import Foundation
import Darwin
import CryptoKit
import AutoApproveCore

// The full-scan decoder is an immutable compatibility oracle from the pre-change Core.
// Only the production Core is used for the linear search-range check.
private protocol HeaderDecoding: AnyObject {
    var receivedBytes: Int { get }
    var expectedBytes: Int? { get }
    var allowsConnectionReuse: Bool { get }
    func append(_ data: Data) throws -> RemoteHTTPResponse?
    func finish() throws
}
extension RemotePeerResponseDecoder: HeaderDecoding {}
extension LegacyPeerResponseDecoder: HeaderDecoding {}


/// One finite HTTP response. Headers parse once; bytes and gzip output stay
/// bounded. A malformed or mismatched peer can never become a preferred route.
private final class LegacyPeerResponseDecoder {
    private let expectedNodeID: String?
    private let acceptsGzip: Bool
    private var buffer = Data()
    private var headers: [String:String]?
    private var status = 0
    private var complete = false
    private(set) var receivedBytes = 0
    private(set) var expectedBytes: Int?
    private var reusable = false
    var allowsConnectionReuse: Bool { complete && reusable }
    init(expectedNodeID: String? = nil, acceptsGzip: Bool = false) {
        self.expectedNodeID = expectedNodeID; self.acceptsGzip = acceptsGzip
    }
    private func invalid(_ message: String) -> RemoteHTTPError {
        RemoteHTTPError(502,message,diagnostics:["failureKind":"protocol"])
    }
    func append(_ data: Data) throws -> RemoteHTTPResponse? {
        guard !complete, data.count <= 64_000 else { throw invalid("Mac의 응답 순서를 확인하지 못했습니다.") }
        receivedBytes += data.count; buffer.append(data)
        guard receivedBytes <= 4_016_388 else { throw invalid("Mac의 응답이 너무 큽니다.") }
        if headers == nil {
            guard let boundary = buffer.range(of:Data("\r\n\r\n".utf8)) else {
                guard buffer.count <= 16_384 else { throw invalid("Mac의 응답 헤더가 너무 큽니다.") }
                return nil
            }
            guard boundary.lowerBound <= 16_384, let text = String(data:buffer[..<boundary.lowerBound],encoding:.utf8) else { throw invalid("Mac의 응답 헤더를 읽지 못했습니다.") }
            let lines = text.components(separatedBy:"\r\n"), first = lines[0].split(separator:" ")
            guard first.count >= 2, ["HTTP/1.0","HTTP/1.1"].contains(String(first[0])), let code = Int(first[1]), (200...599).contains(code) else { throw invalid("Mac의 응답 상태가 올바르지 않습니다.") }
            var fields = [String:String]()
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of:":") else { throw invalid("Mac의 응답 헤더가 올바르지 않습니다.") }
                let key = line[..<colon].lowercased()
                let value = line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces)
                guard !key.isEmpty, key.utf8.allSatisfy({(97...122).contains($0)||(48...57).contains($0)||"!#$%&'*+-.^_`|~".utf8.contains($0)}), fields[key] == nil,
                      value.utf8.allSatisfy({$0 == 9 || $0 >= 32 && $0 != 127}) else { throw invalid("Mac의 응답 헤더가 중복되었거나 올바르지 않습니다.") }
                fields[key] = value
            }
            if let expectedNodeID, let actual = fields["x-autoapprove-node"], actual != expectedNodeID {
                throw RemoteHTTPError(502,"Mac의 연결 정보가 바뀌었습니다. 주소를 다시 추가해주세요.",diagnostics:["failureKind":"identity"])
            }
            guard fields["transfer-encoding"] == nil else { throw invalid("Mac의 응답 전송 형식을 확인하지 못했습니다.") }
            let encoding = fields["content-encoding"]?.lowercased()
            guard encoding == nil || encoding == "identity" || acceptsGzip && encoding == "gzip" else { throw invalid("Mac의 응답 압축 형식을 확인하지 못했습니다.") }
            let length: Int
            if code == 304, fields["content-length"] == nil { length = 0 }
            else {
                guard let value = fields["content-length"], !value.isEmpty, value.utf8.allSatisfy({(48...57).contains($0)}),
                      let parsed = Int(value), (0...4_000_000).contains(parsed) else { throw invalid("Mac의 응답 길이가 올바르지 않습니다.") }
                length = parsed
            }
            guard code != 304 || length == 0 else { throw invalid("Mac의 조건부 응답에 잘못된 본문이 있습니다.") }
            status = code; expectedBytes = length; headers = fields
            let options = fields["connection"]?.split(separator:",").map { $0.trimmingCharacters(in:.whitespaces).lowercased() } ?? []
            reusable = first[0] == "HTTP/1.1" && [200,304].contains(code)
                && expectedNodeID != nil && fields["x-autoapprove-node"] == expectedNodeID
                && options.contains("keep-alive") && !options.contains("close")
            buffer = buffer.subdata(in:boundary.upperBound..<buffer.endIndex)
        }
        guard let fields = headers, let length = expectedBytes else { return nil }
        guard buffer.count <= length else { throw invalid("Mac의 응답 뒤에 잘못된 데이터가 있습니다.") }
        guard buffer.count == length else { return nil }
        let body = status != 304 && fields["content-encoding"]?.lowercased() == "gzip" ? try RemoteGzipDecoder.complete(buffer) : buffer
        var response = RemoteHTTPResponse(status:status,body:body,contentType:fields["content-type"] ?? "application/json; charset=utf-8")
        response.entityTag = fields["etag"]; response.nodeID = fields["x-autoapprove-node"]
        complete = true; buffer = Data(); return response
    }
    func finish() throws {
        guard complete else { throw RemoteHTTPError(503,"Mac의 응답이 전송 중 끊겼습니다. 같은 원본을 다시 확인합니다.") }
    }
}

