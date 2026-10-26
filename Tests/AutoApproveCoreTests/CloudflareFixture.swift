import Foundation
import AutoApproveCore

/// Synthetic Cloudflare account. Never contacts Cloudflare or the real Keychain.
final class CloudflareFixture:@unchecked Sendable {
    static let account=String(repeating:"a",count:32),zone=String(repeating:"b",count:32),otherZone=String(repeating:"c",count:32)
    static let owner="12345678-1234-1234-1234-123456789012",tunnel="11111111-2222-3333-4444-555555555555"
    static let token="SyntheticAccountPermission0123456789"
    private let lock=NSLock()
    var secrets:[String:Data]=[:],requests:[URLRequest]=[],tunnels:[JSONObject]=[],records:[String:[JSONObject]]=[:]
    var pages:[[JSONObject]]=[[CloudflareFixture.domain()]],indexStatus=200,loginDelay:UInt64=0,certificateOverride:Data?
    var loseTunnelReply=false,loseDNSReply=false,oversized=false
    struct Failure:Error {}
    static func domain(_ name:String="example.com",id:String=CloudflareFixture.zone,account:String=CloudflareFixture.account,status:String="active")->JSONObject {
        ["id":id,"name":name,"account":["id":account],"status":status]
    }
    static func certificate()->Data {
        let json=try! JSONSerialization.data(withJSONObject:["zoneID":zone,"accountID":account,"apiToken":token],options:.sortedKeys)
        return Data(("-----BEGIN ARGO TUNNEL TOKEN-----\n"+json.base64EncodedString()+"\n-----END ARGO TUNNEL TOKEN-----\n").utf8)
    }
    func locked<T>(_ body:()->T)->T {lock.lock();defer {lock.unlock()};return body()}
    var services:CloudflareServices {
        CloudflareServices(exchange:{try self.reply($0)},login:{_,_,onURL in
            onURL(URL(string:"https://dash.cloudflare.com/argotunnel?fixture=synthetic")!)
            let delay=self.locked {self.loginDelay}
            if delay > 0 {await withCheckedContinuation {continuation in DispatchQueue.global().asyncAfter(deadline:.now()+Double(delay)/1_000_000_000) {continuation.resume()}}}
            return self.locked {self.certificateOverride ?? Self.certificate()}
        },readSecret:{_,key in self.locked {self.secrets[key]}},saveSecret:{_,key,data in self.locked {self.secrets[key]=data}})
    }
    private func reply(_ request:URLRequest) throws -> CloudflareHTTPReply {
        lock.lock();defer {lock.unlock()};requests.append(request)
        guard let url=request.url,url.scheme == "https",url.host == "api.cloudflare.com",
              request.value(forHTTPHeaderField:"Authorization") == "Bearer "+Self.token else {throw Failure()}
        let path=url.path,method=request.httpMethod ?? "GET"
        guard ["GET","POST"].contains(method) else {throw Failure()}
        let query=Dictionary(uniqueKeysWithValues:(URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems ?? []).map {($0.name,$0.value ?? "")})
        let body=(request.httpBody.flatMap {try? JSONSerialization.jsonObject(with:$0) as? JSONObject}) ?? [:]
        func response(_ result:Any,status:Int=200,info:JSONObject?=nil) throws -> CloudflareHTTPReply {
            var envelope:JSONObject=["success":status == 200,"result":result,"errors":status == 200 ? [] : [["message":Self.token]]]
            if let info {envelope["result_info"]=info}
            return CloudflareHTTPReply(data:oversized ? Data(repeating:32,count:2_000_001) : try JSONSerialization.data(withJSONObject:envelope),status:status)
        }
        if path == "/client/v4/zones" {
            guard indexStatus == 200 else {return try response([],status:indexStatus)}
            guard query["account.id"] == Self.account,query["status"] == "active",let page=Int(query["page"] ?? ""),page > 0,page <= pages.count else {throw Failure()}
            return try response(pages[page-1],info:["total_pages":pages.count])
        }
        if path == "/client/v4/zones/"+Self.zone {return try response(Self.domain())}
        if path == "/client/v4/accounts/"+Self.account+"/cfd_tunnel" {
            if method == "GET" {return try response(tunnels.filter {$0["name"] as? String == query["name"]})}
            guard let name=body["name"] as? String,body["config_src"] as? String == "local",let secret=body["tunnel_secret"] as? String,Data(base64Encoded:secret)?.count == 32 else {throw Failure()}
            let row:JSONObject=["id":Self.tunnel,"name":name,"config_src":"local","account_tag":Self.account]
            tunnels.append(row)
            if loseTunnelReply {loseTunnelReply=false;throw URLError(.networkConnectionLost)}
            return try response(row)
        }
        if path.hasPrefix("/client/v4/zones/"),path.hasSuffix("/dns_records") {
            if method == "GET",let name=query["name"] {return try response(records[name] ?? [])}
            guard let name=body["name"] as? String,records[name] == nil || records[name]?.isEmpty == true else {throw Failure()}
            var row=body;row["id"]="synthetic-dns";records[name]=[row]
            if loseDNSReply {loseDNSReply=false;throw URLError(.networkConnectionLost)}
            return try response(row)
        }
        throw Failure()
    }
    var summary:JSONObject {locked {
        ["tunnels":tunnels.count,"dnsRecords":records.values.reduce(0) {$0+$1.count},"requests":requests.count,
         "writes":requests.filter {$0.httpMethod == "POST"}.count,"methods":requests.map {$0.httpMethod ?? "GET"}]
    }}
}
