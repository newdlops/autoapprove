import Foundation
import Security

public struct CloudflareDomain:Identifiable,Equatable,Sendable {
    public let id:String
    public let name:String
    public let accountID:String
    public init(id:String,name:String,accountID:String) {self.id=id;self.name=name;self.accountID=accountID}
}
public struct CloudflareSetupStatus:Equatable,Sendable {
    public var phase="idle"
    public var detail="Cloudflare에서 한 번 승인하면 등록된 도메인을 선택할 수 있습니다."
    public var authorized=false
    public var domains:[CloudflareDomain]=[]
    public var busy:Bool {["authorizing","loading","provisioning","installing"].contains(phase)}
    public init() {}
}
public struct CloudflareManagedConnection:Sendable {
    public let tunnelID:String
    public let publicURL:String
}

private struct CloudflareAccount:Codable {
    let zoneID:String,accountID:String,apiToken:String
    static func decode(_ data:Data) throws -> Self {
        guard data.count <= 65536,let text=String(data:data,encoding:.utf8) else {throw invalid()}
        let begin="-----BEGIN ARGO TUNNEL TOKEN-----",end="-----END ARGO TUNNEL TOKEN-----"
        let parts=text.components(separatedBy:begin)
        guard parts.count == 2,let encoded=parts[1].components(separatedBy:end).first,
              parts[1].components(separatedBy:end).count == 2,
              let json=Data(base64Encoded:encoded.filter {!$0.isWhitespace}),
              let value=try? JSONSerialization.jsonObject(with:json) as? JSONObject,
              let zone=value["zoneID"] as? String,let account=value["accountID"] as? String,
              let token=value["apiToken"] as? String,CloudflareOnboarding.identifier(zone),CloudflareOnboarding.identifier(account),
              (16...4096).contains(token.utf8.count),token.utf8.allSatisfy({$0 >= 33 && $0 <= 126}),
              value["endpoint"] == nil || value["endpoint"] as? String == "" else {throw invalid()}
        return Self(zoneID:zone,accountID:account,apiToken:token)
    }
    static func invalid()->AppError {.message("Cloudflare 승인 정보를 확인하지 못했습니다. 공식 승인 화면에서 다시 허용해주세요.")}
}
private struct CloudflareCreationIntent:Codable {
    var accountID:String,name:String,secret:String,tunnelID:String?
}

