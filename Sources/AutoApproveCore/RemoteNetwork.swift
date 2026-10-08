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
    public var ptyID: String? = nil
    public var pty: ManagedPTYDescriptor? = nil
}

public struct RemoteNodeState: Codable {
    public var id: String
    public var name: String
    public var snapshot: EngineSnapshot
    public var sessions: [RemoteSessionView]
    public var release: RemoteWebVersion? = nil
    public var webURLs: [String]? = nil
    public var webPort: UInt16? = nil
    public var questionForms: [WebQuestionRequest]? = nil
    public var screenShares: [TestScreenShare]? = nil
    public var update: LANUpdateStatus? = nil
    public var historyDeferred: Bool? = nil
    public var inventory: RemoteNodeState {
        var value = self
        value.snapshot.sessions = []; value.snapshot.events = []; value.historyDeferred = true
        return value
    }
}

public struct RemoteNodeView: Codable {
    public var id: String
    public var name: String
    public var local: Bool
    public var online: Bool
    public var state: RemoteNodeState?
    public var error: String?
    /// Last verified discovery version remains visible when a state read is unavailable.
    public var release: RemoteWebVersion? = nil
    public var loading: Bool? = nil
}

public struct RemoteDashboard: Codable {
    public var gatewayID: String
    public var nodes: [RemoteNodeView]
    public var updatedAt: Date
    public var discovery: String?
    public var gatewayRelease: RemoteWebVersion? = nil
    public var preferredGateway: RemoteWebGateway? = nil
    public var partial: Bool? = nil
}

public struct RemoteTerminalFrame: Codable, Sendable {
    public var sessionID: String
    public var screen: String
    public var revision: String
    public var observedAt: Date
    public var keys: [String]
    public var inputReason: String?
    public var appearance: TerminalAppearance? = nil
    public var cursor: TerminalCursor? = nil
    public var streamID: String? = nil
    public var nativeDisplay: TerminalNativeDisplay? = nil
    public var outputReason: String? = nil
}

/// A browser that already has this revision only needs fresh controls and observation time.
struct RemoteTerminalUpdate: Encodable {
    var sessionID: String
    var screen: String?
    var revision: String
    var observedAt: Date
    var keys: [String]
    var inputReason: String?
    var appearance: TerminalAppearance?
    var cursor: TerminalCursor?
    var streamID: String?
    var nativeDisplay: TerminalNativeDisplay?
    var outputReason: String?
    init(_ frame: RemoteTerminalFrame, knownRevision: String?) {
        sessionID = frame.sessionID; revision = frame.revision; observedAt = frame.observedAt
        keys = frame.keys; inputReason = frame.inputReason
        screen = knownRevision == frame.revision ? nil : frame.screen
        appearance = knownRevision == frame.revision ? nil : frame.appearance
        cursor = frame.cursor; streamID = frame.streamID
        nativeDisplay = knownRevision == frame.revision ? frame.nativeDisplay?.compact : frame.nativeDisplay
        outputReason = frame.outputReason
    }
}

