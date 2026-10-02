import Foundation
import Network
import Darwin

public struct RemoteNetworkStatus: Codable, Equatable {
    public var enabled = false
    public var ready = false
    public var urls: [String] = []
    public var port: UInt16?
    public var peerCount = 0
    public var detail = "같은 네트워크에서 웹 접속이 꺼져 있습니다."
    /// Hotspot hosts may use their cellular resolver and cannot resolve .local.
    /// Keep named URLs for Bonjour peers, but use a literal address for phone QR codes.
    public var directURLs: [String] {
        urls.filter {
            guard let host = URLComponents(string: $0)?.host else { return false }
            return IPv4Address(host) != nil || IPv6Address(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) != nil
        }
    }
    public init() {}
}

public struct RemoteSessionView: Codable {
    public var session: AgentSession
    public var title: String
    public var phaseTitle: String
    public var canApprove: Bool
    public var canReveal: Bool
    public var canRead: Bool
    public var inputReason: String?
    public var keys: [String]
}

public struct RemoteNodeState: Codable {
    public var id: String
    public var name: String
    public var snapshot: EngineSnapshot
    public var sessions: [RemoteSessionView]
}

public struct RemoteNodeView: Codable {
    public var id: String
    public var name: String
    public var local: Bool
    public var online: Bool
    public var state: RemoteNodeState?
    public var error: String?
}

public struct RemoteDashboard: Codable {
    public var gatewayID: String
    public var nodes: [RemoteNodeView]
    public var updatedAt: Date
    public var discovery: String?
}

public struct RemoteTerminalFrame: Codable {
    public var sessionID: String
    public var screen: String
    public var revision: String
    public var observedAt: Date
    public var keys: [String]
    public var inputReason: String?
    public var appearance: TerminalAppearance? = nil
}

/// A browser that already has this revision only needs fresh controls and observation time.
private struct RemoteTerminalUpdate: Encodable {
    var sessionID: String
    var screen: String?
    var revision: String
    var observedAt: Date
    var keys: [String]
    var inputReason: String?
    var appearance: TerminalAppearance?
    init(_ frame: RemoteTerminalFrame, knownRevision: String?) {
        sessionID = frame.sessionID; revision = frame.revision; observedAt = frame.observedAt
        keys = frame.keys; inputReason = frame.inputReason
        screen = knownRevision == frame.revision ? nil : frame.screen
        appearance = knownRevision == frame.revision ? nil : frame.appearance
    }
}

