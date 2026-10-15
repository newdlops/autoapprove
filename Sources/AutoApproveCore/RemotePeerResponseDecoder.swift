import Foundation

/// One finite HTTP response. Headers parse once; bytes and gzip output stay
/// bounded. A malformed or mismatched peer can never become a preferred route.
public final class RemotePeerResponseDecoder {
    private let expectedNodeID: String?
    private let acceptsGzip: Bool
    private var buffer = Data()
    private var headers: [String:String]?
    private var status = 0
    private var complete = false
    public private(set) var receivedBytes = 0
    public private(set) var expectedBytes: Int?
    public init(expectedNodeID: String? = nil, acceptsGzip: Bool = false) {
        self.expectedNodeID = expectedNodeID; self.acceptsGzip = acceptsGzip
    }
    private func invalid(_ message: String) -> RemoteHTTPError {
        RemoteHTTPError(502,message,diagnostics:["failureKind":"protocol"])
    }
    public func append(_ data: Data) throws -> RemoteHTTPResponse? {
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
    public func finish() throws {
        guard complete else { throw RemoteHTTPError(503,"Mac의 응답이 전송 중 끊겼습니다. 같은 원본을 다시 확인합니다.") }
    }
}