@MainActor public final class RemoteNetworkService {
    public static let serviceType = "_autoapprove._tcp"
    public let nodeID: String
    public let name: String
    public let webVersion: RemoteWebVersion?
    public var directDiscoveryInterval: TimeInterval = 45
    private weak var engine: ApprovalEngine?
    private let updateArchive: LANUpdateArchive
    private let updateReceiver: LANUpdateReceiver
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var pathMonitor: NWPathMonitor?
    private var discoveryTask: Task<Void, Never>?
    private var webPeerTask: Task<Void, Never>?
    private var browserRetry: Task<Void, Never>?
    private var browserRetryDelay: TimeInterval = 1
    private var directCursor = 0
    private var directProbedAt: [String: Date] = [:]
    private var pendingHints: [String] = []
    private var nextHintRead = Date.distantPast
    private var nextBlindProbe = Date.distantPast
    private var lanInterfaces: [RemoteLANInterface] = []
    private let bonjourEnabled: Bool
    private let advertisement: RemoteServiceAdvertising
    private let discoveryAddresses: () -> [String]
    private let discoveryHints: @Sendable () -> [String]
    private var namedAccess: RemoteNamedAccess?
    private var updatingNamedAccess = false
    private var publishedPortal = false
    private var listenerRetry: Task<Void, Never>?
    private var listenerRetryDelay: Double = 1
    private var listenerPort: UInt16 = 8765
    private var allowListenerPortFallback = false
    public var port: UInt16? { listener?.port?.rawValue }
    private let queue = DispatchQueue(label: "autoapprove.web.listener")
    private var connections: [UUID: RemoteHTTPConnection] = [:]
    private var streamConnections: Set<UUID> = []
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
        var release: RemoteWebVersion?
        var webURLs: [String] = []
        var webPort: UInt16?
        var webVerifiedAt: Date?
        var nextProbe = Date.distantPast
        var failures = 0
        var bonjourEndpoint: NWEndpoint?
        var preferredEndpoint: NWEndpoint?
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
    private struct KnownPeer: Codable { var id: String; var name: String; var address: String; var urls: [String]; var port: UInt16?; var release: RemoteWebVersion?; var lastSeen: Date }
    private let knownURL: URL
    private var knownPeers: [KnownPeer] = []
    private var knownSaveTask: Task<Void, Never>?
    private let stateReads = RemotePeerStateCache()
    public init(engine: ApprovalEngine, nodeID: String, name: String? = nil, bonjourEnabled: Bool = true, discoveryAddresses: (() -> [String])? = nil, discoveryHints: (@Sendable () -> [String])? = nil, webVersion: RemoteWebVersion? = RemoteWebVersion.current, advertisement: RemoteServiceAdvertising? = nil, onStatus: @escaping (RemoteNetworkStatus) -> Void) {
        self.engine = engine; self.nodeID = nodeID
        updateArchive = LANUpdateArchive(directory: engine.paths.directory.appendingPathComponent("updates/offer"), nodeID: nodeID)
        updateReceiver = LANUpdateReceiver(engine: engine)
        self.bonjourEnabled = bonjourEnabled
        self.advertisement = advertisement ?? RemoteServiceAdvertisement()
        self.discoveryAddresses = discoveryAddresses ?? RemotePeerDiscovery.addresses
        if let discoveryHints { self.discoveryHints = discoveryHints }
        else if discoveryAddresses == nil { self.discoveryHints = { RemoteLAN.neighborURLs() } }
        else { self.discoveryHints = { [] } }
        self.name = name ?? Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        self.webVersion = webVersion?.isCompatible == true ? webVersion : nil
        self.onStatus = onStatus
        receiptsURL = engine.paths.directory.appendingPathComponent("web-requests.json")
        manualURL = engine.paths.directory.appendingPathComponent("web-peers.json")
        knownURL = engine.paths.directory.appendingPathComponent("web-known-peers.json")
        receipts = (try? JSONDecoder().decode([Receipt].self, from: Data(contentsOf: receiptsURL))) ?? []
        manualPeers = (try? JSONDecoder().decode([ManualPeer].self, from: Data(contentsOf: manualURL))) ?? []
        for peer in manualPeers {
            if let endpoint = try? RemoteNetworkAddress.endpoint(peer.address), peer.id != nodeID {
                peers[peer.id] = Peer(id: peer.id, name: peer.name, endpoint: endpoint, available: true, manual: true, directAddress: peer.address)
            }
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        knownPeers = ((try? decoder.decode([KnownPeer].self, from: Data(contentsOf: knownURL))) ?? []).filter {
            UUID(uuidString: $0.id) != nil && $0.id != nodeID && Date().timeIntervalSince($0.lastSeen) < 7 * 86400 && (try? RemoteNetworkAddress.endpoint($0.address)) != nil
        }.prefix(100).map { $0 }
        for peer in knownPeers where peers[peer.id] == nil {
            peers[peer.id] = Peer(id: peer.id, name: peer.name, endpoint: try! RemoteNetworkAddress.endpoint(peer.address), available: false, manual: false,
                directAddress: peer.address, release: peer.release, webURLs: Array(peer.urls.prefix(16)), webPort: peer.port)
        }
    }
    public func start(port preferredPort: UInt16 = 8765, allowPortFallback: Bool = false) throws {
        guard !running else { return }
        let port = preferredPort
        let parameters = RemoteLAN.tcpParameters()
        lanInterfaces = RemoteLAN.interfaces(refresh: true)
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        let epoch = UUID(); generation = epoch; running = true; self.listener = listener
        listenerPort = port; allowListenerPortFallback = allowPortFallback; listenerRetryDelay = 1
        publishedPortal = false
        configureListener(listener, port: port, epoch: epoch)
        status.enabled = true; status.detail = "웹 접속과 같은 네트워크의 Mac을 연결하고 있습니다."
        listener.start(queue: queue)
        startDiscovery(parameters: parameters, epoch: epoch)
    }

    private func configureListener(_ listener: NWListener, port: UInt16, epoch: UUID) {
        // Keep NWListener's lifetime accept budget unlimited. Concurrent requests are
        // bounded by connections.count below. Streams use only 12 of the 32
        // slots, leaving room for input, state, assets and normal API requests.
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            Task { @MainActor in
                guard let self, let listener, self.listener === listener, self.running, self.generation == epoch, self.connections.count < 32,
                      case .hostPort(let host, _) = connection.endpoint,
                      RemoteNetworkAddress.isLocalHost(String(describing: host)) else { connection.cancel(); return }
                let id = UUID()
                let client = RemoteHTTPConnection(connection, queue: self.queue, handler: { [weak self] request in
                    guard let self, !Task.isCancelled, self.running, self.generation == epoch, self.connections[id] != nil else { return .error(RemoteHTTPError(503, "웹 접속이 꺼졌거나 연결이 종료되었습니다.")) }
                    if request.method == "GET", ["/api/pty/stream", "/api/terminal/stream"].contains(request.path) {
                        do { try request.validateOrigin() } catch { return .error(error) }
                        guard self.streamConnections.count < 12 else { return .error(RemoteHTTPError(429, "터미널 실시간 연결은 Mac 한 대에서 12개까지 열 수 있습니다. 다른 화면을 닫고 다시 연결해주세요.")) }
                        self.streamConnections.insert(id)
                    }
                    return await self.handle(request)
                }, onClose: { [weak self] in Task { @MainActor in
                    self?.connections.removeValue(forKey: id); self?.streamConnections.remove(id)
                } })
                self.connections[id] = client; client.start()
            }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, let listener, self.running, self.generation == epoch, self.listener === listener else { return }
                switch state {
                case .ready:
                    self.status.ready = true; self.status.detail = "같은 네트워크의 휴대폰과 Mac에서 접속할 수 있습니다."
                    self.status.port = listener.port?.rawValue ?? port
                    self.listenerPort = self.status.port ?? port
                    self.listenerRetry?.cancel(); self.listenerRetry = nil; self.listenerRetryDelay = 1
                    self.publishService(port: self.listenerPort)
                    self.updateNamedAddresses()
                case .waiting(let error), .failed(let error):
                    if self.allowListenerPortFallback, port != 0, case .posix(let code) = error,
                       code == .EADDRINUSE || code == .EINVAL {
                        self.listenerPort = 0
                    }
                    self.status.ready = false; self.status.urls = []; self.status.port = nil
                    self.status.detail = "웹 연결을 다시 열고 있습니다. \(error.localizedDescription)"
                    self.scheduleListenerRetry(epoch: epoch)
                default: break
                }
                self.emitStatus()
            }
        }
    }

    private func scheduleListenerRetry(epoch: UUID) {
        guard listenerRetry == nil, running else { return }
        let delay = listenerRetryDelay
        listenerRetryDelay = min(30, delay * 2)
        listenerRetry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.running, self.generation == epoch else { return }
            self.listenerRetry = nil
            // Accepted requests and durable receipts remain alive while the acceptor recovers.
            self.listener?.cancel(); self.listener = nil
            do {
                let listener = try NWListener(using: RemoteLAN.tcpParameters(), on: NWEndpoint.Port(rawValue: self.listenerPort)!)
                self.listener = listener
                self.configureListener(listener, port: self.listenerPort, epoch: epoch)
                listener.start(queue: self.queue)
            } catch {
                self.status.detail = "웹 연결을 다시 열고 있습니다. \(error.localizedDescription)"
                self.emitStatus(); self.scheduleListenerRetry(epoch: epoch)
            }
        }
    }

    private func publishService(port: UInt16) {
        guard bonjourEnabled else { return }
        advertisement.publish(name: nodeID, type: Self.serviceType, port: port, txt: serviceTXT(portal: publishedPortal, port: port)) { [weak self] ready in
            guard let self, self.running else { return }
            if !ready { self.discoveryError = "이름 검색을 다시 연결하고 있습니다. 숫자 주소의 웹 접속과 메시지 전송은 계속 사용할 수 있습니다." }
            else { self.discoveryError = nil }
            self.emitStatus()
        }
    }

    private func startDiscovery(parameters: NWParameters, epoch: UUID) {
        if bonjourEnabled {
            startBrowser(parameters: parameters, epoch: epoch)
        }
        startDirectDiscovery(epoch: epoch)
        let monitor = NWPathMonitor(prohibitedInterfaceTypes: [.other, .cellular]); pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.running, self.generation == epoch, self.status.ready, let port = self.port else { return }
                let interfaces = RemoteLAN.interfaces(refresh: true)
                if interfaces != self.lanInterfaces {
                    self.lanInterfaces = interfaces
                    for id in self.peers.keys { self.peers[id]?.nextProbe = .distantPast; self.peers[id]?.preferredEndpoint = nil }
                    self.stateReads.removeAll()
                    self.nextHintRead = .distantPast; self.nextBlindProbe = .distantPast
                    self.startDirectDiscovery(epoch: epoch)
                    self.publishService(port: port)
                }
                self.status.port = port; self.updateNamedAddresses(); self.emitStatus()
            }
        }
        monitor.start(queue: queue)
    }
    private func startBrowser(parameters: NWParameters, epoch: UUID) {
            browser?.cancel()
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: "local."), using: parameters)
            self.browser = browser
            browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
                Task { @MainActor in
                    guard let self, let browser, self.running, self.generation == epoch, self.browser === browser else { return }
                    self.discovered(results)
                }
            }
            browser.stateUpdateHandler = { [weak self, weak browser] state in
                Task { @MainActor in
                    guard let self, let browser, self.running, self.generation == epoch, self.browser === browser else { return }
                    switch state {
                    case .ready: self.discoveryError = nil; self.browserRetryDelay = 1
                    case .waiting: self.discoveryError = "이름으로 Mac을 찾지 못해 같은 네트워크 주소에서 직접 찾고 있습니다. 기본 포트가 다르면 주소로 추가하세요."
                    case .failed:
                        self.discoveryError = "이름 검색을 다시 연결하고 있습니다. 저장한 Mac 주소는 계속 확인합니다."
                        guard self.browserRetry == nil else { return }
                        let delay = self.browserRetryDelay; self.browserRetryDelay = min(30, delay * 2)
                        self.browserRetry = Task { [weak self] in
                            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                            guard let self, self.running, self.generation == epoch else { return }
                            self.browserRetry = nil; self.startBrowser(parameters: RemoteLAN.tcpParameters(), epoch: epoch)
                        }
                    default: break
                    }
                }
            }
            browser.start(queue: queue); emitStatus()
    }
    private func startDirectDiscovery(epoch: UUID) {
        discoveryTask?.cancel()
        discoveryTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            while !Task.isCancelled {
                guard let self, self.running, self.generation == epoch else { return }
                self.stateReads.prune(liveIDs: Set(self.peers.keys))
                self.refreshWebPeers()
                await self.discoverDirectPeers(epoch: epoch)
                self.refreshWebPeers()
                self.checkLANUpdate()
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }
    public func stop() {
        updateReceiver.stop()
        running = false; generation = UUID()
        discoveryTask?.cancel(); discoveryTask = nil
        listenerRetry?.cancel(); listenerRetry = nil; advertisement.stop()
        webPeerTask?.cancel(); webPeerTask = nil
        browserRetry?.cancel(); browserRetry = nil
        knownSaveTask?.cancel(); knownSaveTask = nil; saveKnownPeers()
        stateReads.removeAll()
        directProbedAt.removeAll(); pendingHints.removeAll(); directCursor = 0
        namedAccess?.stop(); namedAccess = nil
        listener?.cancel(); listener = nil; browser?.cancel(); browser = nil
        pathMonitor?.cancel(); pathMonitor = nil
        let clients = Array(connections.values); connections.removeAll(); streamConnections.removeAll(); clients.forEach { $0.close() }
        peers = peers.filter { $0.value.manual }
        for id in Array(peers.keys) { peers[id]?.portal = false; peers[id]?.webVerifiedAt = nil }
        status = RemoteNetworkStatus(); emitStatus()
    }
    public func cancelLANUpdate() { updateReceiver.stop() }
    private func checkLANUpdate() {
        guard running, let peer = newerWebPeers().first(where: { verified($0) }), let release = peer.release else { return }
        let epoch = generation
        updateReceiver.check(nodeID: peer.id, release: release, routeKey: peerEndpoints(peer).map { String(describing: $0) }.joined(separator: "|")) { [weak self] path in
            guard let self, self.running, self.generation == epoch, let current = self.peers[peer.id] else { throw CancellationError() }
            return try await self.exchange(current, path: path, timeout: path == "/api/update/manifest" ? 25 : 15)
        }
    }
    private func emitStatus() { status.peerCount = peers.values.filter(\.available).count; onStatus(status) }
    private func serviceTXT(portal: Bool, port: UInt16) -> Data {
        var values = ["name": String(name.prefix(60)), "version": "1", "portal": portal ? "1" : "0", "http-port": String(port), "ipv4": lanInterfaces.prefix(4).map(\.address).joined(separator: ",")]
        if let webVersion { values["app-version"] = webVersion.version; values["app-build"] = String(webVersion.build) }
        return NetService.data(fromTXTRecord: values.mapValues { Data($0.utf8) })
    }
    private func verified(_ peer: Peer) -> Bool {
        peer.available && peer.release?.isCompatible == true && peer.webVerifiedAt.map { Date().timeIntervalSince($0) < 150 } == true
    }
    private func connectionEndpoint(_ peer: Peer) -> NWEndpoint {
        if let preferred = peer.preferredEndpoint { return preferred }
        let manual = manualPeers.first(where: { $0.id == peer.id }).flatMap { try? RemoteNetworkAddress.endpoint($0.address) }
        let fallback: NWEndpoint
        // A rediscovered numeric endpoint may have a new port after restart.
        // Use a saved address only when Bonjour would otherwise resolve again.
        if case .service = peer.endpoint {
            if let manual, case .hostPort(let host, let savedPort) = manual {
                // A fresh advertisement changes the listener port, not the saved route's host.
                // Verify the exact node at the destination; GET can still try Bonjour if its IP moved.
                fallback = .hostPort(host: host, port: peer.webPort.flatMap(NWEndpoint.Port.init(rawValue:)) ?? savedPort)
            }
            else { fallback = peer.endpoint }
        }
        else { fallback = peer.endpoint }
        // Gateway/version freshness is independent of a confirmed LAN route.
        // Each request still checks the exact node ID at its destination.
        guard let port = peer.webPort else { return fallback }
        return RemoteLAN.preferredEndpoint(fallback, addresses: peer.webURLs, port: port, interfaces: RemoteLAN.interfaces())
    }
    private func acceptWebMetadata(_ found: RemotePeerDiscovery.Found) {
        guard peers[found.id] != nil else { return }
        if peers[found.id]?.available != true { stateReads.remove(found.id) }
        if let endpoint = try? RemoteNetworkAddress.endpoint(found.address) {
            peers[found.id]?.preferredEndpoint = endpoint
            peers[found.id]?.directAddress = found.address; peers[found.id]?.directlySeen = Date()
        }
        peers[found.id]?.release = found.release?.isCompatible == true ? found.release : nil
        peers[found.id]?.webURLs = found.urls
        peers[found.id]?.webPort = found.port
        peers[found.id]?.webVerifiedAt = Date()
        peers[found.id]?.portal = found.portal
        peers[found.id]?.available = true; peers[found.id]?.failures = 0
        peers[found.id]?.nextProbe = Date().addingTimeInterval(15)
        rememberPeer(found.id)
    }
    private func peerEndpoints(_ peer: Peer) -> [NWEndpoint] {
        let primary = connectionEndpoint(peer), interfaces = RemoteLAN.interfaces()
        var result = [primary]
        for address in peer.webURLs {
            guard let endpoint = try? RemoteNetworkAddress.endpoint(address), case .hostPort(let host, _) = endpoint,
                  String(describing: host).hasPrefix("127.") || RemoteLAN.route(to: String(describing: host), interfaces: interfaces) != nil,
                  !result.contains(endpoint) else { continue }
            result.append(endpoint)
        }
        if let bonjour = peer.bonjourEndpoint, !result.contains(bonjour) { result.append(bonjour) }
        return Array(result.prefix(3))
    }
    private static func numericURL(_ endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, let port) = endpoint else { return "" }
        let name = String(describing: host)
        return "http://\(name.contains(":") ? "[\(name)]" : name):\(port.rawValue)"
    }
    private func rememberPeer(_ id: String) {
        guard let peer = peers[id] else { return }
        let addresses = [peer.directAddress].compactMap { $0 } + peer.webURLs
        guard let address = addresses.first(where: { if let endpoint = try? RemoteNetworkAddress.endpoint($0), case .hostPort = endpoint { return true }; return false }) else { return }
        if let previous = knownPeers.first(where: { $0.id == id }), previous.name == peer.name, previous.address == address,
           previous.urls == peer.webURLs, previous.port == peer.webPort, previous.release == peer.release,
           Date().timeIntervalSince(previous.lastSeen) < 60 { return }
        knownPeers.removeAll { $0.id == id }
        knownPeers.append(KnownPeer(id: id, name: peer.name, address: address, urls: Array(peer.webURLs.prefix(16)), port: peer.webPort, release: peer.release, lastSeen: Date()))
        if knownPeers.count > 100 { knownPeers.removeFirst(knownPeers.count - 100) }
        guard knownSaveTask == nil else { return }
        knownSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            self?.knownSaveTask = nil; self?.saveKnownPeers()
        }
    }
    private func saveKnownPeers() {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(knownPeers) {
            try? data.write(to: knownURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownURL.path)
        }
    }
    private func refreshWebPeers() {
        guard webPeerTask == nil else { return }
        let epoch = generation
        let candidates = Array(peers.values.filter { $0.nextProbe <= Date() }.sorted { $0.nextProbe < $1.nextProbe }.prefix(100))
        guard !candidates.isEmpty else { return }
        webPeerTask = Task { [weak self] in
            guard let self else { return }
            for offset in stride(from: 0, to: candidates.count, by: 2) {
                guard self.running, self.generation == epoch, !Task.isCancelled else { return }
                let found = await withTaskGroup(of: RemotePeerDiscovery.Found?.self, returning: [RemotePeerDiscovery.Found].self) { group in
                    for peer in candidates[offset..<min(offset + 2, candidates.count)] {
                        let endpoints = self.peerEndpoints(peer)
                        group.addTask {
                            for endpoint in endpoints {
                                guard !Task.isCancelled else { return nil }
                                if let value = await RemotePeerDiscovery.probe(endpoint, expectedID: peer.id, address: Self.numericURL(endpoint)) { return value }
                            }
                            return nil
                        }
                    }
                    var result: [RemotePeerDiscovery.Found] = []
                    for await value in group { if let value { result.append(value) } }
                    return result
                }
                guard self.running, self.generation == epoch, !Task.isCancelled else { return }
                for value in found {
                    guard let original = candidates.first(where: { $0.id == value.id }), self.peers[value.id]?.endpoint == original.endpoint else { continue }
                    self.acceptWebMetadata(value)
                }
                for peer in candidates[offset..<min(offset + 2, candidates.count)] where !found.contains(where: { $0.id == peer.id }) {
                    guard self.peers[peer.id]?.endpoint == peer.endpoint else { continue }
                    let failures = min(5, (self.peers[peer.id]?.failures ?? 0) + 1)
                    self.peers[peer.id]?.failures = failures
                    self.peers[peer.id]?.nextProbe = Date().addingTimeInterval(pow(2, Double(failures)))
                    self.peers[peer.id]?.webVerifiedAt = nil
                    if !peer.bonjour && !peer.manual && peer.webVerifiedAt.map({ Date().timeIntervalSince($0) < 60 }) != true { self.peers[peer.id]?.available = false }
                }
                self.updateNamedAddresses(); self.emitStatus()
            }
            self.webPeerTask = nil
        }
    }
    private func newerWebPeers() -> [Peer] {
        guard let webVersion else { return [] }
        return peers.values.filter { $0.available && $0.release?.isCompatible == true && $0.release! > webVersion }
            .sorted { $0.release == $1.release ? $0.id < $1.id : $0.release! > $1.release! }
    }
    private func gateway(_ peer: Peer) -> RemoteWebGateway? {
        guard verified(peer), let release = peer.release, let port = peer.webPort else { return nil }
        // Use the proven numeric endpoint first, then physical LAN addresses advertised
        // by the exact Mac. Bonjour names are unsuitable for hotspot-host browsers.
        for address in [peer.directAddress].compactMap({ $0 }) + peer.webURLs {
            let supplied = address.contains("://") ? address : "http://" + address
            guard (try? RemoteNetworkAddress.endpoint(supplied)) != nil, var url = URLComponents(string: supplied),
                  let host = url.host, let ipv4 = IPv4Address(host), UInt16(exactly: url.port ?? 8765) == port else { continue }
            let bytes = Array(ipv4.rawValue)
            guard bytes[0] == 127 || lanInterfaces.contains(where: { $0.address == host }) || RemoteLAN.route(to: host, interfaces: lanInterfaces) != nil else { continue }
            url.port = Int(port); url.path = "/"; url.queryItems = [URLQueryItem(name: "webNode", value: peer.id)]
            if let value = url.string { return RemoteWebGateway(id: peer.id, name: peer.name, url: value, release: release) }
        }
        return nil
    }
    private func preferredGateway() -> RemoteWebGateway? {
        newerWebPeers().compactMap(gateway).first
    }
    private func verifiedGateway() async -> RemoteWebGateway? {
        let epoch = generation
        // Never redirect API requests. Recheck only a bounded number of newer web
        // providers; an offline or reassigned IP must still leave this page usable.
        for peer in newerWebPeers().prefix(4) {
            let found = await RemotePeerDiscovery.probe(connectionEndpoint(peer), expectedID: peer.id)
            guard running, generation == epoch else { return nil }
            guard peers[peer.id]?.endpoint == peer.endpoint else { continue }
            if let found {
                acceptWebMetadata(found)
                if let current = peers[peer.id], let local = webVersion, current.release.map({ $0 > local }) == true, let result = gateway(current) {
                    updateNamedAddresses(); emitStatus(); return result
                }
            } else { peers[peer.id]?.webVerifiedAt = nil }
        }
        updateNamedAddresses(); emitStatus(); return nil
    }
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
        let newerPortal = peers.values.contains { peer in
            gateway(peer) != nil && peer.webPort == 8765 && peer.release.map { release in webVersion.map { release > $0 } ?? false } == true
        }
        let anotherPortal = peers.values.contains { peer in
            guard peer.available && peer.portal else { return false }
            // Older compatible owners relinquish the name; the DNS probe still
            // protects unrelated or legacy owners that cannot cooperate.
            return !(verified(peer) && peer.release.map { release in webVersion.map { release < $0 } ?? false } == true)
        }
        namedAccess?.update(port: port, anotherPortal: anotherPortal, preferred: !newerPortal)
        status.urls = (namedAccess?.urls(port: port, anotherPortal: anotherPortal) ?? []) + Self.addresses(port: port)
        // Keep the same service identity while updating gateway availability.
        let ownsPortal = namedAccess?.ownsPortal == true
        if ownsPortal != publishedPortal {
            publishedPortal = ownsPortal
            publishService(port: port)
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
            var advertised: RemoteWebVersion?
            if case .bonjour(let txt) = result.metadata,
               case .string(let version) = txt.getEntry(for: "app-version"),
               case .string(let build) = txt.getEntry(for: "app-build"), let number = Int(build) {
                let value = RemoteWebVersion(version: version, build: number)
                if value.isCompatible { advertised = value }
            }
            let advertisedPort: UInt16?
            if case .bonjour(let txt) = result.metadata, case .string(let value) = txt.getEntry(for: "http-port"), let port = UInt16(value), port > 0 { advertisedPort = port }
            else { advertisedPort = nil }
            let advertisedURLs: [String]
            if let advertisedPort, case .bonjour(let txt) = result.metadata, case .string(let value) = txt.getEntry(for: "ipv4") {
                advertisedURLs = value.split(separator: ",").prefix(4).compactMap { part in
                    let host = String(part)
                    guard IPv4Address(host) != nil, RemoteNetworkAddress.isLocalHost(host) else { return nil }
                    return "http://\(host):\(advertisedPort)"
                }
            } else { advertisedURLs = [] }
            // A restarted listener can keep its version and service ID while changing ports.
            // Fresh DNS-SD metadata must supersede an old numeric/manual address.
            let unchanged = previous?.release == advertised && (advertisedPort == nil || previous?.webPort == advertisedPort)
            let direct = unchanged && previous?.directlySeen.map { Date().timeIntervalSince($0) < 150 } == true
                ? previous?.directAddress.flatMap { try? RemoteNetworkAddress.endpoint($0) } : nil
            peers[id] = Peer(id: id, name: peerName, endpoint: direct ?? result.endpoint, available: true, manual: previous?.manual ?? false, portal: portal, bonjour: true, directlySeen: previous?.directlySeen, directAddress: previous?.directAddress,
                release: advertised, webURLs: advertisedURLs.isEmpty ? (unchanged ? previous?.webURLs ?? [] : []) : advertisedURLs, webPort: advertisedPort ?? (unchanged ? previous?.webPort : nil), webVerifiedAt: unchanged ? previous?.webVerifiedAt : nil,
                nextProbe: unchanged ? previous?.nextProbe ?? .distantPast : .distantPast, failures: previous?.failures ?? 0, bonjourEndpoint: result.endpoint, preferredEndpoint: unchanged ? previous?.preferredEndpoint : nil)
        }
        // Keep disconnected machines visible, but bound the history on long-running networks.
        if peers.count > 100 {
            for id in peers.values.filter({ !$0.available && !$0.manual }).prefix(peers.count - 100).map(\.id) { peers.removeValue(forKey: id); stateReads.remove(id) }
        }
        updateNamedAddresses(); emitStatus()
        refreshWebPeers()
    }
    private func discoverDirectPeers(epoch: UUID) async {
        if Date() >= nextHintRead {
            nextHintRead = Date().addingTimeInterval(15)
            let read = discoveryHints, hints = await Task.detached(priority: .utility) { read() }.value
            guard running, generation == epoch, !Task.isCancelled else { return }
            pendingHints = Array(hints.prefix(64)).filter { directProbedAt[$0].map { Date().timeIntervalSince($0) < 60 } != true }
        }
        var addresses: [String] = []
        var seen = Set<String>()
        let candidates = Array(discoveryAddresses().prefix(512)).filter { seen.insert($0).inserted }
        let known = Set(peers.values.flatMap { [ $0.directAddress ].compactMap { $0 } + $0.webURLs })
        if !pendingHints.isEmpty { addresses = Array(pendingHints.prefix(2)); pendingHints.removeFirst(addresses.count) }
        else if Date() >= nextBlindProbe, !candidates.isEmpty {
            nextBlindProbe = Date().addingTimeInterval(peers.values.contains(where: { verified($0) }) ? min(5, max(0.5, directDiscoveryInterval)) : 0.5)
            for _ in 0..<candidates.count {
                let address = candidates[directCursor % candidates.count]; directCursor = (directCursor + 1) % candidates.count
                if !known.contains(address), directProbedAt[address].map({ Date().timeIntervalSince($0) >= max(10, directDiscoveryInterval) }) ?? true { addresses = [address]; break }
            }
        }
        for address in addresses { directProbedAt[address] = Date() }
        directProbedAt = directProbedAt.filter { Date().timeIntervalSince($0.value) < 300 }
        let found = await withTaskGroup(of: RemotePeerDiscovery.Found?.self, returning: [RemotePeerDiscovery.Found].self) { group in
            for address in addresses { group.addTask { await RemotePeerDiscovery.find(address) } }
            var result: [RemotePeerDiscovery.Found] = []
            for await peer in group { if let peer { result.append(peer) } }
            return result
        }
            guard running, generation == epoch, !Task.isCancelled else { return }
            for peer in found where peer.id != nodeID {
                guard let endpoint = try? RemoteNetworkAddress.endpoint(peer.address) else { continue }
                if var existing = peers[peer.id] {
                    if existing.endpoint != endpoint { existing.preferredEndpoint = nil; stateReads.remove(peer.id) }
                    existing.directlySeen = Date(); existing.available = true; existing.name = peer.name
                    existing.directAddress = peer.address; existing.endpoint = endpoint
                    existing.release = peer.release; existing.webURLs = peer.urls; existing.webPort = peer.port
                    existing.webVerifiedAt = Date(); existing.portal = peer.portal
                    peers[peer.id] = existing
                } else if peers.count < 100 {
                    peers[peer.id] = Peer(id: peer.id, name: peer.name, endpoint: endpoint, available: true, manual: false, directlySeen: Date(), directAddress: peer.address,
                        release: peer.release, webURLs: peer.urls, webPort: peer.port, webVerifiedAt: Date())
                    peers[peer.id]?.portal = peer.portal
                }
                acceptWebMetadata(peer)
            }
            if !found.isEmpty { updateNamedAddresses(); emitStatus() }
    }
    private func localState() throws -> RemoteNodeState {
        guard let engine else { throw RemoteHTTPError(503, "앱이 종료되었습니다.") }
        return RemoteNodeState(id: nodeID, name: name, snapshot: engine.snapshot, sessions: engine.remoteSessionViews(),
            release: webVersion, webURLs: port.map(Self.addresses), webPort: port,
            questionForms: engine.webQuestions.pending(), screenShares: engine.testScreens.active, update: engine.lanUpdate)
    }
    private func exchange(_ peer: Peer, path: String, method: String = "GET", body: Data = Data(), timeout: TimeInterval? = nil) async throws -> RemoteHTTPResponse {
        guard running, peer.available else { throw RemoteHTTPError(503, "이 Mac이 네트워크에서 연결 해제되었습니다.") }
        let primary = connectionEndpoint(peer)
        guard method == "GET", body.isEmpty else {
            let response = try await RemoteHTTPExchange(endpoint: primary, path: path, method: method, body: body, expectedNodeID: peer.id).run()
            stateReads.remove(peer.id)
            return response
        }
        let endpoints = Array(peerEndpoints(peer).prefix(2))
        guard endpoints.count > 1 else { return try await RemoteHTTPExchange(endpoint: primary, path: path, method: method, body: body, expectedNodeID: peer.id, timeout: timeout).run() }
        let deadline = ProcessInfo.processInfo.systemUptime + (timeout ?? (["/api/state","/api/inventory"].contains(path) ? 4 : 15))
        let epoch = generation
        for (index, endpoint) in endpoints.enumerated() {
            do {
                try Task.checkCancellation()
                let remaining = max(0.05, deadline - ProcessInfo.processInfo.systemUptime)
                let response = try await RemoteHTTPExchange(endpoint: endpoint, path: path, method: method, body: body, expectedNodeID: peer.id,
                    timeout: index == 0 ? remaining / 2 : remaining, retryReads: false).run()
                if [502,503,504].contains(response.status), index < endpoints.count - 1 {
                    throw RemoteHTTPError(response.status, "Mac의 읽기 연결을 다른 LAN 주소에서 확인합니다.")
                }
                if running, generation == epoch, response.status == 200, peers[peer.id]?.endpoint == peer.endpoint {
                    peers[peer.id]?.preferredEndpoint = endpoint
                    if !Self.numericURL(endpoint).isEmpty { peers[peer.id]?.directAddress = Self.numericURL(endpoint); rememberPeer(peer.id) }
                }
                return response
            } catch {
                if error is CancellationError || Task.isCancelled || index == endpoints.count - 1 { throw error }
                if !RemoteReadRecovery.isTransient(error) { throw error }
            }
        }
        throw RemoteHTTPError(503, "Mac의 연결을 확인해주세요.")
    }
    private func readPeerState(_ peer: Peer) async -> RemoteNodeView {
        let endpoint = connectionEndpoint(peer)
        if let task = stateReads.task(for: peer.id, endpoint: endpoint) { return await task.value }
        let epoch = generation, token = UUID()
        let task = Task { @MainActor [weak self] () -> RemoteNodeView in
            guard let self else { return RemoteNodeView(id: peer.id, name: peer.name, local: false, online: false, error: "웹 연결이 종료되었습니다.", release: peer.release) }
            let result: RemoteNodeView
            do {
                let compact = peer.release.map { $0 >= RemoteWebVersion(version:"0.2.61",build:76,api:1) } == true
                let response = try await RemoteDashboardTraffic.shared.read { @MainActor in try await self.exchange(peer, path: compact ? "/api/inventory" : "/api/state",timeout:4) }
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                let state = try decoder.decode(RemoteNodeState.self, from: response.body)
                guard response.status == 200, state.id == peer.id else { throw RemoteHTTPError(502, "Mac의 연결 정보가 바뀌었습니다. 주소를 다시 추가해주세요.") }
                result = RemoteNodeView(id: peer.id, name: state.name, local: false, online: true, state: state.inventory, release: state.release ?? peer.release)
            } catch { result = RemoteNodeView(id: peer.id, name: peer.name, local: false, online: false, error: error.localizedDescription, release: peer.release) }
            if self.running, self.generation == epoch {
                self.stateReads.finish(id: peer.id, token: token, endpoint: self.peers[peer.id].map(self.connectionEndpoint) ?? endpoint,
                    expires: Date().addingTimeInterval(result.online ? 0.75 : 2))
            }
            return result
        }
        stateReads.insert(task, id: peer.id, token: token, endpoint: endpoint)
        return await task.value
    }
    public func dashboard(initial: Bool = false, selectedNode: String? = nil) async throws -> RemoteDashboard {
        let own = try localState().inventory
        let candidates = Array(peers.values).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if initial {
            var nodes = candidates.prefix(100).map { RemoteNodeView(id:$0.id,name:$0.name,local:false,online:false,release:$0.release,loading:true) }
            if let selectedNode, let peer = candidates.first(where:{$0.id == selectedNode}) {
                let value = await readPeerState(peer)
                if let index = nodes.firstIndex(where:{$0.id == selectedNode}) { nodes[index] = value }
            }
            return RemoteDashboard(gatewayID:nodeID,nodes:[RemoteNodeView(id:nodeID,name:name,local:true,online:true,state:own,release:own.release)]+nodes,
                updatedAt:Date(),discovery:discoveryError,gatewayRelease:webVersion,preferredGateway:preferredGateway(),partial:true)
        }
        let other = await withTaskGroup(of: RemoteNodeView.self) { group in
            for peer in candidates.prefix(100) {
                group.addTask { @MainActor in await self.readPeerState(peer) }
            }
            var result: [RemoteNodeView] = []
            for await node in group { result.append(node) }
            return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        for node in other {
            guard peers[node.id] != nil else { continue }
            guard node.online, let state = node.state else {
                // A single failed read must not erase the last confirmed LAN
                // addresses and send the next request back through Bonjour.
                peers[node.id]?.webVerifiedAt = nil
                continue
            }
            let confirmed = peers[node.id]?.release == node.state?.release && peers[node.id]?.webVerifiedAt != nil
            peers[node.id]?.release = state.release?.isCompatible == true ? state.release : nil
            peers[node.id]?.webURLs = state.webURLs ?? []
            peers[node.id]?.webPort = state.webPort
            peers[node.id]?.webVerifiedAt = node.online && confirmed ? Date() : nil
        }
        updateNamedAddresses(); emitStatus()
        return RemoteDashboard(gatewayID: nodeID, nodes: [RemoteNodeView(id: nodeID, name: name, local: true, online: true, state: own, release: own.release)] + other, updatedAt: Date(), discovery: discoveryError,
            gatewayRelease: webVersion, preferredGateway: preferredGateway())
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
                case "/", "/index.html":
                    if let expected = request.parameter("webNode"), expected != nodeID { throw RemoteHTTPError(409, "이 주소의 Mac이 바뀌었습니다. 원래 즐겨찾기나 Mac의 접속 링크로 다시 열어주세요.") }
                    if let gateway = await verifiedGateway() {
                        return RemoteHTTPResponse(status: 302, body: Data(), contentType: "text/plain; charset=utf-8", location: gateway.url)
                    }
                    return try asset("index.html", type: "text/html; charset=utf-8")
                case "/app.css": return try asset("app.css", type: "text/css; charset=utf-8")
                case "/app.js": return try asset("app.js", type: "text/javascript; charset=utf-8")
                case "/pty.js": return try asset("pty.js", type: "text/javascript; charset=utf-8")
                case "/vendor/xterm.js", "/vendor/xterm-fit.js": return try asset(String(request.path.dropFirst()), type: "text/javascript; charset=utf-8")
                case "/vendor/xterm.css": return try asset("vendor/xterm.css", type: "text/css; charset=utf-8")
                case "/favicon.svg": return try asset("favicon.svg", type: "image/svg+xml")
                case "/api/state":
                    if let forwarded = try await forward(request) { return forwarded }
                    return try .json(localState())
                case "/api/inventory": return try .json(localState().inventory)
                case "/api/history":
                    if let forwarded = try await forward(request) { return forwarded }
                    guard let id = request.parameter("session"), let engine else { throw RemoteHTTPError(400,"세션을 지정해주세요.") }
                    return try .json(engine.remoteHistory(sessionID:id))
                case "/api/update/manifest":
                    let (manifest, _) = try await updateArchive.offer()
                    return try .json(manifest)
                case "/api/update/chunk":
                    guard let hash = request.parameter("sha256"), let value = request.parameter("offset"), let offset = Int(value) else { throw RemoteHTTPError(400, "업데이트 파일과 위치를 지정해주세요.") }
                    return RemoteHTTPResponse(body: try await updateArchive.chunk(hash: hash, offset: offset), contentType: "application/zip")
                case "/api/discovery":
                    var object: JSONObject = ["service": "autoapprove", "version": 1, "id": nodeID, "name": name, "urls": port.map(Self.addresses) ?? [], "port": Int(port ?? 0), "portal": namedAccess?.ownsPortal == true]
                    if let webVersion { object["release"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(webVersion)) }
                    return try .object(object)
                case "/api/network": return try await .json(dashboard(initial:request.parameter("initial") == "1",selectedNode:request.parameter("node")))
                case "/api/test-screen":
                    if let forwarded = try await forward(request) { return forwarded }
                    guard let id = request.parameter("share"), let engine else { throw RemoteHTTPError(400, "화면 공유를 지정해주세요.") }
                    return try await .json(engine.testScreens.frame(id))
                case "/api/codex/queue":
                    if let forwarded = try await forward(request) { return forwarded }
                    guard let id = request.parameter("session"), let engine else { throw RemoteHTTPError(400, "Codex 세션을 지정해주세요.") }
                    return try await .json(engine.remoteCodexQueue(sessionID: id, threadID: request.parameter("thread")))
                case "/api/receipt":
                    if let forwarded = try await forward(request) { return forwarded }
                    guard let id = request.parameter("request"), UUID(uuidString: id) != nil else { throw RemoteHTTPError(400, "전송 요청을 지정해주세요.") }
                    guard let receipt = receipts.first(where: { $0.id == id }) else { return try .object(["requestID": id, "phase": "missing"]) }
                    guard let body = receipt.response, let status = receipt.status else { return try .object(["requestID": id, "phase": "pending"]) }
                    return try .object(["requestID": id, "phase": "completed", "status": status,
                        "result": (try? JSONSerialization.jsonObject(with: body)) ?? [:]])
                case "/api/codex/conversations":
                    if let forwarded = try await forward(request) { return forwarded }
                    guard let id = request.parameter("session"), let engine else { throw RemoteHTTPError(400, "Codex 세션을 지정해주세요.") }
                    return try await .json(engine.remoteCodexConversations(sessionID: id))
                case "/api/terminal":
                    if let forwarded = try await forward(request) { return forwarded }
                    guard let id = request.parameter("session"), let engine else { throw RemoteHTTPError(400, "세션을 지정해주세요.") }
                    let frame = try await engine.remoteTerminal(sessionID: id, renderWindow: request.parameter("view") == "screen")
                    return try .json(RemoteTerminalUpdate(frame, knownRevision: request.parameter("revision")))
                case "/api/terminal/stream":
                    if let forwarded = try await forwardStream(request) { return forwarded }
                    guard let id = request.parameter("session"), let engine else { throw RemoteHTTPError(400, "세션을 지정해주세요.") }
                    let renderWindow = request.parameter("view") == "screen"
                    let frame = try await engine.remoteTerminal(sessionID: id, realtime: true, renderWindow: renderWindow)
                    let tmuxObservation = try engine.remoteTmuxObservation(sessionID: id)
                    let observation = engine.remoteTerminalObservation(sessionID:id)
                    let wakeup: @Sendable (TimeInterval) async -> Void
                    if let tmuxObservation { wakeup = { interval in await tmuxObservation.waitForChange(timeout:interval) } }
                    else { wakeup = { interval in await observation.waitForChange(timeout:interval) } }
                    let output = try RemoteTerminalBodyStream(initial: frame, waitForChange: wakeup,
                        responsive: { [weak engine] in engine?.remoteTerminalNeedsResponsiveRead(id) ?? false }) { [weak engine] in
                        guard let engine else { throw RemoteHTTPError(503, "앱이 종료되었습니다.") }
                        return try await engine.remoteTerminal(sessionID: id, realtime: true, renderWindow: renderWindow)
                    }
                    return .eventStream(output, nodeID: nodeID)
                case "/api/pty/stream", "/api/pty/output":
                    if request.path == "/api/pty/stream" {
                        if let forwarded = try await forwardStream(request) { return forwarded }
                    } else if let forwarded = try await forward(request) { return forwarded }
                    guard let engine, let id = request.parameter("pty") else { throw RemoteHTTPError(400, "PTY를 지정해주세요.") }
                    let terminal = try engine.managedPTY.terminal(id)
                    guard request.parameter("stream") == terminal.descriptor.streamID else { throw RemoteHTTPError(409, "PTY 연결이 바뀌었습니다. 다시 연결해주세요.") }
                    let supplied = request.parameter("offset")
                    guard supplied == nil || Int(supplied!) != nil else { throw RemoteHTTPError(400, "올바른 출력 위치가 필요합니다.") }
                    let offset = supplied.flatMap(Int.init)
                    let client = request.parameter("client")
                    if request.path == "/api/pty/stream" {
                        return .eventStream(try RemotePTYBodyStream(terminal: terminal, offset: offset, client: client), nodeID: nodeID)
                    }
                    let output = try RemotePTYBodyStream(terminal: terminal, offset: offset, client: client, emitInitial: false)
                    defer { output.cancel() }
                    return try await .json(output.readUpdate(timeout: 0.75))
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
                peers[state.id] = Peer(id: state.id, name: state.name, endpoint: endpoint, available: true, manual: true, directAddress: address,
                    release: state.release?.isCompatible == true ? state.release : nil, webURLs: state.webURLs ?? [], webPort: state.webPort)
                updateNamedAddresses(); emitStatus(); refreshWebPeers()
                return try .object(["id": state.id, "name": state.name])
            case "/api/action", "/api/input", "/api/terminal/connect", "/api/pty", "/api/pty/input", "/api/pty/resize", "/api/pty/close":
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
                    else if request.path == "/api/terminal/connect" {
                        let frame = try await engine.connectRemoteTerminal(object)
                        // Receipts must not retain megabytes of JPEGs for an explicit action.
                        // The authoritative stream supplies the full image after this control ack.
                        response = try .json(RemoteTerminalUpdate(frame, knownRevision: frame.revision))
                    }
                    else if request.path == "/api/pty" { response = try await .json(engine.createPTY(object)) }
                    else if request.path == "/api/pty/input" { response = try await .object(engine.ptyInput(object)) }
                    else if request.path == "/api/pty/resize" { response = try .object(engine.ptyResize(object)) }
                    else if request.path == "/api/pty/close" { response = try .object(engine.ptyClose(object)) }
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
        return try await exchange(peer, path: forwardedPath(request), method: request.method, body: request.body)
    }
    private func forwardStream(_ request: RemoteHTTPRequest) async throws -> RemoteHTTPResponse? {
        guard let target = request.parameter("node"), target != nodeID else { return nil }
        guard let peer = peers[target] else { throw RemoteHTTPError(404, "이 Mac을 찾지 못했습니다. 목록을 새로고침해주세요.") }
        guard running, peer.available else { throw RemoteHTTPError(503, "이 Mac이 네트워크에서 연결 해제되었습니다.") }
        let epoch = generation
        let endpoints = Array(peerEndpoints(peer).prefix(2)), deadline = ProcessInfo.processInfo.systemUptime + 7
        for (index, endpoint) in endpoints.enumerated() {
            try Task.checkCancellation()
            let remaining = max(0.05, deadline - ProcessInfo.processInfo.systemUptime)
            let output = try RemotePTYPeerBodyStream(endpoint: endpoint, path: forwardedPath(request), expectedNodeID: peer.id,
                timeout: index == 0 && endpoints.count > 1 ? min(2, remaining / 2) : remaining)
            do {
                try await output.open()
                guard running, generation == epoch, !Task.isCancelled else { throw CancellationError() }
                if peers[peer.id]?.endpoint == peer.endpoint { peers[peer.id]?.preferredEndpoint = endpoint }
                return .eventStream(output, nodeID: nodeID)
            } catch {
                output.cancel()
                if index == endpoints.count - 1 || !RemoteReadRecovery.isTransient(error) { throw error }
            }
        }
        throw RemoteHTTPError(503, "Mac의 스트림 연결을 확인해주세요.")
    }
    private func forwardedPath(_ request: RemoteHTTPRequest) -> String {
        let components = request.components
        // Preserve form encoding while removing the gateway selector. Re-encoding
        // Foundation queryItems turns a literal '%2B' into '+', which means space.
        let items = components.percentEncodedQuery?.split(separator: "&").filter { item in
            let key = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0]
            return String(key).replacingOccurrences(of: "+", with: " ").removingPercentEncoding != "node"
        } ?? []
        let query = items.isEmpty ? "" : "?" + items.joined(separator: "&")
        return components.percentEncodedPath + query
    }
    private func asset(_ filename: String, type: String) throws -> RemoteHTTPResponse {
        // SPM's executable accessor looks beside the main bundle. Packaged apps and their
        // helper keep library resources in Contents/Resources, including after relocation.
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let packaged = [Bundle.main.resourceURL?.appendingPathComponent("AutoApprove_AutoApproveCore.bundle/RemoteWeb/" + filename),
            executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/AutoApprove_AutoApproveCore.bundle/RemoteWeb/" + filename)]
        for candidate in packaged.compactMap({ $0 }) where FileManager.default.fileExists(atPath: candidate.path) {
            return webAsset(try Data(contentsOf: candidate), filename: filename, type: type)
        }
        guard let file = Bundle.module.url(forResource: filename, withExtension: nil, subdirectory: "RemoteWeb") else { throw RemoteHTTPError(500, "웹 화면 파일을 찾지 못했습니다.") }
        return webAsset(try Data(contentsOf: file), filename: filename, type: type)
    }
    private func webAsset(_ data: Data, filename: String, type: String) -> RemoteHTTPResponse {
        guard filename == "index.html", var html = String(data: data, encoding: .utf8) else { return RemoteHTTPResponse(body: data, contentType: type) }
        if let webVersion { html = html.replacingOccurrences(of: "__AUTOAPPROVE_WEB_VERSION__", with: "\(webVersion.version):\(webVersion.build):\(webVersion.api)") }
        let nonce = UUID().uuidString
        html = html.replacingOccurrences(of: "__AUTOAPPROVE_STYLE_NONCE__", with: nonce)
        var response = RemoteHTTPResponse(body: Data(html.utf8), contentType: type); response.styleNonce = nonce; return response
    }
    private func save<T: Encodable>(_ value: T, to file: URL) throws {
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    static func addresses(port: UInt16) -> [String] {
        RemoteLAN.interfaces().map { "http://\($0.address):\(port)" }
    }
}
