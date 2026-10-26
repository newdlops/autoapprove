import Foundation
import Network
import CryptoKit
import Security

public enum RemoteTunnelProvider: String, Codable, CaseIterable, Sendable {
    case managed, quick, named, external
    public var title: String {
        switch self {case .managed:return "Cloudflare 고정 주소";case .quick:return "Cloudflare 임시 주소";case .named:return "Cloudflare 토큰 직접 입력";case .external:return "기존 로컬 터널 연결"}
    }
}

public struct RemoteTunnelConfiguration: Codable, Equatable, Sendable {
    public var provider: RemoteTunnelProvider = .quick
    public var publicURL = ""
    public var executable = ""
    public var port: UInt16 = 8766
    public var enabled = false
    public var tunnelID: String?
    public init() {}
    public static func origin(_ value: String) throws -> String {
        guard var url = URLComponents(string:value.trimmingCharacters(in:.whitespacesAndNewlines)), url.scheme == "https",
              url.user == nil, url.password == nil, let host=url.host?.lowercased(), host.count <= 253,
              host.contains("."), !RemoteNetworkAddress.isLocalHost(host), IPv4Address(host) == nil, IPv6Address(host) == nil,
              host.split(separator:".",omittingEmptySubsequences:false).allSatisfy({ label in
                  !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
              }), url.port == nil || url.port == 443, ["","/"].contains(url.path), url.query == nil, url.fragment == nil else {
            throw AppError.message("공개 HTTPS 도메인만 입력해주세요. 경로·접속 키·쿼리는 넣지 않습니다.")
        }
        url.host=host; url.port=nil; url.path=""; return url.string!
    }
    public func validated() throws -> Self {
        var value=self
        guard port > 0 else { throw AppError.message("터널 연결 포트는 1~65535로 입력해주세요.") }
        if provider != .quick { value.publicURL=try Self.origin(publicURL) }
        if provider == .managed, tunnelID.flatMap(UUID.init(uuidString:)) == nil {throw AppError.message("Cloudflare 승인을 마치고 등록된 도메인에 연결해주세요.")}
        if !executable.isEmpty {
            guard executable.hasPrefix("/"), !executable.contains("\0"), FileManager.default.isExecutableFile(atPath:executable) else { throw AppError.message("실행 가능한 cloudflared 파일을 선택해주세요.") }
        }
        return value
    }
}

public struct RemoteTunnelStatus: Equatable, Sendable {
    public var phase = "off"
    public var provider: RemoteTunnelProvider = .quick
    public var detail = "다른 네트워크에서 접속이 꺼져 있습니다."
    public var publicURL: String?
    public var localURL: String?
    public var ready: Bool { phase == "ready" }
    public var active: Bool { !["off","failed"].contains(phase) }
    public init() {}
}