@MainActor public final class RemoteNetworkService {
    public static let serviceType = "_autoapprove._tcp"
    public let nodeID: String
    public let name: String
    public var directDiscoveryInterval: TimeInterval = 45
    private weak var engine: ApprovalEngine?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var pathMonitor: NWPathMonitor?
    private var discoveryTask: Task<Void, Never>?
    private var lanInterfaces: [RemoteLANInterface] = []
    private let bonjourEnabled: Bool
    private let discoveryAddresses: () -> [String]
    private var namedAccess: RemoteNamedAccess?
    private var updatingNamedAccess = false
    private var publishedPortal = false
    public var port: UInt16? { listener?.port?.rawValue }
    private let queue = DispatchQueue(label: "autoapprove.web.listener")
    private var connections: [UUID: RemoteHTTPConnection] = [:]
    private var running = false
    private var generation = UUID()
    private var status = RemoteNetworkStatus()
    private let onStatus: (RemoteNetworkStatus) -> Void
    private struct Peer {
        var id: String
        var name: String
        var endpoint: NWEndpoint
        var available: Bool
        var manual: Bool
        var portal = false
        var bonjour = false
        var directlySeen: Date?
        var directAddress: String?
    }
    private var peers: [String: Peer] = [:]
    private var discoveryError: String?
    private struct Receipt: Codable {
        var id: String
        var fingerprint: String
        var response: Data?
        var status: Int?
    }
    private var receipts: [Receipt] = []
    private let receiptsURL: URL
    private let manualURL: URL
    private struct ManualPeer: Codable { var id: String; var name: String; var address: String }
    private var manualPeers: [ManualPeer] = []
    public init(engine: ApprovalEngine, nodeID: String, name: String? = nil, bonjourEnabled: Bool = true, discoveryAddresses: (() -> [String])? = nil, onStatus: @escaping (RemoteNetworkStatus) -> Void) {
        self.engine = engine; self.nodeID = nodeID
        self.bonjourEnabled = bonjourEnabled
        self.discoveryAddresses = discoveryAddresses ?? RemotePeerDiscovery.addresses
        self.name = name ?? Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        self.onStatus = onStatus
        receiptsURL = engine.paths.directory.appendingPathComponent("web-requests.json")
        manualURL = engine.paths.directory.appendingPathComponent("web-peers.json")
        receipts = (try? JSONDecoder().decode([Receipt].self, from: Data(contentsOf: receiptsURL))) ?? []
        manualPeers = (try? JSONDecoder().decode([ManualPeer].self, from: Data(contentsOf: manualURL))) ?? []
        for peer in manualPeers {
            if let endpoint = try? RemoteNetworkAddress.endpoint(peer.address), peer.id != nodeID {
                peers[peer.id] = Peer(id: peer.id, name: peer.name, endpoint: endpoint, available: true, manual: true)
            }
        }
    }
    public func start(port preferredPort: UInt16 = 8765, allowPortFallback: Bool = false) throws {
        guard !running else { return }
        let port = preferredPort
        let parameters = RemoteLAN.tcpParameters()
        lanInterfaces = RemoteLAN.interfaces(refresh: true)
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        let epoch = UUID(); generation = epoch; running = true; self.listener = listener
        publishedPortal = false
        if bonjourEnabled {
            listener.service = NWListener.Service(name: nodeID, type: Self.serviceType, domain: "local.", txtRecord: NWTXTRecord(["name": String(name.prefix(100)), "version": "1", "portal": "0"]))
        }
        // Keep NWListener's lifetime accept budget unlimited. Concurrent requests are
        // bounded by connections.count below, and each request has a deadline.
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.running, self.generation == epoch, self.connections.count < 32,
                      case .hostPort(let host, _) = connection.endpoint,
                      RemoteNetworkAddress.isLocalHost(String(describing: host)) else { connection.cancel(); return }
                let id = UUID()
                let client = RemoteHTTPConnection(connection, queue: self.queue, handler: { [weak self] request in
                    guard let self, self.running, self.generation == epoch else { return .error(RemoteHTTPError(503, "웹 접속이 꺼졌습니다.")) }
                    return await self.handle(request)
                }, onClose: { [weak self] in Task { @MainActor in self?.connections.removeValue(forKey: id) } })
                self.connections[id] = client; client.start()
            }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, self.running, self.generation == epoch else { return }
                switch state {
                case .ready:
                    self.status.ready = true; self.status.detail = "같은 네트워크의 휴대폰과 Mac에서 접속할 수 있습니다."
                    self.status.port = listener?.port?.rawValue ?? port
                    self.updateNamedAddresses()
                case .waiting(let error), .failed(let error):
                    if allowPortFallback, port != 0, case .posix(let code) = error,
                       code == .EADDRINUSE || code == .EINVAL {
                        // Let Network.framework allocate the fallback port atomically.
                        self.stop()
                        do { try self.start(port: 0) }
                        catch {
                            self.status.enabled = true
                            self.status.detail = "웹 연결을 열지 못했습니다. \(error.localizedDescription)"
                            self.emitStatus()
                        }
                        return
                    }
                    self.status.ready = false; self.status.urls = []; self.status.port = nil
                    self.status.detail = "웹 연결을 열지 못했습니다. 로컬 네트워크 권한과 포트 \(port)를 확인해주세요. \(error.localizedDescription)"
                default: break
                }
                self.emitStatus()
            }
        }
        status.enabled = true; status.detail = "웹 접속과 같은 네트워크의 Mac을 연결하고 있습니다."
        listener.start(queue: queue)
        if bonjourEnabled {
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: "local."), using: parameters)
            self.browser = browser
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                Task { @MainActor in
                    guard let self, self.running, self.generation == epoch else { return }
                    self.discovered(results)
                }
            }
            browser.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.running, self.generation == epoch else { return }
                    switch state {
                    case .ready: self.discoveryError = nil
                    case .waiting, .failed: self.discoveryError = "이름으로 Mac을 찾지 못해 같은 네트워크 주소에서 직접 찾고 있습니다. 기본 포트가 다르면 주소로 추가하세요."
                    default: break
                    }
                }
            }
            browser.start(queue: queue); emitStatus()
        }
        startDirectDiscovery(epoch: epoch)
        let monitor = NWPathMonitor(prohibitedInterfaceTypes: [.other, .cellular]); pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.running, self.generation == epoch, self.status.ready, let port = self.port else { return }
                let interfaces = RemoteLAN.interfaces(refresh: true)
                if interfaces != self.lanInterfaces {
                    self.lanInterfaces = interfaces
                    self.startDirectDiscovery(epoch: epoch)
                }
                self.status.port = port; self.updateNamedAddresses(); self.emitStatus()
            }
        }
        monitor.start(queue: queue)
    }
    private func startDirectDiscovery(epoch: UUID) {
        discoveryTask?.cancel()
        discoveryTask = Task { [weak self] in
            // Debounce interface changes and let the listener and Bonjour settle.
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            while !Task.isCancelled {
                guard let self, self.running, self.generation == epoch else { return }
                await self.discoverDirectPeers(epoch: epoch)
                do { try await Task.sleep(for: .seconds(max(1, self.directDiscoveryInterval))) } catch { return }
            }
        }
    }
    public func stop() {
        running = false; generation = UUID()
        discoveryTask?.cancel(); discoveryTask = nil
        namedAccess?.stop(); namedAccess = nil
        listener?.cancel(); listener = nil; browser?.cancel(); browser = nil
        pathMonitor?.cancel(); pathMonitor = nil
        let clients = Array(connections.values); connections.removeAll(); clients.forEach { $0.close() }
        peers = peers.filter { $0.value.manual }
        for id in Array(peers.keys) { peers[id]?.portal = false }
        status = RemoteNetworkStatus(); emitStatus()
    }
    private func emitStatus() { status.peerCount = peers.values.filter(\.available).count; onStatus(status) }
    private func updateNamedAddresses() {
        guard running, status.ready, let port = status.port, !updatingNamedAccess else { return }
        guard bonjourEnabled else { status.urls = Self.addresses(port: port); return }
        updatingNamedAccess = true
        defer { updatingNamedAccess = false }
        if namedAccess == nil {
            namedAccess = RemoteNamedAccess(nodeID: nodeID) { [weak self] in
                guard let self, self.running, self.status.ready else { return }
                self.updateNamedAddresses(); self.emitStatus()
            }
        }
        let anotherPortal = peers.values.contains { $0.available && $0.portal }
        namedAccess?.update(port: port, anotherPortal: anotherPortal)
        status.urls = (namedAccess?.urls(port: port, anotherPortal: anotherPortal) ?? []) + Self.addresses(port: port)
        // Keep the same service identity while updating gateway availability.
        let ownsPortal = namedAccess?.ownsPortal == true
        if ownsPortal != publishedPortal {
            publishedPortal = ownsPortal
            let txt = NWTXTRecord(["name": String(name.prefix(100)), "version": "1", "portal": ownsPortal ? "1" : "0"])
            listener?.service = NWListener.Service(name: nodeID, type: Self.serviceType, domain: "local.", txtRecord: txt)
        }
    }
    private func discovered(_ results: Set<NWBrowser.Result>) {
        for id in Array(peers.keys) {
            peers[id]?.portal = false
            peers[id]?.bonjour = false
            let recentlySeen = peers[id]?.directlySeen.map { Date().timeIntervalSince($0) < 150 } ?? false
            if peers[id]?.manual != true { peers[id]?.available = recentlySeen }
        }
        for result in results {
            guard case .service(let id, _, _, _) = result.endpoint, UUID(uuidString: id) != nil, id != nodeID else { continue }
            var peerName = "Mac · " + id.prefix(8)
            if case .bonjour(let txt) = result.metadata {
                guard txt.getEntry(for: "version") == .string("1") else { continue }
                if case .string(let value) = txt.getEntry(for: "name"), !value.isEmpty { peerName = String(value.prefix(100)) }
            } else { continue }
            let portal: Bool
            if case .bonjour(let txt) = result.metadata, txt.getEntry(for: "portal") == .string("1") { portal = true }
            else { portal = false }
            let previous = peers[id]
            let direct = previous?.directlySeen.map { Date().timeIntervalSince($0) < 150 } == true
                ? previous?.directAddress.flatMap { try? RemoteNetworkAddress.endpoint($0) } : nil
            peers[id] = Peer(id: id, name: peerName, endpoint: direct ?? result.endpoint, available: true, manual: previous?.manual ?? false, portal: portal, bonjour: true, directlySeen: previous?.directlySeen, directAddress: previous?.directAddress)
        }
        // Keep disconnected machines visible, but bound the history on long-running networks.
        if peers.count > 100 {
            for id in peers.values.filter({ !$0.available && !$0.manual }).prefix(peers.count - 100).map(\.id) { peers.removeValue(forKey: id) }
        }
        updateNamedAddresses(); emitStatus()
    }
    private func discoverDirectPeers(epoch: UUID) async {
        let addresses = Array(discoveryAddresses().prefix(512))
        // Bound connection count and keep the main actor free while HTTP probes wait.
        for offset in stride(from: 0, to: addresses.count, by: 8) {
            guard running, generation == epoch, !Task.isCancelled else { return }
            let found = await withTaskGroup(of: RemotePeerDiscovery.Found?.self, returning: [RemotePeerDiscovery.Found].self) { group in
                for address in addresses[offset..<min(offset + 8, addresses.count)] {
                    group.addTask { await RemotePeerDiscovery.find(address) }
                }
                var result: [RemotePeerDiscovery.Found] = []
                for await peer in group { if let peer { result.append(peer) } }
                return result
            }
            guard running, generation == epoch, !Task.isCancelled else { return }
            for peer in found where peer.id != nodeID {
                guard let endpoint = try? RemoteNetworkAddress.endpoint(peer.address) else { continue }
                if var existing = peers[peer.id] {
                    existing.directlySeen = Date(); existing.available = true; existing.name = peer.name
                    existing.directAddress = peer.address; existing.endpoint = endpoint
                    peers[peer.id] = existing
                } else if peers.count < 100 {
                    peers[peer.id] = Peer(id: peer.id, name: peer.name, endpoint: endpoint, available: true, manual: false, directlySeen: Date(), directAddress: peer.address)
                }
            }
            if !found.isEmpty { emitStatus() }
        }
        for id in Array(peers.keys) where peers[id]?.manual == false && peers[id]?.bonjour == false {
            let recentlySeen = peers[id]?.directlySeen.map { Date().timeIntervalSince($0) < 150 } ?? false
            peers[id]?.available = recentlySeen
        }
        emitStatus()
    }
    private func localState() throws -> RemoteNodeState {
        guard let engine else { throw RemoteHTTPError(503, "앱이 종료되었습니다.") }
        return RemoteNodeState(id: nodeID, name: name, snapshot: engine.snapshot, sessions: engine.remoteSessionViews())
    }
    private func exchange(_ peer: Peer, path: String, method: String = "GET", body: Data = Data()) async throws -> RemoteHTTPResponse {
        guard running, peer.available else { throw RemoteHTTPError(503, "이 Mac이 네트워크에서 연결 해제되었습니다.") }
        return try await RemoteHTTPExchange(endpoint: peer.endpoint, path: path, method: method, body: body, expectedNodeID: peer.id).run()
    }
    public func dashboard() async throws -> RemoteDashboard {
        let own = try localState()
        let candidates = Array(peers.values).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let other = await withTaskGroup(of: RemoteNodeView.self) { group in
            for peer in candidates.prefix(100) {
                group.addTask { @MainActor in
                    do {
                        let response = try await self.exchange(peer, path: "/api/state")
                        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                        let state = try decoder.decode(RemoteNodeState.self, from: response.body)
                        guard response.status == 200, state.id == peer.id else { throw RemoteHTTPError(502, "Mac의 연결 정보가 바뀌었습니다. 주소를 다시 추가해주세요.") }
                        return RemoteNodeView(id: peer.id, name: state.name, local: false, online: true, state: state)
                    } catch { return RemoteNodeView(id: peer.id, name: peer.name, local: false, online: false, error: error.localizedDescription) }
                }
            }
            var result: [RemoteNodeView] = []
            for await node in group { result.append(node) }
            return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return RemoteDashboard(gatewayID: nodeID, nodes: [RemoteNodeView(id: nodeID, name: name, local: true, online: true, state: own)] + other, updatedAt: Date(), discovery: discoveryError)
    }
    public func handle(_ request: RemoteHTTPRequest) async -> RemoteHTTPResponse {
        do {
            try request.validateOrigin()
            if let expected = request.headers["x-autoapprove-node"], expected != nodeID {
                throw RemoteHTTPError(409, "이 주소의 Mac이 바뀌었습니다. 목록을 새로고침하거나 Mac 주소를 다시 추가해주세요.")
            }
            guard ["GET", "POST"].contains(request.method) else { throw RemoteHTTPError(405, "이 요청 방식은 지원하지 않습니다.") }
            if request.method == "GET" {
                switch request.path {
                case "/", "/index.html": return try asset("index.html", type: "text/html; charset=utf-8")
                case "/app.css": return try asset("app.css", type: "text/css; charset=utf-8")
                case "/app.js": return try asset("app.js", type: "text/javascript; charset=utf-8")
                case "/favicon.svg": return try asset("favicon.svg", type: "image/svg+xml")
                case "/api/state": return try .json(localState())
                case "/api/discovery": return try .object(["service": "autoapprove", "version": 1, "id": nodeID, "name": name])
                case "/api/network": return try await .json(dashboard())
                case "/api/terminal":
                    if let forwarded = try await forward(request) { return forwarded }
                    guard let id = request.parameter("session"), let engine else { throw RemoteHTTPError(400, "세션을 지정해주세요.") }
                    let frame = try await engine.remoteTerminal(sessionID: id)
                    return try .json(RemoteTerminalUpdate(frame, knownRevision: request.parameter("revision")))
                default: throw RemoteHTTPError(404, "페이지를 찾지 못했습니다.")
                }
            }
            let object = try request.json()
            switch request.path {
            case "/api/peers":
                guard let address = object["address"] as? String else { throw RemoteHTTPError(400, "Mac 주소가 필요합니다.") }
                let endpoint = try RemoteNetworkAddress.endpoint(address)
                let response = try await RemoteHTTPExchange(endpoint: endpoint, path: "/api/state", method: "GET", body: Data()).run()
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                guard response.status == 200, let state = try? decoder.decode(RemoteNodeState.self, from: response.body), UUID(uuidString: state.id) != nil else { throw RemoteHTTPError(502, "이 주소에서 AutoApprove를 찾지 못했습니다.") }
                guard state.id != nodeID else { throw RemoteHTTPError(409, "이 Mac은 이미 연결되어 있습니다.") }
                manualPeers.removeAll { $0.id == state.id }; manualPeers.append(ManualPeer(id: state.id, name: state.name, address: address))
                try save(manualPeers, to: manualURL)
                peers[state.id] = Peer(id: state.id, name: state.name, endpoint: endpoint, available: true, manual: true); emitStatus()
                return try .object(["id": state.id, "name": state.name])
            case "/api/action", "/api/input":
                if let forwarded = try await forward(request) { return forwarded }
                guard let engine, let requestID = object["requestID"] as? String, UUID(uuidString: requestID) != nil else { throw RemoteHTTPError(400, "고유한 요청 ID가 필요합니다.") }
                let fingerprint = PromptDetector.fingerprint(request.path + String(decoding: request.body, as: UTF8.self))
                if let existing = receipts.first(where: { $0.id == requestID }) {
                    guard existing.fingerprint == fingerprint else { throw RemoteHTTPError(409, "이미 사용한 요청 ID입니다.") }
                    if let body = existing.response { return RemoteHTTPResponse(status: existing.status ?? 200, body: body) }
                    throw RemoteHTTPError(409, "이미 전달을 시작한 요청입니다. 입력을 다시 보내지 말고 터미널 화면을 확인해주세요.")
                }
                receipts.append(Receipt(id: requestID, fingerprint: fingerprint)); if receipts.count > 1024 { receipts.removeFirst(receipts.count - 1024) }
                do { try save(receipts, to: receiptsURL) } catch { receipts.removeAll { $0.id == requestID }; throw error }
                let response: RemoteHTTPResponse
                do {
                    if request.path == "/api/input" { response = try await .object(engine.remoteInput(object)) }
                    else { response = try await .object(engine.remoteAction(object)) }
                } catch { response = .error(error) }
                if let index = receipts.firstIndex(where: { $0.id == requestID }) {
                    receipts[index].response = response.body; receipts[index].status = response.status
                    // The reserved receipt already prevents a repeated input if saving the result fails.
                    try? save(receipts, to: receiptsURL)
                }
                return response
            default: throw RemoteHTTPError(404, "지원하지 않는 동작입니다.")
            }
        } catch { return .error(error) }
    }
    private func forward(_ request: RemoteHTTPRequest) async throws -> RemoteHTTPResponse? {
        guard let target = request.parameter("node"), target != nodeID else { return nil }
        guard let peer = peers[target] else { throw RemoteHTTPError(404, "이 Mac을 찾지 못했습니다. 목록을 새로고침해주세요.") }
        let components = request.components
        // Preserve form encoding while removing the gateway selector. Re-encoding
        // Foundation queryItems turns a literal '%2B' into '+', which means space.
        let items = components.percentEncodedQuery?.split(separator: "&").filter { item in
            let key = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0]
            return String(key).replacingOccurrences(of: "+", with: " ").removingPercentEncoding != "node"
        } ?? []
        let query = items.isEmpty ? "" : "?" + items.joined(separator: "&")
        return try await exchange(peer, path: components.percentEncodedPath + query, method: request.method, body: request.body)
    }
    private func asset(_ filename: String, type: String) throws -> RemoteHTTPResponse {
        // SPM's executable accessor looks beside the main bundle. Packaged apps and their
        // helper keep library resources in Contents/Resources, including after relocation.
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let packaged = [Bundle.main.resourceURL?.appendingPathComponent("AutoApprove_AutoApproveCore.bundle/RemoteWeb/" + filename),
            executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/AutoApprove_AutoApproveCore.bundle/RemoteWeb/" + filename)]
        for candidate in packaged.compactMap({ $0 }) where FileManager.default.fileExists(atPath: candidate.path) {
            return RemoteHTTPResponse(body: try Data(contentsOf: candidate), contentType: type)
        }
        guard let file = Bundle.module.url(forResource: filename, withExtension: nil, subdirectory: "RemoteWeb") else { throw RemoteHTTPError(500, "웹 화면 파일을 찾지 못했습니다.") }
        return RemoteHTTPResponse(body: try Data(contentsOf: file), contentType: type)
    }
    private func save<T: Encodable>(_ value: T, to file: URL) throws {
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    static func addresses(port: UInt16) -> [String] {
        RemoteLAN.interfaces().map { "http://\($0.address):\(port)" }
    }
}