@main struct PeerHeaderCheck {
    enum Failure:Error {case mismatch(String)}
    static func require(_ value:Bool,_ reason:String) throws {if !value {throw Failure.mismatch(reason)}}
    static var seed:UInt64=0x123456789abcdef
    static func random(_ limit:Int) -> Int {seed = seed &* 6364136223846793005 &+ 1442695040888963407;return Int((seed>>32)%UInt64(limit))}
    static func sha(_ data:Data) -> String {SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()}
    static func emit(_ value:[String:Any]) throws {print(String(decoding:try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),as:UTF8.self))}
    static func wire(_ body:Data=Data(),padding:Int=0,status:Int=200,node:String="owner",gzip:Bool=false) throws -> Data {
        var payload=body
        if gzip {
            let encoder=try RemoteGzipEncoder();payload=Data()
            if body.isEmpty {payload=try encoder.encode(body,final:true)}
            else {for offset in stride(from:0,to:body.count,by:2_000_000) {let end=min(body.count,offset+2_000_000);payload.append(try encoder.encode(body.subdata(in:offset..<end),final:end==body.count))}}
        }
        let header="HTTP/1.1 \(status) OK\r\nContent-Length: \(payload.count)\r\nX-AutoApprove-Node: \(node)\r\nConnection: keep-alive\r\nETag: \"same\"\r\nX-Padding: "+String(repeating:"a",count:padding)+"\r\n"+(gzip ? "Content-Encoding: gzip\r\n":"")+"\r\n"
        return Data(header.utf8)+payload
    }
    static func chunks(_ data:Data,width:Int,empty:Bool=false,foreign:Bool=false) -> [Data] {
        var result=[Data]()
        for offset in stride(from:0,to:data.count,by:width) {
            let chunk=data.subdata(in:offset..<min(data.count,offset+width))
            if foreign {
                let cocoa=chunk.withUnsafeBytes {NSData(bytes:$0.baseAddress,length:$0.count)}
                if offset%2==0 {result.append(Data(referencing:cocoa))}
                else {
                    let framed=Data(repeating:7,count:19)+chunk+Data([7])
                    let base=framed.withUnsafeBytes {NSData(bytes:$0.baseAddress,length:$0.count)}
                    result.append(Data(referencing:base).dropFirst(19).prefix(chunk.count))
                }
            }else {result.append(chunk)}
            if empty && offset+width<data.count {result.append(Data())}
        }
        if result.isEmpty {result.append(Data())}
        return result
    }
    static func error(_ error:Error) -> [String:Any] {
        guard let value=error as? RemoteHTTPError else {return ["unexpected":String(describing:error)]}
        return ["status":value.status,"message":value.message,"diagnostics":value.diagnostics ?? [:]]
    }
    static func response(_ value:RemoteHTTPResponse) -> [String:Any] {
        ["status":value.status,"bytes":value.body.count,"index":value.body.startIndex,"body":sha(value.body),"type":value.contentType,
         "etag":value.entityTag.map {$0 as Any} ?? NSNull(),"node":value.nodeID.map {$0 as Any} ?? NSNull()]
    }
    private static func observe(_ decoder: any HeaderDecoding,_ values:[Data]) throws -> [String:Any] {
        var trace=Data(),result:[String:Any]=[:],calls=0
        func state(_ flag:Int) {
            for number in [calls,flag,decoder.receivedBytes,decoder.expectedBytes ?? -1,decoder.allowsConnectionReuse ? 1:0] {
                var value=Int64(number);withUnsafeBytes(of:&value){trace.append(contentsOf:$0)}
            }
        }
        for chunk in values {
            let saved=Array(chunk),index=chunk.startIndex;calls+=1
            var rejected=false
            do {if let value=try decoder.append(chunk) {result["response"]=response(value);state(1)}else {state(0)}}
            catch {result["appendError"]=Self.error(error);state(2);rejected=true}
            try require(Array(chunk)==saved && chunk.startIndex==index,"Caller input changed")
            if rejected {break}
        }
        do {try decoder.finish();result["finished"]=true}catch {result["finishError"]=Self.error(error)}
        // Preserve the old observable behavior after completion or rejection.
        calls+=1
        do {if let value=try decoder.append(Data()) {result["after"]=response(value);state(3)}else {state(4)}}catch {result["afterError"]=Self.error(error);state(5)}
        result["trace"]=sha(trace);result["calls"]=calls;result["received"]=decoder.receivedBytes;result["expected"]=decoder.expectedBytes ?? -1;result["reuse"]=decoder.allowsConnectionReuse
        return result
    }
    static func outcome(_ values:[Data],node:String?,gzip:Bool) throws -> [String:Any] {
        let actual=try observe(RemotePeerResponseDecoder(expectedNodeID:node,acceptsGzip:gzip),values)
        let legacy=try observe(LegacyPeerResponseDecoder(expectedNodeID:node,acceptsGzip:gzip),values)
        let left=try JSONSerialization.data(withJSONObject:actual,options:[.sortedKeys])
        let right=try JSONSerialization.data(withJSONObject:legacy,options:[.sortedKeys])
        try require(left==right,"Actual Core differs from the retained full-scan decoder")
        return actual
    }
    static func check() throws {
        var count=0
        func record(_ name:String,_ data:Data,width:Int=64000,empty:Bool=false,foreign:Bool=false,node:String?="owner",gzip:Bool=true) throws {
            var result=try outcome(chunks(data,width:width,empty:empty,foreign:foreign),node:node,gzip:gzip);result["case"]=name;count+=1
        }
        let body=Data("합성 원본🙂 e\u{301}\r\n\u{0}".utf8)
        for padding in [0,1,14,15,16,17,27,28,29,30,31,32,33,63,64,127,1024,8192] {
            let packet=try wire(body,padding:padding)
            for width in [1,2,3,4,7,17,28,29,30,31,32,33,64,127,64000] {
                try record("valid-\(padding)-\(width)",packet,width:width)
                if padding<128 {try record("storage-\(padding)-\(width)",packet,width:width,empty:true,foreign:true)}
            }
        }
        let base="HTTP/1.1 200 OK\r\nContent-Length: 0\r\nX-Padding: "
        for boundary in [16380,16381,16382,16383,16384,16385,16386] {
            let head=Data((base+String(repeating:"a",count:boundary-base.utf8.count)).utf8),packet=head+Data([13,10,13,10])
            for width in [1,3,17,31,32,16380,16384,64000] {try record("limit-\(boundary)-\(width)",packet,width:width)}
            for suffix in 0...4 {var result=try outcome([Data(packet.prefix(packet.count-suffix)),Data(packet.suffix(suffix))],node:"owner",gzip:true);result["case"]="limit-tail-\(boundary)-\(suffix)";count+=1}
        }
        let invalid=["", "HTTP/2 200 OK\r\nContent-Length: 0", "HTTP/1.1 199 OK\r\nContent-Length: 0", "HTTP/1.1 600 OK\r\nContent-Length: 0",
            "HTTP/1.1 200 OK", "HTTP/1.1 200 OK\r\nContent-Length: -1", "HTTP/1.1 200 OK\r\nContent-Length: 1x", "HTTP/1.1 200 OK\r\nContent-Length: 4000001",
            "HTTP/1.1 200 OK\r\nContent-Length: 0\r\ncontent-length: 0", "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nTransfer-Encoding: chunked",
            "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nBad Header: value", "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nX-Test: a\u{7f}",
            "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nContent-Encoding: br", "HTTP/1.1 304 OK\r\nContent-Length: 1", "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nX-AutoApprove-Node: other"]
        for (index,header) in invalid.enumerated() {for width in [1,3,17,31,32,64000] {try record("invalid-\(index)-\(width)",Data((header+"\r\n\r\n").utf8),width:width)}}
        for status in [200,201,204,304,403,503] {for expected in [true,false] {for compressed in [false,true] {
            let packet=try wire(status==304 ? Data():body,status:status,gzip:compressed)
            for width in [1,17,64000] {try record("status-\(status)-\(expected)-\(compressed)-\(width)",packet,width:width,node:expected ? "owner":nil,gzip:compressed)}
        }}}
        for version in ["HTTP/1.0","HTTP/1.1"] {for option in ["keep-alive","close","keep-alive, close","KEEP-ALIVE","upgrade",""] {
            let packet=Data("\(version) 304 Not Modified\r\nX-AutoApprove-Node: owner\r\nConnection: \(option)\r\n\r\n".utf8)
            for width in [1,17,64000] {try record("reuse-\(version)-\(option)-\(width)",packet,width:width)}
        }}
        for index in 0..<1000 {
            var packet=try wire(body,padding:random(256))
            for _ in 0..<1+random(4) {packet[random(packet.count)]=UInt8(random(256))}
            try record("fuzz-\(index)",packet,width:[1,3,7,17,31,32,127,64000][random(8)],empty:index%3==0,foreign:index%5==0)
        }
        for size in [0,1,2,3,4,16384,16385,64000,64001] {try record("plain-\(size)",Data(repeating:65,count:size),width:size==64001 ? 64001:64000)}
        let large=Data(repeating:120,count:4_000_000),exact=try wire(large)
        try record("body-exact",exact);try record("body-extra",exact+Data([0]))
        for total in [4_016_388,4_016_389] {try record("wire-limit-\(total)",exact+Data(repeating:65,count:total-exact.count))}
        try record("compressed-exact",try wire(large,gzip:true));try record("compressed-bomb",try wire(large+Data([120]),gzip:true))
        try require(count==1814,"Compatibility corpus count changed")
        try emit(["summary":true,"cases":count,"scope":"Actual Core and retained full-scan response,step trace,metadata/errors and caller input"])
    }
    static func workBound() throws {
        var checks=0
        for width in [1,2,3,4,7,17,28,29,30,31,32,33,64,8192] {
            let input=Data(repeating:65,count:8192),decoder=RemotePeerResponseDecoder();var previous=0,examined=0,calls=0
            for chunk in chunks(input,width:width,empty:true) {
                let expected=decoder.receivedBytes+chunk.count;try require(try decoder.append(chunk)==nil,"Incomplete header completed")
                let fields=Dictionary(uniqueKeysWithValues:Mirror(reflecting:decoder).children.compactMap {child in child.label.map {($0,child.value)}})
                guard let cursor=fields["status"] as? Int else {throw Failure.mismatch("Candidate cursor metadata missing")}
                examined+=max(0,expected-previous);calls+=1
                try require(cursor==max(0,expected-3),"Cursor is not the required three-byte overlap");previous=cursor
            }
            try require(examined<=input.count+3*calls,"Search range work is not linear");checks+=1
        }
        try require(checks==14,"Search-bound corpus count changed")
        try emit(["workBound":true,"cases":checks,"threeByteOverlapExact":true,"linearSearchRanges":true])
    }
    static func main() throws {
        try check()
        try workBound()
        print("PEER_HEADER cases 1814; search-bound cases 14; exact legacy bytes/errors/steps; caller storage exact")
    }
}
