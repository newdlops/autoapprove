import Foundation
import AutoApproveCore

extension ApprovalTests {
    func testHTTPRequestComponentsPreserveTargetAndValueIsolation() throws {
        let targets = ["/", "/?", "/index.html?webNode=fixture", "/api/terminal?session=process%3A42%2Bstart&view=text",
            "/a%2Fb?x=%23%26%3D", "/a/../b?empty=", "/한글/e\u{301}/🙂?text=한글%2B말",
            "/%252F?value=%252B", "/path??value=a?b", "/path?semi=a;b&literal=%25"]
        for target in targets {
            let expected = URLComponents(string: "http://localhost" + target)!
            var request = try RemoteHTTPRequest.parse(Data("GET \(target) HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8))!
            try expectEqual(request.target, target)
            try expectEqual(request.components, expected)
            try expectEqual(request.path, expected.path)
            var edited = request.components
            edited.host = "elsewhere.example"; edited.path = "/changed"; edited.queryItems = [URLQueryItem(name: "node", value: "elsewhere")]
            request.clientAddress = "127.0.0.2"
            try expectEqual(request.components, expected, "An edited components value cannot alter its HTTP request")
            try expectEqual(request.path, expected.path)
            let other = try RemoteHTTPRequest.parse(Data("GET /api/state?node=other HTTP/1.0\r\nHost: localhost\r\n\r\n".utf8))!
            try expectEqual(other.path, "/api/state"); try expectEqual(other.parameter("node"), "other")
            try expectEqual(request.components, expected, "A later message cannot replace this message's target")
        }
    }

    func testHTTPRequestQueryKeepsFormEscapesDuplicatesAndEmptyValues() throws {
        let target = "/api/terminal?session=process%3Adate+with+spaces%2Band&node=first&node=second&empty=&bare&bare=present&key+name=a%26b%3Dc&key%2Bname=%252B&unicode=%ED%95%9C%EA%B8%80%F0%9F%99%82"
        let request = try RemoteHTTPRequest.parse(Data("GET \(target) HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8))!
        for _ in 0..<3 {
            try expectEqual(request.parameter("session"), "process:date with spaces+and")
            try expectEqual(request.parameter("node"), "first")
            try expectEqual(request.parameter("empty"), "")
            try expectEqual(request.parameter("bare"), "present")
            try expectEqual(request.parameter("key name"), "a&b=c")
            try expectEqual(request.parameter("key+name"), "%2B")
            try expectEqual(request.parameter("unicode"), "한글🙂")
            try expectNil(request.parameter("missing"))
        }
        let next = try RemoteHTTPRequest.parse(Data("GET /api/state HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8))!
        try expectNil(next.parameter("session")); try expectNil(next.components.query)
    }

    func testHTTPRequestTargetRetainsFramingAndOriginBoundaries() throws {
        let body = Data("{\"node\":\"first\"}".utf8)
        let head = Data("POST /api/action?node=local HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        try expectNil(try RemoteHTTPRequest.parse(head + body.dropLast()))
        let complete = try RemoteHTTPRequest.parse(head + body)!
        try expectEqual(complete.body, body); try expectEqual(complete.parameter("node"), "local")
        try expectEqual(try complete.json()["node"] as? String, "first")
        let cases: [(String, Int)] = [
            ("GET /api/state#fragment HTTP/1.1\r\nHost: localhost\r\n\r\n",400),
            ("GET //other/api/state HTTP/1.1\r\nHost: localhost\r\n\r\n",400),
            ("GET http://other/api/state HTTP/1.1\r\nHost: localhost\r\n\r\n",400),
            ("GET / HTTP/2\r\nHost: localhost\r\n\r\n",400),
            ("GET / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nContent-Length: 2\r\n\r\n",400),
            ("GET / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n",400),
            ("POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: -1\r\n\r\n",413),
            ("GET / HTTP/1.1\r\n" + String(repeating:"x",count:16_385),431),
            (String(repeating:"x",count:280_001),413)]
        for (wire,status) in cases {
            do { _ = try RemoteHTTPRequest.parse(Data(wire.utf8)); throw AppError.message("Malformed message was accepted") }
            catch let error as RemoteHTTPError { try expectEqual(error.status,status) }
        }
        try expectThrows(try RemoteHTTPRequest.parse(head + body + Data("GET / HTTP/1.1\r\n\r\n".utf8)))
        for extra in ["Origin: http://elsewhere.example\r\n", "Sec-Fetch-Site: cross-site\r\n"] {
            let request = try RemoteHTTPRequest.parse(Data("GET /api/state?node=local HTTP/1.1\r\nHost: localhost\r\n\(extra)\r\n".utf8))!
            do { try request.validateOrigin(); throw AppError.message("Foreign request was accepted") }
            catch let error as RemoteHTTPError { try expectEqual(error.status,403) }
        }
    }
}
