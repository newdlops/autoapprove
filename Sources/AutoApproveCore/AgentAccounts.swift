import Foundation
import CryptoKit

/// A Mac-local account coordinator. Its private login PTYs never enter the
/// session manager, inventory, output streams, audit log or receipt archive.
@MainActor public final class AgentAccounts {
    private final class Job {
        let id:String,owner:String,agent:String,expires:Date,tty:String
        var terminal:ManagedPTY?,task:Task<Void,Never>?,sequence=0
        let writer=UUID().uuidString
        var phase="starting",url:String?,code:String?,message:String?,submitted=false
        init(id:String,owner:String,agent:String,terminal:ManagedPTY,now:Date) {
            self.id=id;self.owner=owner;self.agent=agent;self.terminal=terminal;tty=terminal.descriptor.tty;expires=now.addingTimeInterval(600)
        }
        var active:Bool {["starting","waiting","verifying"].contains(phase)}
        func finish(_ phase:String,_ message:String?=nil) {
            self.phase=phase;self.message=message;url=nil;code=nil
            terminal?.close();terminal=nil
        }
        var view:JSONObject {
            var value:JSONObject=["id":id,"agent":agent,"phase":phase,"submitted":submitted,"remaining":max(0,Int(expires.timeIntervalSinceNow))]
            if let url {value["url"]=url};if let code {value["code"]=code};if let message {value["message"]=message};return value
        }
    }
    private let services:AgentAccountServices
    private var crypto=AgentAccountCrypto(),generation=UUID()
    private var grants:[String:Date]=[:],jobs:[String:Job]=[:],seen:[String:Date]=[:]
    private var failures:[Date]=[],unlocking=false,pinStamp=""
    private var retiredTTYs:[String:Date]=[:]
    private var cached:[AgentAccountState]=[],cachedAt=Date.distantPast,checking:Task<[AgentAccountState],Never>?
    public init(services:AgentAccountServices = .live) {self.services=services}
    public var privateTTYs:Set<String> {Set(jobs.values.map(\.tty)).union(retiredTTYs.filter{$0.value>Date()}.keys)}
    public var busy:Bool {jobs.values.contains(where:\.active)}
    public func hello(node:String,pin:RemoteTunnelPIN?) -> JSONObject {
        ["version":1,"node":node,"keyID":crypto.id,"publicKey":crypto.publicKey,"pinConfigured":pin != nil,"time":Date().timeIntervalSince1970*1000]
    }
    public func stop() {
        generation=UUID();checking?.cancel();checking=nil
        retiredTTYs=retiredTTYs.filter{$0.value>Date()}
        for job in jobs.values {retiredTTYs[job.tty]=Date().addingTimeInterval(60);job.task?.cancel();job.finish("cancelled")}
        jobs.removeAll();grants.removeAll();seen.removeAll();cached=[];cachedAt = .distantPast;crypto=AgentAccountCrypto()
    }
    public func encrypted(_ envelope:JSONObject,node:String,pin:RemoteTunnelPIN?) async throws -> JSONObject {
        let request=try crypto.open(envelope,node:node),currentCrypto=crypto
        do {
            let now=Date()
            guard let time=request.object["time"] as? Double,abs(now.timeIntervalSince1970*1000-time)<90000 else {throw RemoteHTTPError(409,"로그인 요청이 만료됐습니다. 창을 다시 열어주세요.")}
            seen=seen.filter{now.timeIntervalSince($0.value)<120}
            let id=envelope["request"] as! String
            guard seen[id]==nil else {throw RemoteHTTPError(409,"이미 처리한 로그인 요청입니다. 진행 상태를 확인해주세요.")}
            guard seen.count<4096 else {throw RemoteHTTPError(429,"로그인 요청이 많습니다. 잠시 후 다시 확인해주세요.")};seen[id]=now
            guard let pin else {throw RemoteHTTPError(403,"이 Mac의 연결 설정에서 접속 PIN을 먼저 지정해주세요. Cloudflare 연결은 필요하지 않습니다.")}
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            let stamp=SHA256.hash(data:try encoder.encode(pin)).map{String(format:"%02x",$0)}.joined()
            if pinStamp != stamp {grants.removeAll();pinStamp=stamp}
            grants=grants.filter{$0.value>now}
            for job in jobs.values where job.active && (job.expires<=now || grants[job.owner]==nil) {job.task?.cancel();job.finish("expired","인증 시간이 만료됐습니다. 다시 로그인해주세요.")}
            jobs=jobs.filter{$0.value.expires.addingTimeInterval(120)>now}
            let object=request.object
            if object["action"] as? String=="unlock" {
                failures=failures.filter{now.timeIntervalSince($0)<60}
                guard failures.count<5,!unlocking else {throw RemoteHTTPError(429,"PIN 확인은 잠시 후 다시 시도해주세요.")}
                guard let value=object["pin"] as? String,RemoteTunnelPIN.valid(value) else {throw RemoteHTTPError(400,"PIN은 숫자 6~12자리입니다.")}
                failures.append(now);unlocking=true;let epoch=generation
                let valid=await Task.detached(priority:.userInitiated){pin.matches(value)}.value
                unlocking=false;guard epoch==generation else {throw RemoteHTTPError(409,"Mac의 로그인 설정이 변경됐습니다. 다시 확인해주세요.")}
                guard valid else {throw RemoteHTTPError(401,"PIN이 맞지 않습니다. 선택한 Mac의 접속 PIN을 입력해주세요.")}
                failures=[];guard grants.count<16 else {throw RemoteHTTPError(429,"관리 연결이 많습니다. 잠시 후 다시 열어주세요.")}
                let token=try RemoteTunnelGateway.random();grants[token]=Date().addingTimeInterval(900)
                return try currentCrypto.seal(["token":token,"home":services.home],for:request)
            }
            guard let owner=object["token"] as? String,grants[owner] != nil else {throw RemoteHTTPError(401,"관리 인증이 만료됐습니다. PIN을 다시 입력해주세요.")}
            let result=try await perform(object,owner:owner)
            return try currentCrypto.seal(result,for:request)
        } catch {
            let known=error as? RemoteHTTPError
            return try currentCrypto.seal(["error":known?.message ?? "Mac의 로그인 상태를 확인하지 못했습니다. 다시 확인해주세요.","status":known?.status ?? 503],for:request)
        }
    }
    private func states(force:Bool=false) async -> [AgentAccountState] {
        if let checking {return await checking.value}
        if !force,!cached.isEmpty,Date().timeIntervalSince(cachedAt)<15 {return cached}
        let services=services,epoch=generation
        let task=Task {await withTaskGroup(of:AgentAccountState.self,returning:[AgentAccountState].self){group in
            for agent in ["codex","claude"] {group.addTask{(try? await services.check(agent)) ?? AgentAccountState(agent:agent,phase:"unknown")}}
            var values:[AgentAccountState]=[];for await value in group {values.append(value)};return values.sorted{$0.agent>$1.agent}
        }}
        checking=task;let value=await task.value
        guard epoch==generation else {return []};checking=nil;cached=value;cachedAt=Date();return value
    }
    private func perform(_ object:JSONObject,owner:String) async throws -> JSONObject {
        switch object["action"] as? String {
        case "status":
            let states=await states(force:object["refresh"] as? Bool==true)
            guard grants[owner] != nil else {throw RemoteHTTPError(401,"관리 인증을 다시 확인해주세요.")}
            return ["states":states.map{["agent":$0.agent,"phase":$0.phase,"method":$0.method]},"jobs":jobs.values.filter{$0.owner==owner}.sorted{$0.expires<$1.expires}.map(\.view),"busy":Array(Set(jobs.values.filter{$0.active && $0.owner != owner}.map(\.agent)))]
        case "begin":
            guard let agent=object["agent"] as? String,["codex","claude"].contains(agent),let id=object["id"] as? String,UUID(uuidString:id) != nil else {throw RemoteHTTPError(400,"로그인할 도구를 선택해주세요.")}
            if let old=jobs[id] {guard old.owner==owner,old.agent==agent else {throw RemoteHTTPError(403,"다른 로그인 요청입니다.")};return old.view}
            guard !jobs.values.contains(where:{$0.agent==agent && $0.active}) else {throw RemoteHTTPError(409,"이 Mac에서 해당 도구의 로그인이 진행 중입니다. 이전 로그인을 취소한 뒤 시작해주세요.")}
            guard jobs.count<16 else {throw RemoteHTTPError(429,"로그인 요청이 많습니다. 잠시 후 다시 시도해주세요.")}
            let terminal=try services.launch(agent),job=Job(id:id,owner:owner,agent:agent,terminal:terminal,now:Date())
            jobs[id]=job;let epoch=generation
            job.task=Task{[weak self,weak job] in guard let self,let job else {return};await self.follow(job,epoch:epoch)}
            return job.view
        case "submit":
            guard let id=object["id"] as? String,let job=jobs[id],job.owner==owner,job.agent=="claude",job.phase=="waiting",!job.submitted,let terminal=job.terminal else {throw RemoteHTTPError(409,"인증 코드를 다시 보내지 말고 진행 상태를 확인해주세요.")}
            guard let raw=object["code"] as? String else {throw RemoteHTTPError(400,"공식 인증 페이지의 코드를 붙여넣어주세요.")}
            let code=raw.trimmingCharacters(in:.whitespacesAndNewlines)
            guard (4...4096).contains(code.utf8.count),code.utf8.allSatisfy({$0>=33 && $0<=126}),!code.hasPrefix("http") else {throw RemoteHTTPError(400,"공식 인증 페이지에 표시된 일회용 코드만 붙여넣어주세요.")}
            // Reserve before the write. Partial/uncertain input is never replayed.
            job.submitted=true;job.phase="verifying";job.sequence+=1
            do {try terminal.input(Data((code+"\r").utf8),streamID:terminal.descriptor.streamID,client:job.writer,sequence:job.sequence)}
            catch {job.finish("uncertain","코드 전달 결과를 확인 중입니다. 같은 코드를 다시 보내지 말고 로그인 상태를 확인해주세요.");cachedAt = .distantPast}
            return job.view
        case "cancel":
            guard let agent=object["agent"] as? String,["codex","claude"].contains(agent) else {throw RemoteHTTPError(400,"도구를 선택해주세요.")}
            // An explicitly PIN-authorized owner may cancel an abandoned tab.
            for job in jobs.values where job.agent==agent && job.active {job.task?.cancel();job.finish("cancelled","로그인을 취소했습니다.")}
            return ["cancelled":true]
        default:throw RemoteHTTPError(400,"지원하지 않는 계정 작업입니다.")
        }
    }
    private func follow(_ job:Job,epoch:UUID) async {
        var offset=0,buffer=""
        defer {buffer="";job.terminal?.close();job.terminal=nil}
        while !Task.isCancelled,epoch==generation,job.active,let terminal=job.terminal {
            if Date()>=job.expires {job.finish("expired","인증 시간이 만료됐습니다. 다시 로그인해주세요.");return}
            do {
                let output=try terminal.read(after:offset);offset=output.offset
                if let data=Data(base64Encoded:output.data) {buffer+=String(decoding:data,as:UTF8.self);if buffer.utf8.count>24000 {buffer=String(buffer.suffix(16000))}}
                let challenge=AgentAccountOutput.challenge(buffer,agent:job.agent)
                if let url=challenge.url {job.url=url;if let code=challenge.code {job.code=code};if job.phase=="starting" {job.phase="waiting"}}
                if let exit=output.exitCode {
                    job.phase="verifying";let state=try await services.check(job.agent)
                    guard !Task.isCancelled,epoch==generation,job.active else {return}
                    if exit==0,state.phase=="authenticated" {job.finish("succeeded","이 Mac에서 로그인했습니다.")}
                    else if buffer.lowercased().contains("expired") {job.finish("expired","인증 코드가 만료됐습니다. 다시 로그인해주세요.")}
                    else {job.finish("failed","로그인을 완료하지 못했습니다. CLI 버전·인터넷 연결·계정의 인증 허용 설정을 확인한 뒤 다시 시도해주세요.")}
                    cachedAt = .distantPast;return
                }
                if job.phase=="starting",job.expires.timeIntervalSinceNow<570 {job.finish("failed","공식 로그인 링크를 받지 못했습니다. CLI를 업데이트하고 인터넷 연결을 확인한 뒤 다시 시도해주세요.");return}
                try await Task.sleep(for:.milliseconds(150))
            } catch is CancellationError {return}
            catch {job.finish("failed","Mac의 인증 프로세스 연결이 끝났습니다. 로그인 상태를 다시 확인해주세요.");return}
        }
    }
}