/// No existing remote tunnel/DNS record is updated or deleted. An intent and
/// its secret survive uncertain POST completion, so retries first reconcile GET.
@MainActor public final class CloudflareOnboarding {
    private let directory:URL,owner:String,services:CloudflareServices
    private let onStatus:@MainActor(CloudflareSetupStatus)->Void
    private var epoch=UUID()
    private var cancelOperation:(()->Void)?
    public private(set) var status=CloudflareSetupStatus()
    public private(set) var approvalURL:URL?
    public init(directory:URL,owner:String,services:CloudflareServices = .live,onStatus:@escaping @MainActor(CloudflareSetupStatus)->Void) {
        self.directory=directory;self.owner=owner;self.services=services;self.onStatus=onStatus
    }
    nonisolated static func identifier(_ value:String)->Bool {value.range(of:#"^[a-fA-F0-9]{32}$"#,options:.regularExpression) != nil}
    private func publish(_ phase:String,_ detail:String) {status.phase=phase;status.detail=detail;onStatus(status)}
    private func current(_ id:UUID) throws {try Task.checkCancellation();guard id == epoch else {throw CancellationError()}}
    public func cancel() {
        epoch=UUID();cancelOperation?();cancelOperation=nil;approvalURL=nil
        publish(status.authorized ? "authorized" : "idle",status.authorized ? "승인한 도메인을 선택하고 연결하세요." : "Cloudflare에서 한 번 승인하면 등록된 도메인을 선택할 수 있습니다.")
    }
    public func authorize(executable:String) async throws {
        try await operation {id in
            self.approvalURL=nil;self.status.domains=[];self.publish("authorizing","브라우저의 Cloudflare 화면에서 로그인하고 이 Mac의 연결을 허용해주세요…")
            let certificate=try await self.services.login(executable,self.directory) { [weak self] url in
                Task { @MainActor in guard let self,self.epoch == id,self.status.phase == "authorizing" else {return};self.approvalURL=url;self.onStatus(self.status) }
            }
            try self.current(id)
            let account=try CloudflareAccount.decode(certificate)
            try self.services.saveSecret(self.directory,"cloudflare-account",JSONEncoder().encode(account))
            self.status.authorized=true
            try await self.loadDomains(account,id:id)
        }
    }
    public func restore() async throws {
        try await operation {id in
            guard let account=try self.account() else {self.status.authorized=false;self.status.domains=[];self.publish("idle","Cloudflare에서 한 번 승인하면 등록된 도메인을 선택할 수 있습니다.");return}
            self.status.authorized=true;try await self.loadDomains(account,id:id)
        }
    }
    private func operation<T:Sendable>(_ body:@escaping @MainActor(UUID) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard cancelOperation == nil else {throw AppError.message("진행 중인 Cloudflare 작업을 먼저 마쳐주세요.")}
        let id=UUID();epoch=id
        let task=Task {try await body(id)};cancelOperation={task.cancel()}
        defer {if epoch == id {cancelOperation=nil}}
        do {return try await withTaskCancellationHandler(operation:{try await task.value},onCancel:{task.cancel()})}
        catch {
            if epoch == id {
                if error is CancellationError || Task.isCancelled {publish(status.authorized ? "authorized" : "idle","Cloudflare 작업을 취소했습니다.")}
                else {publish("failed",error.localizedDescription)}
            }
            if Task.isCancelled {throw CancellationError()};throw error
        }
    }
    private func account() throws -> CloudflareAccount? {
        guard let data=try services.readSecret(directory,"cloudflare-account") else {return nil}
        guard let account=try? JSONDecoder().decode(CloudflareAccount.self,from:data),Self.identifier(account.accountID),Self.identifier(account.zoneID),
              (16...4096).contains(account.apiToken.utf8.count),account.apiToken.utf8.allSatisfy({$0 >= 33 && $0 <= 126}) else {throw CloudflareAccount.invalid()}
        return account
    }
    private func loadDomains(_ account:CloudflareAccount,id:UUID) async throws {
        status.domains=[];publish("loading","Cloudflare에 등록된 도메인을 불러오고 있습니다…")
        var domains:[CloudflareDomain]=[]
        do {
            for page in 1...20 {
                let value=try await request("GET","zones",account:account,id:id,query:["account.id":account.accountID,"status":"active","per_page":"50","page":String(page)])
                guard let rows=value["result"] as? [JSONObject] else {throw invalidResponse()}
                for row in rows {if let domain=domain(row,account:account) {domains.append(domain)}}
                let pages=(value["result_info"] as? JSONObject)?["total_pages"] as? Int ?? 1
                guard pages <= 20 else {throw AppError.message("Cloudflare 도메인이 너무 많습니다. 승인할 도메인을 Cloudflare에서 다시 선택해주세요.")}
                if page >= pages {break}
            }
        } catch let error as CloudflareAPIError where error.status == 403 {
            // Some login certificates permit their selected zone but not the
            // account-wide zone index. Zone details accepts DNS permissions.
            let value=try await request("GET","zones/"+account.zoneID,account:account,id:id)
            if let row=value["result"] as? JSONObject,let domain=domain(row,account:account) {domains=[domain]}
        }
        try current(id)
        status.domains=Array(Dictionary(domains.map {($0.id,$0)},uniquingKeysWith: {first,_ in first}).values).sorted {$0.name.localizedStandardCompare($1.name) == .orderedAscending}
        status.authorized=true;approvalURL=nil
        publish("authorized",status.domains.isEmpty ? "사용 가능한 등록 도메인이 없습니다. Cloudflare에서 도메인을 연결한 뒤 다시 불러오세요." : "Cloudflare 승인이 완료됐습니다. 도메인을 선택하고 연결하세요.")
    }
    private func domain(_ row:JSONObject,account:CloudflareAccount)->CloudflareDomain? {
        guard let id=row["id"] as? String,Self.identifier(id),let name=(row["name"] as? String)?.lowercased(),
              row["status"] as? String == "active",(row["account"] as? JSONObject)?["id"] as? String == account.accountID,
              (try? RemoteTunnelSetup.origin(name)) == "https://"+name else {return nil}
        return CloudflareDomain(id:id,name:name,accountID:account.accountID)
    }
    public func proposedURL(for domainID:String)->String? {
        guard let domain=status.domains.first(where:{$0.id == domainID}) else {return nil}
        return "https://autoapprove-"+owner.replacingOccurrences(of:"-",with:"").prefix(8).lowercased()+"."+domain.name
    }
    public func provision(domainID:String) async throws -> CloudflareManagedConnection {
        try await operation {id in
            guard let account=try self.account(),let domain=self.status.domains.first(where:{$0.id == domainID}),domain.accountID == account.accountID else {
                throw AppError.message("Cloudflare 승인을 마치고 등록된 도메인을 선택해주세요.")
            }
            self.publish("provisioning","이 Mac의 터널과 접속 주소를 자동으로 설정하고 있습니다…")
            var intent:CloudflareCreationIntent
            if let data=try self.services.readSecret(self.directory,"cloudflare-create-intent"),let saved=try? JSONDecoder().decode(CloudflareCreationIntent.self,from:data),saved.accountID == account.accountID {
                intent=saved
                guard intent.name.range(of:#"^AutoApprove-[a-f0-9-]{36}$"#,options:.regularExpression) != nil,
                      Data(base64Encoded:intent.secret)?.count == 32,intent.tunnelID == nil || UUID(uuidString:intent.tunnelID!) != nil else {throw self.invalidResponse()}
            } else {
                var bytes=[UInt8](repeating:0,count:32)
                guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes) == errSecSuccess else {throw self.invalidResponse()}
                intent=CloudflareCreationIntent(accountID:account.accountID,name:"AutoApprove-"+UUID().uuidString.lowercased(),secret:Data(bytes).base64EncodedString(),tunnelID:nil)
                try self.save(intent)
            }
            let path="accounts/"+account.accountID+"/cfd_tunnel"
            if intent.tunnelID == nil {
                let existing=try await self.request("GET",path,account:account,id:id,query:["name":intent.name,"is_deleted":"false"])
                guard let rows=existing["result"] as? [JSONObject],rows.count <= 1 else {throw self.invalidResponse()}
                let tunnel:JSONObject
                if let first=rows.first {tunnel=first}
                else {
                    let created=try await self.request("POST",path,account:account,id:id,body:["name":intent.name,"config_src":"local","tunnel_secret":intent.secret])
                    guard let result=created["result"] as? JSONObject else {throw self.invalidResponse()};tunnel=result
                }
                guard let tunnelID=tunnel["id"] as? String,UUID(uuidString:tunnelID) != nil,tunnel["name"] as? String == intent.name,
                      tunnel["config_src"] == nil || tunnel["config_src"] as? String == "local",
                      tunnel["account_tag"] == nil || tunnel["account_tag"] as? String == account.accountID else {throw self.invalidResponse()}
                intent.tunnelID=tunnelID.lowercased();try self.save(intent)
            }
            try self.current(id)
            let tunnelID=intent.tunnelID!,target=tunnelID+".cfargotunnel.com",marker="AutoApprove "+self.owner
            let credential:JSONObject=["AccountTag":account.accountID,"TunnelID":tunnelID,"TunnelSecret":intent.secret]
            try self.services.saveSecret(self.directory,"cloudflare-tunnel:"+tunnelID,JSONSerialization.data(withJSONObject:credential))
            let base="autoapprove-"+self.owner.replacingOccurrences(of:"-",with:"").prefix(8).lowercased()
            let dns="zones/"+domain.id+"/dns_records"
            for suffix in 0..<5 {
                let host=base+(suffix == 0 ? "" : "-\(suffix+1)")+"."+domain.name
                _ = try RemoteTunnelSetup.origin(host)
                let found=try await self.request("GET",dns,account:account,id:id,query:["name":host,"per_page":"100"])
                guard let rows=found["result"] as? [JSONObject] else {throw self.invalidResponse()}
                let matches:(JSONObject)->Bool={row in
                    (row["name"] as? String)?.lowercased() == host && row["type"] as? String == "CNAME" &&
                    (row["content"] as? String)?.lowercased().trimmingCharacters(in:CharacterSet(charactersIn:".")) == target &&
                    row["proxied"] as? Bool == true && row["comment"] as? String == marker
                }
                if rows.count == 1,let first=rows.first,matches(first) {self.publish("authorized","접속 주소 설정을 마쳤습니다. 이 Mac과 연결하고 있습니다…");return CloudflareManagedConnection(tunnelID:tunnelID,publicURL:"https://"+host)}
                guard rows.isEmpty else {continue}
                let created=try await self.request("POST",dns,account:account,id:id,body:["type":"CNAME","name":host,"content":target,"proxied":true,"ttl":1,"comment":marker])
                guard let record=created["result"] as? JSONObject,matches(record) else {throw self.invalidResponse()}
                self.publish("authorized","접속 주소 설정을 마쳤습니다. 이 Mac과 연결하고 있습니다…")
                return CloudflareManagedConnection(tunnelID:tunnelID,publicURL:"https://"+host)
            }
            throw AppError.message("접속 주소가 이미 사용 중입니다. 기존 DNS는 유지했습니다. 다른 도메인을 선택해주세요.")
        }
    }
    private func save(_ intent:CloudflareCreationIntent) throws {try services.saveSecret(directory,"cloudflare-create-intent",JSONEncoder().encode(intent))}
    private func invalidResponse()->AppError {.message("Cloudflare 설정 응답을 확인하지 못했습니다. 다시 연결하면 생성 결과부터 확인합니다.")}
    private func request(_ method:String,_ path:String,account:CloudflareAccount,id:UUID,query:[String:String]=[:],body:JSONObject?=nil) async throws -> JSONObject {
        try current(id)
        var url=URLComponents(string:"https://api.cloudflare.com/client/v4/"+path)!
        if !query.isEmpty {url.queryItems=query.sorted {$0.key < $1.key}.map {URLQueryItem(name:$0.key,value:$0.value)}}
        var request=URLRequest(url:url.url!);request.httpMethod=method;request.timeoutInterval=15
        request.setValue("Bearer "+account.apiToken,forHTTPHeaderField:"Authorization")
        if let body {request.httpBody=try JSONSerialization.data(withJSONObject:body);request.setValue("application/json",forHTTPHeaderField:"Content-Type")}
        let reply=try await services.exchange(request);try current(id)
        guard (200..<300).contains(reply.status) else {throw CloudflareAPIError(status:reply.status)}
        guard reply.data.count <= 2_000_000,let value=try JSONSerialization.jsonObject(with:reply.data) as? JSONObject,value["success"] as? Bool == true else {throw invalidResponse()}
        return value
    }
}
private struct CloudflareAPIError:LocalizedError {
    let status:Int
    var errorDescription:String? {
        if [401,403].contains(status) {return "Cloudflare 승인 또는 도메인 설정 권한이 부족합니다. Cloudflare에서 다시 승인해주세요."}
        if status == 429 {return "Cloudflare 요청이 많습니다. 잠시 후 다시 연결해주세요."}
        return "Cloudflare 설정을 완료하지 못했습니다 (HTTP \(status)). 다시 연결하면 생성 결과부터 확인합니다."
    }
}
