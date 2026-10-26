import Foundation

public struct CloudflareRelayPacket:Sendable {
    public enum Kind:UInt8,Sendable {case hello=0,request,headers,data,end,cancel,credit,socketData,socketClose,compressedData,socketCredit}
    public static let maximumSize=2_032_780
    public let kind:Kind,id:UInt32,payload:Data
    public init(kind:Kind,id:UInt32,payload:Data = Data()) {self.kind=kind;self.id=id;self.payload=payload}
    public func encoded() throws -> Data {
        guard payload.count <= Self.maximumSize-8,(id == 0) == (kind == .hello) else {throw Self.invalid()}
        var data=Data([65,65,1,kind.rawValue]);Self.append(id,to:&data);data.append(payload);return data
    }
    public static func decode(_ data:Data) throws -> Self {
        guard (8...maximumSize).contains(data.count) else {throw invalid()}
        let bytes=[UInt8](data.prefix(8))
        guard bytes[0] == 65,bytes[1] == 65,bytes[2] == 1,let kind=Kind(rawValue:bytes[3]) else {throw invalid()}
        let id=read(bytes,at:4)
        guard (id == 0) == (kind == .hello) else {throw invalid()}
        return Self(kind:kind,id:id,payload:Data(data.dropFirst(8)))
    }
    public struct Request:Sendable {
        public let method:String,path:String,headers:[String:String],body:Data
        public let socket:Bool
    }
    public func request() throws -> Request {
        guard kind == .request,payload.count >= 4 else {throw Self.invalid()}
        let prefix=[UInt8](payload.prefix(4)),size=Int(Self.read(prefix,at:0))
        guard (2...32768).contains(size),payload.count >= 4+size,payload.count-4-size <= 2_000_000,
              let value=try? JSONSerialization.jsonObject(with:payload.subdata(in:4..<4+size)) as? JSONObject,
              let method=value["method"] as? String,["GET","POST","HEAD","OPTIONS"].contains(method),
              let path=value["path"] as? String,path.hasPrefix("/"),!path.hasPrefix("//"),path.utf8.count <= 16384,
              !path.utf8.contains(where:{$0 < 32 || $0 == 127}),!path.contains("\\"),!path.contains("#"),
              let headers=value["headers"] as? [String:String],headers.count <= 100,
              headers.allSatisfy({!$0.key.isEmpty && $0.key.utf8.allSatisfy {byte in byte > 32 && byte < 127 && ![UInt8(58),40,41,60,62,64,44,59,92,34,47,91,93,63,61,123,125].contains(byte)} && !$0.value.utf8.contains(where:{$0 == 0 || $0 == 10 || $0 == 13})}) else {throw Self.invalid()}
        let socket = value["socket"] as? Bool == true
        if socket {
            guard method == "GET",payload.count == 4+size,URLComponents(string:"http://localhost"+path)?.path == "/api/input/socket" else {throw Self.invalid()}
        }
        return Request(method:method,path:path,headers:headers,body:Data(payload.dropFirst(4+size)),socket:socket)
    }
    public func credit() throws -> Int {
        guard kind == .credit || kind == .socketCredit,payload.count == 4 else {throw Self.invalid()}
        let amount=Int(Self.read([UInt8](payload),at:0))
        guard (1...262144).contains(amount) else {throw Self.invalid()};return amount
    }
    public static func requestPayload(method:String,path:String,headers:[String:String],body:Data = Data(),socket:Bool = false) throws -> Data {
        var object:JSONObject = ["method":method,"path":path,"headers":headers];if socket {object["socket"] = true}
        let metadata=try JSONSerialization.data(withJSONObject:object)
        guard metadata.count <= 32768,body.count <= 2_000_000 else {throw invalid()}
        var data=Data();append(UInt32(metadata.count),to:&data);data.append(metadata);data.append(body);return data
    }
    private static func append(_ value:UInt32,to data:inout Data) {
        data.append(UInt8((value>>24)&255));data.append(UInt8((value>>16)&255));data.append(UInt8((value>>8)&255));data.append(UInt8(value&255))
    }
    private static func read(_ bytes:[UInt8],at:Int)->UInt32 {
        UInt32(bytes[at])<<24|UInt32(bytes[at+1])<<16|UInt32(bytes[at+2])<<8|UInt32(bytes[at+3])
    }
    private static func invalid()->AppError {.message("HTTPS 중계 응답을 확인하지 못했습니다. 다시 연결해주세요.")}
}
