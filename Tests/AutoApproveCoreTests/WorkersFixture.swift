import Foundation
import Darwin
import AutoApproveCore

/// No real account, token, DNS, or Keychain is accessed.
final class WorkersFixture:@unchecked Sendable {
    let lock=NSRecursiveLock()
    var secrets:[String:Data]=[:],requests:[URLRequest]=[],bindings:[JSONObject]?,metadata:[JSONObject]=[]
    var records:[JSONObject]=[]
    var conflict=false,foreign=false,loseUpload=false,empty=false,delay:UInt64=0,indexStatus=200
    var uploads=0,domains=0,authCalls=0
    func locked<T>(_ body:()->T)->T {lock.lock();defer{lock.unlock()};return body()}
    var tools:CloudflareWorkersServices {CloudflareWorkersServices(authorize:{_,saved,interactive,onURL in
        self.locked {self.authCalls+=1}
        if interactive {onURL(URL(string:"https://dash.cloudflare.com/oauth2/auth?fixture=1")!)}
        let delay=self.locked {self.delay};if delay>0 {try? await Task.sleep(nanoseconds:delay)}
        return CloudflareWorkersAuthorization(credential:Data("synthetic oauth TOML".utf8),token:CloudflareFixture.token)
    })}
    var http:CloudflareServices {CloudflareServices(exchange:{try self.reply($0)},login:{_,_,_ in throw CloudflareFixture.Failure()},readSecret:{_,key in self.locked {self.secrets[key]}},saveSecret:{_,key,data in self.locked {self.secrets[key]=data}})}
    private func reply(_ request:URLRequest) throws -> CloudflareHTTPReply {
        lock.lock();defer{lock.unlock()};requests.append(request)
        guard request.url?.host=="api.cloudflare.com",request.url?.scheme=="https",request.value(forHTTPHeaderField:"Authorization")=="Bearer "+CloudflareFixture.token else {throw CloudflareFixture.Failure()}
        let path=request.url!.path,method=request.httpMethod!
        func response(_ result:Any,status:Int=200)->CloudflareHTTPReply {CloudflareHTTPReply(data:try! JSONSerialization.data(withJSONObject:["success":status==200,"result":result]),status:status)}
        if path=="/client/v4/zones" {return response(empty ? []:[CloudflareFixture.domain()],status:indexStatus)}
        if path.hasSuffix("/settings") {return response(bindings.map {["bindings":$0]} ?? [:],status:bindings==nil ? 404:200)}
        if path.hasSuffix("/workers/domains/records"),method=="GET" {return response(records)}
        if path.hasSuffix("/domains/changeset") {
            guard let origins=try JSONSerialization.jsonObject(with:request.httpBody!) as? [JSONObject],!origins.isEmpty else {throw CloudflareFixture.Failure()}
            return response(["conflicting":conflict ? [["hostname":"taken.example.com"]]:[],"updated":foreign ? [["id":"fixture","modified":true]]:[]])
        }
        if path.hasSuffix("/workers/domains/records/fixture") {return response(["service":"foreign-worker"])}
        if path.hasSuffix("/domains/records") {
            let json=try JSONSerialization.jsonObject(with:request.httpBody!) as! JSONObject
            guard method=="PUT",json["override_scope"] as? Bool==false,json["override_existing_origin"] as? Bool==false,json["override_existing_dns_record"] as? Bool==false else {throw CloudflareFixture.Failure()}
            guard let origins=json["origins"] as? [JSONObject] else {throw CloudflareFixture.Failure()}
            let script=path.split(separator:"/").dropLast(2).last.map(String.init)!
            records=origins.map {row in var record=row;record["service"]=script;return record}
            domains+=1;return response([:])
        }
        if path.hasSuffix("/subdomain") {
            let json=try JSONSerialization.jsonObject(with:request.httpBody!) as! JSONObject
            guard method=="POST",json["enabled"] as? Bool==false,json["previews_enabled"] as? Bool==false else {throw CloudflareFixture.Failure()};return response([:])
        }
        if method=="PUT",path.contains("/workers/scripts/") {
            let data=request.httpBody!,text=String(decoding:data,as:UTF8.self)
            let start=text.range(of:"\r\n\r\n")!.upperBound,end=text.range(of:"\r\n--",range:start..<text.endIndex)!.lowerBound
            let json=try JSONSerialization.jsonObject(with:Data(text[start..<end].utf8)) as! JSONObject
            metadata.append(json);bindings=json["bindings"] as? [JSONObject];uploads+=1
            guard text.contains("export class TunnelRoom"),!text.contains("SyntheticAccountPermission") else {throw CloudflareFixture.Failure()}
            for data in secrets.values {
                if let saved=try? JSONSerialization.jsonObject(with:data) as? JSONObject,let key=saved["key"] as? String,text.contains(key) {throw CloudflareFixture.Failure()}
            }
            if loseUpload {loseUpload=false;throw URLError(.networkConnectionLost)}
            return response([:])
        }
        throw CloudflareFixture.Failure()
    }
    @MainActor func manager()->CloudflareWorkersOnboarding {CloudflareWorkersOnboarding(directory:FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-workers"),owner:CloudflareFixture.owner,http:http,tools:tools,onStatus:{_ in})}
    var summary:JSONObject {locked {["uploads":uploads,"domains":domains,"authCalls":authCalls,"requests":requests.count]}}
}