/// Public traffic enters a separate authenticated loopback listener. The LAN
/// listener's host/origin rules and unauthenticated discovery remain unchanged.
@MainActor public final class RemoteTunnelGateway {
    private struct Session { let expires: TimeInterval }
    private struct Client { let connection: RemoteHTTPConnection; var session: String?; var streaming=false }
    private let queue = DispatchQueue(label:"autoapprove.tunnel.gateway")
    private var listener: NWListener?
    private var deadlines: RemoteHTTPDeadlines?
    private var clients: [UUID:Client] = [:]
    private var sessions: [String:Session] = [:]
    private var expiryTask: Task<Void,Never>?
    private var epoch = UUID()
    private var origin: String?
    private let polling: Bool
    private let handler: @MainActor (RemoteHTTPRequest) async -> RemoteHTTPResponse
    private var failedAt: TimeInterval = 0, failedAttempts = 0
    private let sessionDuration: TimeInterval
    public private(set) var port: UInt16?
    public let accessKey: String
    public let probe: String
    public var sessionCount: Int { sessions.count }
    public init(polling: Bool = false, sessionDuration: TimeInterval = 28800,
                handler: @escaping @MainActor (RemoteHTTPRequest) async -> RemoteHTTPResponse) throws {
        self.polling=polling; self.handler=handler; self.sessionDuration=max(1,min(28800,sessionDuration))
        accessKey=try Self.random(); probe=try Self.random()
    }
    private static func random() throws -> String {
        var bytes=[UInt8](repeating:0,count:32)
        guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes) == errSecSuccess else { throw AppError.message("접속 키를 만들지 못했습니다. 다시 연결해주세요.") }
        return Data(bytes).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
    }
    public func setOrigin(_ supplied: String) throws {
        let next=try RemoteTunnelConfiguration.origin(supplied)
        if origin != next { sessions.removeAll(); for value in clients.values { value.connection.close() }; clients.removeAll() }
        origin=next
    }
    public func start(port: UInt16) async throws {
        stop(); let epoch=UUID(); self.epoch=epoch
        let parameters=RemoteLAN.tcpParameters()
        parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
        let listener=try NWListener(using:parameters,on:NWEndpoint.Port(rawValue:port)!); self.listener=listener
        let deadlines=RemoteHTTPDeadlines(queue:queue); self.deadlines=deadlines
        listener.newConnectionHandler={ [weak self] connection in Task { @MainActor in
            guard let self, self.epoch == epoch, self.listener != nil, self.clients.count < 32 else { connection.cancel(); return }
            let id=UUID()
            let client=RemoteHTTPConnection(connection,queue:self.queue,deadlines:deadlines,handler:{ [weak self] request in
                guard let self, self.epoch == epoch, self.clients[id] != nil else { return .error(RemoteHTTPError(503,"터널 연결이 종료되었습니다.")) }
                let session=self.session(request)
                self.clients[id]?.session=session
                if session != nil, request.method == "GET", request.path.hasSuffix("/stream") {
                    guard self.clients.values.filter({$0.streaming}).count < 12 else { return .error(RemoteHTTPError(429,"실시간 연결이 많습니다. 다른 터미널 화면을 닫고 다시 시도해주세요.")) }
                    self.clients[id]?.streaming=true
                }
                return await self.respond(request,session:session,client:id)
            },onClose:{ [weak self] in Task { @MainActor in self?.clients.removeValue(forKey:id) } })
            self.clients[id]=Client(connection:client); client.start()
        } }
        var openingTimeout:Task<Void,Never>?
        defer {openingTimeout?.cancel()}
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            var completed=false
            openingTimeout=Task { @MainActor in
                do {try await Task.sleep(for:.seconds(5))} catch {return}
                guard !completed else {return};completed=true;listener.cancel()
                continuation.resume(throwing:AppError.message("터널 서비스 포트를 열지 못했습니다. 다른 포트를 선택해주세요."))
            }
            listener.stateUpdateHandler={ [weak self] state in Task { @MainActor in
                guard !completed else { return }
                switch state {
                case .ready:
                    completed=true; self?.port=listener.port?.rawValue; continuation.resume()
                case .failed(let error), .waiting(let error): completed=true; continuation.resume(throwing:error)
                case .cancelled: completed=true; continuation.resume(throwing:CancellationError())
                default: break
                }
            } }
            listener.start(queue:queue)
        }
        expiryTask=Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for:.seconds(1)) } catch { return }
                guard let self else { return }; self.expire()
            }
        }
    }
    public func stop() {
        epoch=UUID(); listener?.cancel(); listener=nil; port=nil
        expiryTask?.cancel(); expiryTask=nil; sessions.removeAll()
        for value in clients.values { value.connection.close() }; clients.removeAll(); deadlines=nil
    }
    public func disconnectClients() {
        for value in clients.values { value.connection.close() }; clients.removeAll()
    }
    private func expire() {
        let now=ProcessInfo.processInfo.systemUptime
        sessions=sessions.filter { $0.value.expires > now }
        for value in clients.values where value.session != nil && sessions[value.session!] == nil { value.connection.close() }
    }
    private func session(_ request: RemoteHTTPRequest) -> String? {
        let cookies=(request.headers["cookie"] ?? "").split(separator:";").map { $0.trimmingCharacters(in:.whitespaces) }
        let matching=cookies.filter { $0.hasPrefix("__Host-autoapprove_tunnel=") }
        guard matching.count == 1, let token=matching.first?.split(separator:"=",maxSplits:1).last.map(String.init),
              let session=sessions[token], session.expires > ProcessInfo.processInfo.systemUptime else { return nil }
        return token
    }
    private func checkOrigin(_ request: RemoteHTTPRequest) throws {
        guard let origin, let port, let host=request.headers["host"]?.lowercased(),
              host == URLComponents(string:origin)?.host || host == (URLComponents(string:origin)?.host ?? "")+":443" || host == "127.0.0.1:\(port)" || host == "127.0.0.1" || host == "localhost" || host == "localhost:\(port)" else { throw RemoteHTTPError(403,"접속한 터널 주소를 확인해주세요.") }
        if let supplied=request.headers["origin"], supplied != origin { throw RemoteHTTPError(403,"다른 웹사이트의 요청은 처리하지 않습니다.") }
        if request.method == "POST", request.headers["origin"] != origin { throw RemoteHTTPError(403,"접속 페이지에서 직접 요청해주세요.") }
        if let site=request.headers["sec-fetch-site"], !["same-origin","none"].contains(site) {
            guard request.method == "GET", ["/","/auth","/index.html"].contains(request.path), request.headers["sec-fetch-mode"] == "navigate", request.headers["sec-fetch-dest"] == "document" else { throw RemoteHTTPError(403,"접속 페이지에서 직접 요청해주세요.") }
        }
    }
    private func cookie(_ token: String, age: Int) -> String {
        "__Host-autoapprove_tunnel=\(token); Path=/; Max-Age=\(age); Secure; HttpOnly; SameSite=Strict"
    }
    private func respond(_ request: RemoteHTTPRequest, session: String?, client: UUID) async -> RemoteHTTPResponse {
        do {
            try checkOrigin(request)
            guard ["GET","POST"].contains(request.method) else { throw RemoteHTTPError(405,"지원하지 않는 요청입니다.") }
            if request.path == "/auth/probe", request.method == "GET" { return try .object(["probe":probe]) }
            if request.path == "/auth/login", request.method == "POST" {
                guard request.body.count <= 1024, let key=try request.json()["key"] as? String, key.utf8.count <= 256 else { throw RemoteHTTPError(400,"접속 키를 입력해주세요.") }
                let expected=Array(SHA256.hash(data:Data(accessKey.utf8))), actual=Array(SHA256.hash(data:Data(key.utf8)))
                let equal=zip(expected,actual).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
                guard equal else {
                    let now=ProcessInfo.processInfo.systemUptime
                    if now-failedAt > 60 { failedAt=now; failedAttempts=0 }
                    failedAttempts += 1
                    throw RemoteHTTPError(failedAttempts > 30 ? 429 : 401,failedAttempts > 30 ? "접속 시도가 많습니다. Mac에서 키를 확인하고 잠시 뒤 다시 시도해주세요." : "접속 키가 맞지 않습니다. Mac의 연결 설정에서 새 링크를 확인해주세요.")
                }
                expire()
                guard sessions.count < 32 else { throw RemoteHTTPError(429,"접속 중인 브라우저가 많습니다. 다른 기기에서 로그아웃해주세요.") }
                let token=try Self.random(); sessions[token]=Session(expires:ProcessInfo.processInfo.systemUptime+sessionDuration)
                var response=try RemoteHTTPResponse.object(["authenticated":true]); response.setCookie=cookie(token,age:Int(sessionDuration)); return response
            }
            if request.path == "/auth/logout", request.method == "POST" {
                if let session {
                    sessions.removeValue(forKey:session)
                    for (id,value) in clients where id != client && value.session == session { value.connection.close() }
                }
                var response=try RemoteHTTPResponse.object(["authenticated":false]); response.setCookie=cookie("",age:0); return response
            }
            if request.method == "GET", ["/tunnel-login.js","/tunnel-login.css","/app.css","/favicon.svg"].contains(request.path) { return try Self.asset(String(request.path.dropFirst())) }
            if session == nil || request.path == "/auth" {
                if request.method == "GET", ["/","/auth","/index.html"].contains(request.path) { return try Self.asset("tunnel-login.html") }
                throw RemoteHTTPError(401,"접속 시간이 끝났습니다. Mac의 접속 키로 다시 연결해주세요.")
            }
            // Quick Tunnels do not support SSE. Never expose a stalled stream
            // as an input-capable terminal; the page uses sequential JSON reads.
            if polling && request.path.hasSuffix("/stream") { throw RemoteHTTPError(406,"임시 터널에서는 화면을 순서대로 조회합니다.") }
            if request.path.hasPrefix("/api/update/") { throw RemoteHTTPError(403,"앱 설치 파일은 같은 네트워크에서 확인해주세요.") }
            var headers=request.headers
            for key in ["cookie","authorization","forwarded","x-forwarded-host","x-forwarded-proto","cf-access-jwt-assertion"] { headers.removeValue(forKey:key) }
            headers["host"]="127.0.0.1"; headers["origin"]="http://127.0.0.1"; headers["sec-fetch-site"]="same-origin"
            let forwarded=RemoteHTTPRequest(method:request.method,target:request.target,headers:headers,body:request.body)
            var response=await handler(forwarded)
            if response.contentType.hasPrefix("text/html"), response.status == 200, let html=String(data:response.body,encoding:.utf8) {
                response.body=Data(html.replacingOccurrences(of:"<head>",with:"<head><meta name=\"autoapprove-tunnel\" content=\"\(polling ? "polling" : "stream")\">").utf8)
            }
            return response
        } catch { return .error(error) }
    }
    static func asset(_ name: String) throws -> RemoteHTTPResponse {
        let type=name.hasSuffix(".html") ? "text/html" : name.hasSuffix(".css") ? "text/css" : name.hasSuffix(".svg") ? "image/svg+xml" : "text/javascript"
        let file="AutoApprove_AutoApproveCore.bundle/RemoteWeb/"+name
        let executable=URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL
        let packaged=[Bundle.main.resourceURL?.appendingPathComponent(file),executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/"+file)]
        for url in packaged.compactMap({$0}) where FileManager.default.fileExists(atPath:url.path) {
            return RemoteHTTPResponse(body:try Data(contentsOf:url),contentType:type+"; charset=utf-8")
        }
        guard let url=Bundle.module.url(forResource:name,withExtension:nil,subdirectory:"RemoteWeb") else { throw AppError.message("웹 접속 파일을 찾지 못했습니다.") }
        return RemoteHTTPResponse(body:try Data(contentsOf:url),contentType:type+"; charset=utf-8")
    }
}
