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
    /// This name resolves on this Mac only, and is not a LAN address for peers or phones.
    public var localAddressReady: Bool? = nil
    public var inventory: RemoteNodeState {
        var value = self
        value.snapshot.sessions = []; value.snapshot.events = []; value.historyDeferred = true
        value.sessions = value.sessions.map { view in
            var view = view
            view.session = view.session.webInventory
            return view
        }
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
    public var sequence: Int? = nil
    public var question: TerminalChoiceQuestion? = nil
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
    var sequence: Int?
    var question: TerminalChoiceQuestion?
    var screenPatch: RemoteTerminalScreenPatch? = nil
    var screenCopy: RemoteTerminalScreenCopy? = nil
    var appearanceUnchanged: Bool? = nil
    init(_ frame: RemoteTerminalFrame, knownRevision: String?) {
        sessionID = frame.sessionID; revision = frame.revision; observedAt = frame.observedAt
        keys = frame.keys; inputReason = frame.inputReason
        screen = knownRevision == frame.revision ? nil : frame.screen
        appearance = knownRevision == frame.revision ? nil : frame.appearance
        cursor = frame.cursor; streamID = frame.streamID
        nativeDisplay = knownRevision == frame.revision ? frame.nativeDisplay?.compact : frame.nativeDisplay
        outputReason = frame.outputReason
        sequence = frame.sequence
        question = frame.question
    }
    init(_ frame: RemoteTerminalFrame, previous: RemoteTerminalFrame?, delta: Bool, copy: Bool = false) {
        let sameSource = previous?.sessionID == frame.sessionID && previous?.streamID == frame.streamID
        self.init(frame,knownRevision:sameSource ? previous?.revision : nil)
        guard delta, let previous, let streamID = frame.streamID, !streamID.isEmpty, streamID == previous.streamID,
              frame.sessionID == previous.sessionID, frame.revision != previous.revision else { return }
        let patch = RemoteTerminalScreenPatch.make(previous:previous.screen,current:frame.screen,baseRevision:previous.revision)
        let replacementBytes = patch?.text.utf8.count ?? frame.screen.utf8.count
        if copy, replacementBytes > 1024,
           let span = RemoteTerminalScreenCopy.make(previous:previous.screen,current:frame.screen,baseRevision:previous.revision),
           span.head.utf8.count + span.tail.utf8.count + 256 < replacementBytes {
            screen = nil; screenCopy = span
        } else if let patch { screen = nil; screenPatch = patch }
        else { return }
        if frame.appearance == previous.appearance { appearance = nil; appearanceUnchanged = true }
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
    private var interfaceMonitors: [NWPathMonitor] = []
    private var discoveryTask: Task<Void, Never>?
    private var webPeerTask: Task<Void, Never>?
    private var webPeerToken = UUID()
    private var browserRetry: Task<Void, Never>?
    private var browserRetryDelay: TimeInterval = 1
    private var directCursor = 0
    private var directProbedAt: [String: Date] = [:]
    private var pendingHints: [String] = []
    private var nextHintRead = Date.distantPast
    private var nextBlindProbe = Date.distantPast
    private var lanInterfaces: [RemoteLANInterface] = []
    private let bonjourEnabled: Bool
    private let loopbackOnly: Bool
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
    private let terminalFeeds = RemoteTerminalFeeds()
    private var running = false
    private var generation = UUID()
    private var status = RemoteNetworkStatus()
    private let onStatus: (RemoteNetworkStatus) -> Void
    private var lastEmittedStatus: RemoteNetworkStatus?
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
        var readTiming = RemoteReadTiming()
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
    private var foregroundStateReads: [String:UUID] = [:]
    private let inventoryValidation = RemotePeerInventoryCache()
    private let readConnections = RemoteHTTPReadPool()
    private var readTimingEpoch = UUID()
    public init(engine: ApprovalEngine, nodeID: String, name: String? = nil, bonjourEnabled: Bool = true, loopbackOnly: Bool = false, discoveryAddresses: (() -> [String])? = nil, discoveryHints: (@Sendable () -> [String])? = nil, webVersion: RemoteWebVersion? = RemoteWebVersion.current, advertisement: RemoteServiceAdvertising? = nil, onStatus: @escaping (RemoteNetworkStatus) -> Void) {
        self.engine = engine; self.nodeID = nodeID
        updateArchive = LANUpdateArchive(directory: engine.paths.directory.appendingPathComponent("updates/offer"), nodeID: nodeID)
        updateReceiver = LANUpdateReceiver(engine: engine)
        self.loopbackOnly = loopbackOnly
        self.bonjourEnabled = bonjourEnabled && !loopbackOnly
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
        for peer in manualPeers where !loopbackOnly {
            if let endpoint = try? RemoteNetworkAddress.endpoint(peer.address), peer.id != nodeID {
                peers[peer.id] = Peer(id: peer.id, name: peer.name, endpoint: endpoint, available: true, manual: true, directAddress: peer.address)
            }
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        knownPeers = ((try? decoder.decode([KnownPeer].self, from: Data(contentsOf: knownURL))) ?? []).filter {
            UUID(uuidString: $0.id) != nil && $0.id != nodeID && Date().timeIntervalSince($0.lastSeen) < 7 * 86400 && (try? RemoteNetworkAddress.endpoint($0.address)) != nil
        }.prefix(100).map { $0 }
        for peer in knownPeers where !loopbackOnly && peers[peer.id] == nil {
            peers[peer.id] = Peer(id: peer.id, name: peer.name, endpoint: try! RemoteNetworkAddress.endpoint(peer.address), available: false, manual: false,
                directAddress: peer.address, release: peer.release, webURLs: Array(peer.urls.prefix(16)), webPort: peer.port)
        }
    }
    public func start(port preferredPort: UInt16 = 8765, allowPortFallback: Bool = false) throws {
        guard !running else { return }
        let port = preferredPort
        let parameters = listenerParameters()
        lanInterfaces = loopbackOnly ? [] : RemoteLAN.interfaces(refresh: true)
        // Constrain the address here; NWListener remains the single source of
        // the selected port, including persisted ports and busy-port recovery.
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        let epoch = UUID(); generation = epoch; running = true; self.listener = listener
        listenerPort = port; allowListenerPortFallback = allowPortFallback; listenerRetryDelay = 1
        publishedPortal = false
        configureListener(listener, port: port, epoch: epoch)
        status.enabled = true; status.detail = "웹 접속과 같은 네트워크의 Mac을 연결하고 있습니다."
        listener.start(queue: queue)
        startDiscovery(parameters: parameters, epoch: epoch)
    }

    private func listenerParameters() -> NWParameters {
        let parameters = RemoteLAN.tcpParameters()
        if loopbackOnly { parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any) }
        return parameters
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
                    var response = await self.handle(request)
                    if response.nodeID == nil { response.nodeID = self.nodeID }
                    return response
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
                    self.status.ready = true
                    self.status.detail = self.loopbackOnly ? "이 Mac의 127.0.0.1에서만 접속할 수 있습니다." : "같은 네트워크의 휴대폰과 Mac에서 접속할 수 있습니다."
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
                let listener = try NWListener(using: self.listenerParameters(), on: NWEndpoint.Port(rawValue: self.listenerPort)!)
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
        guard !loopbackOnly else { return }
        if bonjourEnabled {
            startBrowser(parameters: parameters, epoch: epoch)
        }
        startDirectDiscovery(epoch: epoch)
        let monitor = NWPathMonitor(prohibitedInterfaceTypes: [.other, .cellular]); pathMonitor = monitor
        let changed: @Sendable (NWPath) -> Void = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.running, self.generation == epoch, self.status.ready, let port = self.port else { return }
                let interfaces = RemoteLAN.interfaces(refresh: true)
                if interfaces != self.lanInterfaces {
                    self.lanInterfaces = interfaces
                    self.readTimingEpoch = UUID()
                    for id in self.peers.keys {
                        self.peers[id]?.nextProbe = .distantPast; self.peers[id]?.preferredEndpoint = nil
                        self.peers[id]?.readTiming = RemoteReadTiming()
                    }
                    self.stateReads.removeAll(); self.inventoryValidation.removeAll()
                    self.readConnections.removeAll()
                    self.foregroundStateReads.removeAll()
                    self.webPeerToken = UUID(); self.webPeerTask?.cancel(); self.webPeerTask = nil
                    self.nextHintRead = .distantPast; self.nextBlindProbe = .distantPast; self.directCursor = 0
                    self.directProbedAt.removeAll(); self.pendingHints.removeAll()
                    self.startDirectDiscovery(epoch: epoch)
                    self.publishService(port: port)
                }
                self.status.port = port; self.updateNamedAddresses(); self.emitStatus()
            }
        }
        monitor.pathUpdateHandler = changed
        monitor.start(queue: queue)
        for kind in [NWInterface.InterfaceType.wifi,.wiredEthernet] {
            let scoped = NWPathMonitor(requiredInterfaceType:kind)
            scoped.pathUpdateHandler = changed; scoped.start(queue:queue); interfaceMonitors.append(scoped)
        }
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
                self.inventoryValidation.prune(liveIDs: Set(self.peers.keys))
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
        webPeerToken = UUID(); foregroundStateReads.removeAll()
        browserRetry?.cancel(); browserRetry = nil
        knownSaveTask?.cancel(); knownSaveTask = nil; saveKnownPeers()
        stateReads.removeAll(); inventoryValidation.removeAll()
        readConnections.removeAll()
        readTimingEpoch = UUID()
        for id in peers.keys { peers[id]?.readTiming = RemoteReadTiming() }
        directProbedAt.removeAll(); pendingHints.removeAll(); directCursor = 0
        namedAccess?.stop(); namedAccess = nil
        listener?.cancel(); listener = nil; browser?.cancel(); browser = nil
        pathMonitor?.cancel(); pathMonitor = nil
        interfaceMonitors.forEach {$0.cancel()}; interfaceMonitors.removeAll()
        let clients = Array(connections.values); connections.removeAll(); streamConnections.removeAll(); clients.forEach { $0.close() }
        terminalFeeds.stop()
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
    private func emitStatus() {
        status.peerCount = peers.values.filter(\.available).count
        guard status != lastEmittedStatus else { return }
        lastEmittedStatus = status
        onStatus(status)
    }
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
        guard !loopbackOnly else { return }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(knownPeers) {
            try? data.write(to: knownURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownURL.path)
        }
    }
    private func refreshWebPeers() {
        guard webPeerTask == nil else { return }
        let epoch = generation, token = UUID()
        let remembered = Dictionary(knownPeers.map { ($0.id,$0.lastSeen) },uniquingKeysWith:max)
        func recent(_ peer: Peer) -> Date {
            max(peer.directlySeen ?? .distantPast,peer.webVerifiedAt ?? .distantPast,remembered[peer.id] ?? .distantPast)
        }
        let candidates = Array(peers.values.filter { $0.nextProbe <= Date() }.sorted {
            if $0.failures != $1.failures { return $0.failures < $1.failures }
            if recent($0) != recent($1) { return recent($0) > recent($1) }
            if $0.manual != $1.manual { return $0.manual }
            if $0.nextProbe != $1.nextProbe { return $0.nextProbe < $1.nextProbe }
            return $0.id < $1.id
        }.prefix(100))
        guard !candidates.isEmpty else { return }
        webPeerToken = token
        webPeerTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.webPeerToken == token { self.webPeerTask = nil } }
            typealias Result = (id:String,endpoint:NWEndpoint,started:Date,found:RemotePeerDiscovery.Found?)
            @MainActor func query(_ peer: Peer) -> @Sendable () async -> Result {
                let endpoints = self.peerEndpoints(peer), id = peer.id, original = peer.endpoint
                return {
                    let started = Date()
                    for endpoint in endpoints {
                        guard !Task.isCancelled else { break }
                        if let found = await RemotePeerDiscovery.probe(endpoint,expectedID:id,address:Self.numericURL(endpoint)) {
                            return (id,original,started,found)
                        }
                    }
                    return (id,original,started,nil)
                }
            }
            await withTaskGroup(of:Result.self) { group in
                var next = min(2,candidates.count)
                for peer in candidates.prefix(next) { group.addTask(operation:query(peer)) }
                // Consume each completion immediately; one slow address cannot
                // hold its healthy neighbour or the next queued peer in a batch.
                while let result = await group.next() {
                    guard self.running, self.generation == epoch, self.webPeerToken == token, !Task.isCancelled else { group.cancelAll(); return }
                    if let current = self.peers[result.id], current.endpoint == result.endpoint,
                       (current.directlySeen ?? .distantPast) <= result.started,
                       (current.webVerifiedAt ?? .distantPast) <= result.started {
                        if let found = result.found { self.acceptWebMetadata(found) }
                        else {
                            let failures = min(5,current.failures+1)
                            self.peers[result.id]?.failures = failures
                            self.peers[result.id]?.nextProbe = Date().addingTimeInterval(pow(2,Double(failures)))
                            self.peers[result.id]?.webVerifiedAt = nil
                            if !current.bonjour && !current.manual,
                               current.webVerifiedAt.map({Date().timeIntervalSince($0)<60}) != true,
                               current.directlySeen.map({Date().timeIntervalSince($0)<60}) != true {
                                self.peers[result.id]?.available = false
                            }
                        }
                        self.updateNamedAddresses(); self.emitStatus()
                    }
                    if next < candidates.count { group.addTask(operation:query(candidates[next])); next += 1 }
                }
            }
        }
    }
    private func newerWebPeers() -> [Peer] {
        guard let webVersion else { return [] }
        return peers.values.filter { $0.available && $0.release?.isCompatible == true && $0.release! > webVersion }
            .sorted { $0.release == $1.release ? $0.id < $1.id : $0.release! > $1.release! }
    }
    private func gateway(_ peer: Peer, client: String? = nil, requireVerified: Bool = true) -> RemoteWebGateway? {
        guard (!requireVerified || verified(peer)), let release = peer.release, let port = peer.webPort else { return nil }
        // Use the proven numeric endpoint first, then physical LAN addresses advertised
        // by the exact Mac. Bonjour names are unsuitable for hotspot-host browsers.
        for address in [peer.directAddress].compactMap({ $0 }) + peer.webURLs {
            let supplied = address.contains("://") ? address : "http://" + address
            guard (try? RemoteNetworkAddress.endpoint(supplied)) != nil, var url = URLComponents(string: supplied),
                  let host = url.host, let ipv4 = IPv4Address(host), UInt16(exactly: url.port ?? 8765) == port else { continue }
            let bytes = Array(ipv4.rawValue)
            guard RemoteLAN.sharesClientLAN(host,client:client,interfaces:lanInterfaces) else { continue }
            guard bytes[0] == 127 || lanInterfaces.contains(where: { $0.address == host }) || RemoteLAN.route(to: host, interfaces: lanInterfaces) != nil else { continue }
            url.port = Int(port); url.path = "/"; url.queryItems = [URLQueryItem(name: "webNode", value: peer.id)]
            if let value = url.string { return RemoteWebGateway(id: peer.id, name: peer.name, url: value, release: release) }
        }
        return nil
    }
    private func preferredGateway(client: String? = nil) -> RemoteWebGateway? {
        newerWebPeers().compactMap {gateway($0,client:client)}.first
    }
    private func updateNamedAddresses() {
        guard running, status.ready, let port = status.port, !updatingNamedAccess else { return }
        if loopbackOnly { status.urls = ["http://127.0.0.1:\(port)"]; return }
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
                nextProbe: unchanged ? previous?.nextProbe ?? .distantPast : .distantPast, failures: previous?.failures ?? 0, bonjourEndpoint: result.endpoint, preferredEndpoint: unchanged ? previous?.preferredEndpoint : nil,
                readTiming: unchanged ? previous?.readTiming ?? RemoteReadTiming() : RemoteReadTiming())
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
            let known = Set(peers.values.flatMap { [$0.directAddress].compactMap {$0} + $0.webURLs })
            pendingHints = Array(hints.prefix(64)).filter { !known.contains($0) && directProbedAt[$0].map { Date().timeIntervalSince($0) < 60 } != true }
        }
        var addresses: [String] = []
        if !pendingHints.isEmpty { addresses = Array(pendingHints.prefix(2)); pendingHints.removeFirst(addresses.count) }
        else if Date() >= nextBlindProbe {
            // Preparing hundreds of subnet candidates also reads interface
            // metadata. Do it only when a blind probe is actually due, after
            // passive hints, rather than on every 250-ms maintenance tick.
            var seen = Set<String>()
            let candidates = Array(discoveryAddresses().prefix(512)).filter { seen.insert($0).inserted }
            if !candidates.isEmpty {
                let known = Set(peers.values.flatMap { [ $0.directAddress ].compactMap { $0 } + $0.webURLs })
                let lanes = Set(candidates.map {RemoteLAN.discoveryLane($0,interfaces:lanInterfaces)})
                let reached = Set(peers.values.filter {verified($0)}.flatMap {peer in
                    ([peer.directAddress,peer.preferredEndpoint.map(Self.numericURL)].compactMap {$0}).map {RemoteLAN.discoveryLane($0,interfaces:lanInterfaces)}
                })
                let allReached = !lanes.isEmpty && lanes.isSubset(of:reached)
                nextBlindProbe = Date().addingTimeInterval(allReached ? min(5, max(0.5, directDiscoveryInterval)) : 0.5)
                var selectedLanes = Set<String>()
                for _ in 0..<candidates.count {
                    let address = candidates[directCursor % candidates.count]; directCursor = (directCursor + 1) % candidates.count
                    let lane = RemoteLAN.discoveryLane(address,interfaces:lanInterfaces)
                    if !known.contains(address), !selectedLanes.contains(lane), directProbedAt[address].map({ Date().timeIntervalSince($0) >= max(10, directDiscoveryInterval) }) ?? true {
                        addresses.append(address); selectedLanes.insert(lane)
                        if addresses.count == 2 || selectedLanes.count == lanes.count { break }
                    }
                }
            }
        }
        for address in addresses { directProbedAt[address] = Date() }
        directProbedAt = directProbedAt.filter { Date().timeIntervalSince($0.value) < 300 }
        guard !addresses.isEmpty else { return }
        await withTaskGroup(of: RemotePeerDiscovery.Found?.self) { group in
            for address in addresses { group.addTask { await RemotePeerDiscovery.find(address) } }
            for await value in group {
                guard running, generation == epoch, !Task.isCancelled else { group.cancelAll(); return }
                guard let peer = value, peer.id != nodeID else { continue }
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
                updateNamedAddresses(); emitStatus()
            }
        }
    }
    private func localState() throws -> RemoteNodeState {
        guard let engine else { throw RemoteHTTPError(503, "앱이 종료되었습니다.") }
        return RemoteNodeState(id: nodeID, name: name, snapshot: engine.snapshot, sessions: engine.remoteSessionViews(),
            release: webVersion, webURLs: port.map(Self.addresses), webPort: port,
            questionForms: engine.webQuestions.pending(), screenShares: engine.testScreens.active, update: engine.lanUpdate,
            localAddressReady:LocalDashboardAddress.status() == .ready)
    }
    private enum PeerReadResult: Sendable { case stagger; case response(Int,RemoteHTTPResponse,TimeInterval) }
    private func exchange(_ peer: Peer, path: String, method: String = "GET", body: Data = Data(), timeout: TimeInterval? = nil, entityTag: String? = nil, allowUnavailableRead: Bool = false) async throws -> RemoteHTTPResponse {
        guard running, peer.available || allowUnavailableRead && method == "GET" && body.isEmpty else { throw RemoteHTTPError(503, "이 Mac이 네트워크에서 연결 해제되었습니다.") }
        let primary = connectionEndpoint(peer)
        guard method == "GET", body.isEmpty else {
            let response = try await RemoteHTTPExchange(endpoint: primary, path: path, method: method, body: body, expectedNodeID: peer.id).run()
            stateReads.remove(peer.id)
            inventoryValidation.remove(peer.id)
            return response
        }
        let endpoints = Array(peerEndpoints(peer).prefix(2))
        guard endpoints.count > 1 else { return try await readConnections.read(endpoint:primary,path:path,expectedNodeID:peer.id,timeout:timeout,entityTag:entityTag,
            retryReads:!["/api/state","/api/inventory"].contains(path)) }
        let deadline = ProcessInfo.processInfo.systemUptime + (timeout ?? (["/api/state","/api/inventory"].contains(path) ? 4 : 15))
        let epoch = generation
        let timingEpoch = readTimingEpoch, kind = RemoteReadTiming.Kind.finite(path: path)
        let delay = peer.readTiming.delay(route: String(describing: endpoints[0]), kind: kind)
        let expectedID = peer.id
        let readConnections = self.readConnections
        let read: @Sendable (Int) async throws -> PeerReadResult = { index in
            let started = ProcessInfo.processInfo.systemUptime
            let response = try await readConnections.read(endpoint:endpoints[index],path:path,expectedNodeID:expectedID,
                timeout:max(0.05,deadline-ProcessInfo.processInfo.systemUptime),entityTag:entityTag,retryReads:false)
            if [502,503,504].contains(response.status) { throw RemoteHTTPError(response.status,"Mac의 읽기 연결을 다른 LAN 주소에서 확인합니다.") }
            return .response(index,response,ProcessInfo.processInfo.systemUptime-started)
        }
        // Adapt the optional alternate to this route's response time and jitter.
        // A definite transport failure still wakes it immediately.
        // Both requests share the original deadline; POST never enters here.
        let winner = try await withThrowingTaskGroup(of:PeerReadResult.self) { group -> (Int,RemoteHTTPResponse,TimeInterval) in
            group.addTask { try await read(0) }
            group.addTask { try await Task.sleep(for:.seconds(delay)); return .stagger }
            var alternate = false, active = 1
            while !group.isEmpty {
              do {
                guard let result = try await group.next() else { break }
                switch result {
                case .response(let index,let response,let elapsed): group.cancelAll(); return (index,response,elapsed)
                case .stagger:
                    if !alternate { alternate = true; active += 1; group.addTask { try await read(1) } }
                }
              } catch {
                guard RemoteReadRecovery.isTransient(error) else { group.cancelAll(); throw error }
                try Task.checkCancellation()
                active -= 1
                if !alternate { alternate = true; active += 1; group.addTask { try await read(1) } }
                else if active == 0 { group.cancelAll(); throw error }
              }
            }
            throw RemoteHTTPError(503,"Mac의 연결을 확인해주세요.")
        }
        guard running, generation == epoch, !Task.isCancelled else { throw CancellationError() }
        let endpoint = endpoints[winner.0], response = winner.1
        if timingEpoch == readTimingEpoch, response.nodeID == peer.id, [200,304].contains(response.status), peers[peer.id]?.endpoint == peer.endpoint {
            peers[peer.id]?.readTiming.observe(route: String(describing: endpoint), kind: kind, elapsed: winner.2)
        }
        if (response.status == 200 || response.status == 304 && response.nodeID == peer.id), peers[peer.id]?.endpoint == peer.endpoint {
            peers[peer.id]?.preferredEndpoint = endpoint
            if !Self.numericURL(endpoint).isEmpty { peers[peer.id]?.directAddress = Self.numericURL(endpoint); rememberPeer(peer.id) }
        }
        return response
    }
    private func peerStateTask(_ peer: Peer, foreground: Bool = false) -> Task<RemoteNodeView, Never> {
        let endpoint = connectionEndpoint(peer)
        // A selected bookmark may replace a queued background/negative read.
        // Existing fresh success and simultaneous selected readers still share.
        if foreground, foregroundStateReads[peer.id] == nil, stateReads.value(for:peer.id,endpoint:endpoint)?.online != true {
            stateReads.remove(peer.id)
        }
        if let task = stateReads.task(for: peer.id, endpoint: endpoint) { return task }
        let epoch = generation, token = UUID()
        foregroundStateReads[peer.id] = foreground ? token : nil
        let task = Task { @MainActor [weak self] () -> RemoteNodeView in
            guard let self else { return RemoteNodeView(id: peer.id, name: peer.name, local: false, online: false, error: "웹 연결이 종료되었습니다.", release: peer.release) }
            defer { if self.foregroundStateReads[peer.id] == token { self.foregroundStateReads.removeValue(forKey:peer.id) } }
            let result: RemoteNodeView
            do {
                try Task.checkCancellation()
                guard self.stateReads.isCurrent(id:peer.id,token:token) else { throw CancellationError() }
                let compact = peer.release.map { $0 >= RemoteWebVersion(version:"0.2.61",build:76,api:1) } == true
                let tag = compact ? self.inventoryValidation.requestTag(for: peer.id, endpoint: endpoint) : nil
                let response = try await RemoteDashboardTraffic.shared.read(foreground:foreground) { @MainActor in
                    try await self.exchange(peer,path:compact ? "/api/inventory" : "/api/state",timeout:4,entityTag:tag,allowUnavailableRead:foreground)
                }
                try Task.checkCancellation()
                guard self.running, self.generation == epoch, self.stateReads.isCurrent(id:peer.id,token:token) else { throw CancellationError() }
                let state: RemoteNodeState
                if compact {
                    state = try self.inventoryValidation.resolve(response, requestedTag:tag, id:peer.id, endpoint:endpoint)
                } else {
                    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                    state = try decoder.decode(RemoteNodeState.self, from: response.body)
                }
                guard [200,304].contains(response.status), state.id == peer.id else { throw RemoteHTTPError(502, "Mac의 연결 정보가 바뀌었습니다. 주소를 다시 추가해주세요.") }
                self.markPeerRead(peer)
                result = RemoteNodeView(id: peer.id, name: state.name, local: false, online: true, state: state.inventory, release: state.release ?? peer.release)
            } catch {
                if self.generation == epoch, self.stateReads.isCurrent(id:peer.id,token:token) { self.inventoryValidation.remove(peer.id) }
                result = RemoteNodeView(id: peer.id, name: peer.name, local: false, online: false, error: error.localizedDescription, release: peer.release)
            }
            if self.running, self.generation == epoch {
                self.stateReads.finish(id: peer.id, token: token, endpoint: self.peers[peer.id].map(self.connectionEndpoint) ?? endpoint,
                    expires: Date().addingTimeInterval(result.online ? 3 : 2), value:result)
            }
            return result
        }
        stateReads.insert(task, id: peer.id, token: token, endpoint: endpoint)
        return task
    }
    public func dashboard(initial: Bool = false, selectedNode: String? = nil, client: String? = nil) async throws -> RemoteDashboard {
        let own = try localState().inventory
        let candidates = Array(peers.values).sorted {
            if verified($0) != verified($1) { return verified($0) }
            if $0.available != $1.available { return $0.available }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        var completed: [String:(NWEndpoint,RemoteNodeView)] = [:]
        func value(_ peer: Peer) -> RemoteNodeView? {
            let endpoint = peers[peer.id].map(connectionEndpoint) ?? connectionEndpoint(peer)
            if let result = stateReads.value(for:peer.id,endpoint:endpoint) { completed[peer.id] = (endpoint,result) }
            return completed[peer.id].flatMap { $0.0 == endpoint ? $0.1 : nil }
        }
        func waitForReads(_ peers: [Peer], progressive: Bool = false) async throws {
            for peer in peers { _ = peerStateTask(peer,foreground:peer.id == selectedNode) }
            // Keep the first usable inventory independent of slow peers. Once
            // one arrives, allow a short burst for its healthy neighbours.
            // A selected Mac retains its own full bounded wait instead.
            let selected = selectedNode.flatMap { id in peers.first { $0.id == id } }
            if progressive, selected == nil, peers.contains(where: { value($0)?.online == true }) { return }
            let until = ProcessInfo.processInfo.systemUptime + 0.35
            var readyUntil: TimeInterval?
            while true {
                try Task.checkCancellation()
                let revision = stateReads.revision
                guard peers.contains(where: { value($0) == nil }) else { return }
                if progressive {
                    if let selected {
                        if value(selected) != nil { return }
                    } else if peers.contains(where: { value($0)?.online == true }), readyUntil == nil {
                        readyUntil = ProcessInfo.processInfo.systemUptime + 0.008
                    }
                }
                let remaining = min(until,readyUntil ?? until) - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { return }
                await stateReads.waitForChange(after: revision, timeout: remaining)
            }
        }
        if initial {
            var nodes = candidates.prefix(100).map { RemoteNodeView(id:$0.id,name:$0.name,local:false,online:false,release:$0.release,loading:true) }
            if let selectedNode, let peer = candidates.first(where:{$0.id == selectedNode}) {
                try await waitForReads([peer])
                if let index = nodes.firstIndex(where:{$0.id == selectedNode}), let completed = value(peer) { nodes[index] = completed }
            }
            return RemoteDashboard(gatewayID:nodeID,nodes:[RemoteNodeView(id:nodeID,name:name,local:true,online:true,state:own,release:own.release)]+nodes,
                updatedAt:Date(),discovery:discoveryError,gatewayRelease:webVersion,preferredGateway:preferredGateway(client:client),partial:true)
        }
        let requested = Array(candidates.prefix(100))
        try await waitForReads(requested,progressive:true)
        let other = requested.map { peer in value(peer) ?? RemoteNodeView(id:peer.id,name:peer.name,local:false,online:false,release:peer.release,loading:true) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for node in other {
            guard peers[node.id] != nil else { continue }
            if node.loading == true { continue } // An unfinished read is not a failed identity or route check.
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
            gatewayRelease: webVersion, preferredGateway: preferredGateway(client:client),partial:other.contains(where:{$0.loading == true}) ? true : nil)
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
                    // Every client owns its entry document. A newer/offline Mac
                    // cannot delay or redirect a phone's first byte or local alias.
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
                case "/api/inventory":
                    return try await localState().inventory.response(ifNoneMatch:request.headers["if-none-match"],
                        acceptsGzip:RemoteGzipEncoder.accepts(request.headers["accept-encoding"]))
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
                case "/api/network":
                    let current = try await dashboard(initial:request.parameter("initial") == "1",selectedNode:request.parameter("node"),client:request.clientAddress)
                    return try current.response(ifNoneMatch: request.headers["if-none-match"])
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
                case "/api/terminal/timings":
                    if let forwarded = try await forward(request) { return forwarded }
                    return try .json(RemoteTerminalPerformance.shared.snapshot())
                case "/api/terminal":
                    if let forwarded = try await forward(request) { return forwarded }
                    guard let id = request.parameter("session"), let engine else { throw RemoteHTTPError(400, "세션을 지정해주세요.") }
                    let frame = try await RemoteTerminalReadRecovery.read {
                        try await engine.remoteTerminal(sessionID:id,renderWindow:request.parameter("view") == "screen",initial:request.parameter("initial") == "1")
                    }
                    return try RemoteTerminalPerformance.shared.measure(.responseEncoding) {
                        try .terminalJSON(RemoteTerminalUpdate(frame, knownRevision:request.parameter("revision")))
                    }
                case "/api/terminal/stream":
                    if let forwarded = try await forwardStream(request) { return forwarded }
                    guard let id = request.parameter("session"), let engine else { throw RemoteHTTPError(400, "세션을 지정해주세요.") }
                    let renderWindow = request.parameter("view") == "screen"
                    let key = RemoteTerminalFeeds.Key(session:id,window:renderWindow)
                    let subscription = try await terminalFeeds.subscribe(key:key,initial:{ [weak engine] in
                        guard let engine else { throw RemoteHTTPError(503,"앱이 종료되었습니다.") }
                        return try await engine.remoteTerminal(sessionID:id,realtime:true,renderWindow:renderWindow,initial:true)
                    },observation:{ [weak engine] in
                        if let tmux = try engine?.remoteTmuxObservation(sessionID:id) {
                            return { interval in await tmux.waitForChange(timeout:interval) }
                        }
                        let observation = engine?.remoteTerminalObservation(sessionID:id)
                        return { interval in
                            if let observation { await observation.waitForChange(timeout:interval) }
                            else { try? await Task.sleep(for:.seconds(interval)) }
                        }
                    },responsive:{ [weak engine] in engine?.remoteTerminalNeedsResponsiveRead(id) ?? false }) { [weak engine] in
                        guard let engine else { throw RemoteHTTPError(503,"앱이 종료되었습니다.") }
                        return try await engine.remoteTerminal(sessionID:id,realtime:true,renderWindow:renderWindow)
                    }
                    let frame = subscription.initial
                    let delta = request.parameter("delta") == "1"
                    let base = delta ? terminalFeeds.base(key:key,revision:request.parameter("revision"),stream:request.parameter("stream"),current:frame) : nil
                    let output: RemoteTerminalBodyStream
                    do {
                        output = try RemoteTerminalBodyStream(initial:frame,emitInitial:false,delta:delta,copy:request.parameter("copy") == "1",
                            resume:base,compact:request.parameter("compact") == "1" && !renderWindow,paced:true,
                            onCancel:{ subscription.cancel() }) { try await subscription.next() }
                    } catch { subscription.cancel(); throw error }
                    // The verified first event is ready. Send it with the headers,
                    // without another main-actor hop or a second small TCP write.
                    return .eventStream(output, nodeID: nodeID, initialData: output.initialEvent)
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
                guard !loopbackOnly else { throw RemoteHTTPError(403, "로컬 전용 실행에서는 다른 Mac을 연결하지 않습니다.") }
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
    private func markPeerRead(_ peer: Peer) {
        guard running, !Task.isCancelled, peers[peer.id]?.endpoint == peer.endpoint else { return }
        peers[peer.id]?.available = true; peers[peer.id]?.directlySeen = Date(); peers[peer.id]?.failures = 0
    }
    private func forward(_ request: RemoteHTTPRequest) async throws -> RemoteHTTPResponse? {
        guard let target = request.parameter("node"), target != nodeID else { return nil }
        guard let peer = peers[target] else { throw RemoteHTTPError(404, "이 Mac을 찾지 못했습니다. 목록을 새로고침해주세요.") }
        let measured = request.method == "GET" && request.path == "/api/terminal"
        let start = RemoteTerminalPerformance.now; var succeeded = false
        defer { if measured { RemoteTerminalPerformance.shared.observe(.relayHTTP,elapsed:RemoteTerminalPerformance.now-start,succeeded:succeeded) } }
        let read = request.method == "GET" && request.body.isEmpty
        let response = try await exchange(peer,path:forwardedPath(request),method:request.method,body:request.body,allowUnavailableRead:read)
        // Only an exact fresh identity can restore a saved/offline read route.
        // Legacy peers without the header still use metadata discovery first.
        if !peer.available, response.nodeID != peer.id {
            throw RemoteHTTPError(502,"저장한 주소의 Mac을 확인하지 못했습니다. 목록을 새로고침해주세요.",diagnostics:["failureKind":"identity"])
        }
        if read, response.status == 200, response.nodeID == peer.id { markPeerRead(peer) }
        succeeded = response.status < 400
        return response
    }
    private enum PeerStreamResult: Sendable { case stagger; case opened(Int,RemotePTYPeerBodyStream,TimeInterval,Data) }
    private func forwardStream(_ request: RemoteHTTPRequest) async throws -> RemoteHTTPResponse? {
        guard let target = request.parameter("node"), target != nodeID else { return nil }
        guard let peer = peers[target] else { throw RemoteHTTPError(404, "이 Mac을 찾지 못했습니다. 목록을 새로고침해주세요.") }
        guard running else { throw RemoteHTTPError(503, "이 Mac이 네트워크에서 연결 해제되었습니다.") }
        let measured = request.path == "/api/terminal/stream", start = RemoteTerminalPerformance.now
        var succeeded = false
        defer { if measured { RemoteTerminalPerformance.shared.observe(.relayStreamOpen,elapsed:RemoteTerminalPerformance.now-start,succeeded:succeeded) } }
        let epoch = generation
        let endpoints = Array(peerEndpoints(peer).prefix(2)), deadline = ProcessInfo.processInfo.systemUptime + 7
        let timingEpoch = readTimingEpoch
        let delay = peer.readTiming.delay(route: String(describing: endpoints[0]), kind: .stream)
        let path = forwardedPath(request), expectedID = peer.id
        let open: @Sendable (Int) async throws -> PeerStreamResult = { index in
            try Task.checkCancellation()
            let started = ProcessInfo.processInfo.systemUptime
            let output = try RemotePTYPeerBodyStream(endpoint: endpoints[index], path: path, expectedNodeID: expectedID,
                timeout: max(0.05, deadline - started))
            do {
                let initial = try await output.open(); try Task.checkCancellation()
                return .opened(index,output,ProcessInfo.processInfo.systemUptime-started,initial)
            } catch { output.cancel(); throw error }
        }
        // Keep opening latency separate from finite bodies. Failed transports
        // wake the alternate immediately; healthy but busy peers avoid duplicates.
        let opened = try await withThrowingTaskGroup(of: PeerStreamResult.self) { group -> (Int,RemotePTYPeerBodyStream,TimeInterval,Data) in
            group.addTask { try await open(0) }
            if endpoints.count > 1 { group.addTask { try await Task.sleep(for: .seconds(delay)); return .stagger } }
            var alternate = endpoints.count < 2, active = 1
            while !group.isEmpty {
                do {
                    guard let result = try await group.next() else { break }
                    switch result {
                    case .opened(let index,let output,let elapsed,let initial): group.cancelAll(); return (index,output,elapsed,initial)
                    case .stagger:
                        if !alternate { alternate = true; active += 1; group.addTask { try await open(1) } }
                    }
                } catch {
                    if !RemoteReadRecovery.isTransient(error) { group.cancelAll(); throw error }
                    try Task.checkCancellation()
                    active -= 1
                    if !alternate { alternate = true; active += 1; group.addTask { try await open(1) } }
                    else if active == 0 { group.cancelAll(); throw error }
                }
            }
            throw RemoteHTTPError(503, "Mac의 스트림 연결을 확인해주세요.")
        }
        guard running, generation == epoch, !Task.isCancelled else { opened.1.cancel(); throw CancellationError() }
        if peers[peer.id]?.endpoint == peer.endpoint {
            peers[peer.id]?.preferredEndpoint = endpoints[opened.0]
            if timingEpoch == readTimingEpoch {
                peers[peer.id]?.readTiming.observe(route: String(describing: endpoints[opened.0]), kind: .stream, elapsed: opened.2)
            }
        }
        markPeerRead(peer)
        succeeded = true
        return .eventStream(opened.1, nodeID: nodeID, initialData: opened.3)
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
