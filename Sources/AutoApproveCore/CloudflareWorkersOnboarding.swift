import Foundation
import CryptoKit
import Security

public struct CloudflareWorkersServices:Sendable {
    public var authorize:@Sendable(URL,Data?,Bool,@escaping @Sendable(URL)->Void) async throws -> CloudflareWorkersAuthorization
    public init(authorize:@escaping @Sendable(URL,Data?,Bool,@escaping @Sendable(URL)->Void) async throws -> CloudflareWorkersAuthorization) {self.authorize=authorize}
    public static let live=Self(authorize:{directory,data,interactive,onURL in
        try await CloudflareWorkersTool.authorize(directory:directory,credential:data,interactive:interactive,onURL:onURL)
    })
}
private struct WorkerIntent:Codable {
    let account:String,script:String,key:String
    var hash:String {SHA256.hash(data:Data(key.utf8)).map {String(format:"%02x",$0)}.joined()}
}

/// Official OAuth is isolated from the user's Wrangler profile. Remote writes
/// are native API calls with explicit conflict protection, never CLI deploy.
@MainActor public final class CloudflareWorkersOnboarding {
    private let directory:URL,owner:String,http:CloudflareServices,tools:CloudflareWorkersServices
    private let onStatus:@MainActor(CloudflareSetupStatus)->Void
    private var epoch=UUID(),cancelOperation:(()->Void)?
    public private(set) var status=CloudflareSetupStatus()
    public private(set) var approvalURL:URL?
    public init(directory:URL,owner:String,http:CloudflareServices = .live,tools:CloudflareWorkersServices = .live,onStatus:@escaping @MainActor(CloudflareSetupStatus)->Void) {
        self.directory=directory;self.owner=owner;self.http=http;self.tools=tools;self.onStatus=onStatus
    }
    private func publish(_ phase:String,_ detail:String) {status.phase=phase;status.detail=detail;onStatus(status)}
    private func current(_ id:UUID) throws {try Task.checkCancellation();guard id==epoch else {throw CancellationError()}}
    public func cancel() {epoch=UUID();cancelOperation?();cancelOperation=nil;approvalURL=nil;publish(status.authorized ? "authorized":"idle",status.authorized ? "도메인을 선택하고 HTTPS로 연결하세요.":"Cloudflare Workers를 승인하면 443 포트로 연결할 수 있습니다.")}
    private func operation<T:Sendable>(_ body:@escaping @MainActor(UUID) async throws -> T) async throws -> T {
        try Task.checkCancellation();guard cancelOperation==nil else {throw AppError.message("진행 중인 Cloudflare 작업을 먼저 마쳐주세요.")}
        let id=UUID();epoch=id;let task=Task {try await body(id)};cancelOperation={task.cancel()}
        defer {if epoch==id {cancelOperation=nil}}
        do {return try await withTaskCancellationHandler(operation:{try await task.value},onCancel:{task.cancel()})}
        catch {if epoch==id {publish(error is CancellationError ? "idle":"failed",error is CancellationError ? "Cloudflare 작업을 취소했습니다.":error.localizedDescription)};throw error}
    }
    private func session(interactive:Bool,id:UUID) async throws -> String {
        let saved=interactive ? nil:try http.readSecret(directory,"cloudflare-workers-account")
        guard interactive || saved != nil else {throw AppError.message("Cloudflare Workers 승인이 필요합니다. ‘Cloudflare에서 승인’을 눌러주세요.")}
        publish(interactive ? "authorizing":"loading",interactive ? "연결 도구를 준비한 뒤 브라우저에서 Workers와 도메인 연결을 승인해주세요…":"Cloudflare 승인을 확인하고 있습니다…")
        let result=try await tools.authorize(directory,saved,interactive) { [weak self] url in
            Task { @MainActor in guard let self,self.epoch==id else {return};self.approvalURL=url;self.onStatus(self.status) }
        }
        try current(id)
        guard !result.credential.isEmpty,result.credential.count<=65536,(16...8192).contains(result.token.utf8.count),result.token.utf8.allSatisfy({$0>=33&&$0<=126}) else {throw invalid()}
        try http.saveSecret(directory,"cloudflare-workers-account",result.credential);status.authorized=true
        return result.token
    }
    public func authorize() async throws {try await operation {id in let token=try await self.session(interactive:true,id:id);try await self.load(token,id:id)}}
    public func restore() async throws {
        try await operation {id in
            guard try self.http.readSecret(self.directory,"cloudflare-workers-account") != nil else {self.status=CloudflareSetupStatus();self.publish("idle","Cloudflare Workers를 승인하면 443 포트로 연결할 수 있습니다.");return}
            let token=try await self.session(interactive:false,id:id);try await self.load(token,id:id)
        }
    }
    private func load(_ token:String,id:UUID) async throws {
        status.domains=[];publish("loading","Cloudflare에 등록된 도메인을 불러오고 있습니다…")
        var domains:[CloudflareDomain]=[]
        for page in 1...20 {
            let value=try await request("GET","zones",token:token,id:id,query:["status":"active","per_page":"50","page":String(page)])
            guard let rows=value["result"] as? [JSONObject] else {throw invalid()}
            for row in rows {
                guard let zone=row["id"] as? String,CloudflareOnboarding.identifier(zone),let account=(row["account"] as? JSONObject)?["id"] as? String,CloudflareOnboarding.identifier(account),
                      let name=(row["name"] as? String)?.lowercased(),row["status"] as? String=="active",(try? RemoteTunnelSetup.origin(name))=="https://"+name else {continue}
                domains.append(CloudflareDomain(id:zone,name:name,accountID:account))
            }
            let pages=(value["result_info"] as? JSONObject)?["total_pages"] as? Int ?? 1
            guard pages<=20 else {throw AppError.message("등록된 도메인이 너무 많습니다. Cloudflare 계정의 도메인 권한을 확인해주세요.")};if page>=pages {break}
        }
        try current(id);approvalURL=nil
        status.domains=Array(Dictionary(domains.map {($0.id,$0)},uniquingKeysWith: {a,_ in a}).values).sorted {$0.name<$1.name}
        publish("authorized",domains.isEmpty ? "사용 가능한 등록 도메인이 없습니다. Cloudflare에 도메인을 연결한 뒤 다시 불러오세요.":"Workers 승인이 완료됐습니다. 도메인과 짧은 서브도메인을 선택하고 연결하세요.")
    }
    public func proposedURL(for domainID:String,subdomain:String)->String? {
        guard let domain=status.domains.first(where:{$0.id==domainID}),let label=try? RemoteTunnelSetup.subdomain(subdomain) else {return nil}
        return try? RemoteTunnelSetup.origin(label+"."+domain.name)
    }
    public func provision(domainID:String,subdomain:String) async throws -> String {
        try await operation {id in
            guard let domain=self.status.domains.first(where:{$0.id==domainID}) else {throw AppError.message("Cloudflare Workers 승인을 마치고 도메인을 선택해주세요.")}
            let label=try RemoteTunnelSetup.subdomain(subdomain),host=label+"."+domain.name
            let origin=try RemoteTunnelSetup.origin(host),token=try await self.session(interactive:false,id:id)
            self.publish("provisioning","Workers와 접속 주소를 설정하고 있습니다…")
            let name="cloudflare-workers-intent:"+domain.accountID
            let intent:WorkerIntent
            if let data=try self.http.readSecret(self.directory,name) {
                guard data.count<=4096,let saved=try? JSONDecoder().decode(WorkerIntent.self,from:data),saved.account==domain.accountID else {throw self.invalid()}
                _ = try CloudflareRelayCredential(script:saved.script,origin:origin,key:saved.key).validated(for:origin);intent=saved
            } else {
                var bytes=[UInt8](repeating:0,count:32);guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes)==errSecSuccess else {throw self.invalid()}
                intent=WorkerIntent(account:domain.accountID,script:"autoapprove-relay-"+UUID().uuidString.lowercased().replacingOccurrences(of:"-",with:""),key:Data(bytes).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:""))
                try self.http.saveSecret(self.directory,name,JSONEncoder().encode(intent))
            }
            let path="accounts/"+intent.account+"/workers/scripts/"+intent.script
            let settings=try await self.request("GET",path+"/settings",token:token,id:id,allow404:true)
            let exists=settings["success"] as? Bool==true
            if exists {
                guard let bindings=(settings["result"] as? JSONObject)?["bindings"] as? [JSONObject],
                      bindings.contains(where:{$0["name"] as? String=="AUTOAPPROVE_OWNER" && $0["text"] as? String==self.owner}),
                      bindings.contains(where:{$0["name"] as? String=="CONNECTOR_HASH" && $0["text"] as? String==intent.hash}) else {throw AppError.message("이 Mac의 Workers 소유 정보를 확인하지 못했습니다. 기존 설정은 변경하지 않았습니다.")}
            }
            // All override flags stay false on the final domain write. For an
            // existing Worker, preflight also precedes changing its hostname.
            var origins:[[String:Any]]=[]
            if exists {
                // Include our previous custom domains so a rename never asks
                // the API to remove a route as a side effect of replacement.
                for page in 0..<20 {
                    let existing=try await self.request("GET","accounts/"+intent.account+"/workers/domains/records",token:token,id:id,query:["service":intent.script,"environment":"production","per_page":"100","page":String(page)])
                    guard let rows=existing["result"] as? [JSONObject] else {throw self.invalid()}
                    for row in rows {
                        guard row["service"] as? String==intent.script,let hostname=row["hostname"] as? String,let zone=row["zone_id"] as? String,CloudflareOnboarding.identifier(zone),
                              (try? RemoteTunnelSetup.origin(hostname))=="https://"+hostname else {throw self.invalid()}
                        if hostname != host {origins.append(["hostname":hostname,"zone_id":zone])}
                    }
                    if rows.count<100 {break};if page==19 {throw self.invalid()}
                }
            }
            origins.append(["hostname":host,"zone_id":domain.id])
            let source=try Self.relaySource()
            var metadata:JSONObject=["main_module":"relay.mjs","compatibility_date":"2026-10-01","bindings":[
                ["type":"durable_object_namespace","name":"TUNNEL","class_name":"TunnelRoom"],
                ["type":"plain_text","name":"PUBLIC_HOST","text":host],
                ["type":"plain_text","name":"CONNECTOR_HASH","text":intent.hash],
                ["type":"plain_text","name":"AUTOAPPROVE_OWNER","text":self.owner]
            ],"logpush":false,"observability":["enabled":false]]
            if !exists {metadata["migrations"]=["new_tag":"v1","new_sqlite_classes":["TunnelRoom"]]}
            let boundary="AutoApprove"+UUID().uuidString.replacingOccurrences(of:"-",with:"")
            var body=Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"metadata\"\r\nContent-Type: application/json\r\n\r\n".utf8)
            body.append(try JSONSerialization.data(withJSONObject:metadata));body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"relay.mjs\"; filename=\"relay.mjs\"\r\nContent-Type: application/javascript+module\r\n\r\n".utf8));body.append(source);body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            // The changeset API requires an uploaded script. A first attempt
            // can leave only our unbound Worker if the requested DNS is taken.
            if !exists {_ = try await self.request("PUT",path,token:token,id:id,raw:body,contentType:"multipart/form-data; boundary="+boundary)}
            let changes=try await self.request("POST",path+"/domains/changeset",token:token,id:id,query:["replace_state":"true"],json:origins)
            guard let result=changes["result"] as? JSONObject,let conflicts=result["conflicting"] as? [JSONObject],let updated=result["updated"] as? [JSONObject],conflicts.isEmpty else {throw self.collision()}
            for change in updated where change["modified"] as? Bool==true {
                guard let recordID=change["id"] as? String,recordID.range(of:#"^[A-Za-z0-9_-]{1,128}$"#,options:.regularExpression) != nil else {throw self.invalid()}
                let previous=try await self.request("GET","accounts/"+intent.account+"/workers/domains/records/"+recordID,token:token,id:id)
                guard (previous["result"] as? JSONObject)?["service"] as? String==intent.script else {throw self.collision()}
            }
            if exists {_ = try await self.request("PUT",path,token:token,id:id,raw:body,contentType:"multipart/form-data; boundary="+boundary)}
            _ = try await self.request("POST",path+"/subdomain",token:token,id:id,json:["enabled":false,"previews_enabled":false])
            _ = try await self.request("PUT",path+"/domains/records",token:token,id:id,json:["origins":origins,"override_scope":false,"override_existing_origin":false,"override_existing_dns_record":false])
            try self.current(id)
            let credential=CloudflareRelayCredential(script:intent.script,origin:origin,key:intent.key)
            try self.http.saveSecret(self.directory,"cloudflare-worker",JSONEncoder().encode(credential))
            self.publish("authorized","HTTPS 접속 주소 설정을 마쳤습니다. 이 Mac을 연결하고 있습니다…")
            return origin
        }
    }
    private func invalid()->AppError {.message("Cloudflare Workers 응답을 확인하지 못했습니다. 다시 연결하면 기존 생성 결과부터 확인합니다.")}
    private static func relaySource() throws -> Data {
        let relative="AutoApprove_AutoApproveCore.bundle/CloudflareRelay/relay.mjs"
        let executable=URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL
        let candidates=[Bundle.main.resourceURL?.appendingPathComponent(relative),executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/"+relative)]
        for url in candidates.compactMap({$0}) where FileManager.default.fileExists(atPath:url.path) {
            let data=try Data(contentsOf:url);guard (1...200000).contains(data.count) else {throw AppError.message("HTTPS 중계 파일을 확인하지 못했습니다.")};return data
        }
        // SwiftPM's generated accessor can reference the build machine; never
        // evaluate it in a relocated app if its packaged resource is missing.
        guard Bundle.main.bundleURL.pathExtension != "app",let url=Bundle.module.url(forResource:"relay",withExtension:"mjs",subdirectory:"CloudflareRelay") else {throw AppError.message("HTTPS 중계 파일이 없습니다. 앱을 다시 설치해주세요.")}
        let data=try Data(contentsOf:url);guard (1...200000).contains(data.count) else {throw AppError.message("HTTPS 중계 파일을 확인하지 못했습니다.")};return data
    }
    private func collision()->AppError {.message("선택한 서브도메인이 이미 사용 중입니다. 기존 연결은 유지했습니다. 다른 이름을 입력해주세요.")}
    private func request(_ method:String,_ path:String,token:String,id:UUID,query:[String:String]=[:],json:Any?=nil,raw:Data?=nil,contentType:String?=nil,allow404:Bool=false) async throws -> JSONObject {
        try current(id);var url=URLComponents(string:"https://api.cloudflare.com/client/v4/"+path)!
        if !query.isEmpty {url.queryItems=query.sorted {$0.key<$1.key}.map {URLQueryItem(name:$0.key,value:$0.value)}}
        var request=URLRequest(url:url.url!);request.httpMethod=method;request.timeoutInterval=30;request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
        if let json {request.httpBody=try JSONSerialization.data(withJSONObject:json);request.setValue("application/json",forHTTPHeaderField:"Content-Type")}
        if let raw {request.httpBody=raw;request.setValue(contentType,forHTTPHeaderField:"Content-Type")}
        let reply=try await http.exchange(request);try current(id)
        if allow404 && reply.status==404 {return ["success":false]}
        guard (200..<300).contains(reply.status) else {
            if [401,403].contains(reply.status) {throw AppError.message("Cloudflare Workers 또는 도메인 권한이 부족합니다. 다시 승인해주세요.")}
            if reply.status==409 {throw collision()}
            if reply.status==429 {throw AppError.message("Cloudflare 사용 한도에 도달했습니다. 잠시 후 다시 연결하거나 Cloudflare 계정의 한도를 확인해주세요.")}
            throw AppError.message("Cloudflare Workers 설정을 완료하지 못했습니다 (HTTP \(reply.status)). 다시 연결하면 기존 생성 결과부터 확인합니다.")
        }
        guard reply.data.count<=2_000_000,let value=try JSONSerialization.jsonObject(with:reply.data) as? JSONObject,value["success"] as? Bool==true else {throw invalid()};return value
    }
}
