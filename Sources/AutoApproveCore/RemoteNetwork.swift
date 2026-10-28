import Foundation
import Network
import Darwin

public struct RemoteNetworkStatus: Codable, Equatable {
    public var enabled = false
    public var ready = false
    public var urls: [String] = []
    public var port: UInt16?
    public var loopbackURL:String?
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
    public var terminalWireVersion: Int? = nil
    public var networkWaitVersion: Int? = nil
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
    public var terminalWireVersion: Int? = nil
    public var networkWaitVersion: Int? = nil
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
    private let publishedUpdates:PublishedUpdates
    private var pendingPublishedOffer:PublishedReleaseOffer?
    private var publishedUpdateMaintenance:Task<Void,Never>?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var pathMonitor: NWPathMonitor?
    private var interfaceMonitors: [NWPathMonitor] = []
    private var pathChanges = RemoteNetworkPathChanges()
    private var discoveryTask: Task<Void, Never>?
    private var webPeerTask: Task<Void, Never>?
    private var webPeerToken = UUID()
    private var nextWebPeerRefresh = Date.distantPast
    private var browserRetry: Task<Void, Never>?
    private var browserRetryDelay: TimeInterval = 1
    private var directCursor = 0
    private var directProbedAt: [String: Date] = [:]
    private var nextDirectProbePrune = Date.distantPast
    private var pendingHints: [String] = []
    private var nextHintRead = Date.distantPast
    private var nextBlindProbe = Date.distantPast
    private struct DirectDiscoveryAddress {
        let address: String
        let lane: String
    }
    private var cachedDirectAddresses: [DirectDiscoveryAddress]?
    private var lanInterfaces: [RemoteLANInterface] = []
    private let bonjourEnabled: Bool
    private let loopbackOnly: Bool
    private var listenerLoopbackHost="127.0.0.1"
    private let advertisement: RemoteServiceAdvertising
    private let discoveryAddresses: () -> [String]
    private let cacheDiscoveryAddresses: Bool
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
    private var httpDeadlines: RemoteHTTPDeadlines?
    private var connections: [UUID: RemoteHTTPConnection] = [:]
    private var pendingIdleAdmissions = 0
    private var streamConnections: Set<UUID> = []
    private let terminalFeeds = RemoteTerminalFeeds()
    private var running = false
    private let dashboardEncodingPreparation: (@Sendable () async throws -> Void)?
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
    private struct DashboardPeerOrderKey: Equatable {
        let id: String
        let name: String
        let available: Bool
        let verified: Bool
        let release: RemoteWebVersion?
        let directAddress: String?
        let webURLs: [String]
        let webPort: UInt16?
    }
    private struct DashboardNodeOrderKey: Equatable {
        let id: String
        let name: String
    }
    private var dashboardPeerOrderKeys: [DashboardPeerOrderKey] = []
    private var dashboardPeerKeysByID: [String: DashboardPeerOrderKey] = [:]
    private var dashboardPeerOrder: [String] = []
    private var dashboardNodeOrderKeys: [DashboardNodeOrderKey] = []
    private var dashboardNodeOrder: [Int] = []
    private struct DashboardGatewayKey: Equatable {
        let id: String
        let name: String
        let url: String
        let release: RemoteWebVersion
    }
    private struct DashboardResponseKey: Equatable {
        let initial: Bool
        let selectedNode: String?
        let client: String?
        let engineRevision: UInt64
        let stateReadsRevision: UUID
        let peers: [DashboardPeerOrderKey]
        let discovery: String?
        let webVersion: RemoteWebVersion?
        let urls: [String]
        let webPort: UInt16?
        let questionForms: [WebQuestionRequest]
        let screenShares: [TestScreenShare]
        let update: LANUpdateStatus
        let localAddressReady: Bool
        let preferredGateway: DashboardGatewayKey?
    }
    private struct CachedDashboardValidator {
        let key: DashboardResponseKey
        let entityTag: String
    }
    private var cachedDashboardValidator: CachedDashboardValidator?
    private struct DashboardEncodingLease: Sendable {
        let id = UUID()
        let cancellation = RemoteDashboardEncodingCancellation()
    }
    @MainActor private final class DashboardEncodingWork {
        let id: UUID
        let key: DashboardResponseKey?
        let epoch: UUID
        let promise = RemoteDashboardEncodingPromise()
        let cancellation = RemoteDashboardEncodingCancellation()
        var preparationTask: Task<Void, Never>?
        var validatorChecked = false
        var waiters: [UUID: RemoteDashboardEncodingCancellation] = [:]
        init(id: UUID, key: DashboardResponseKey?, epoch: UUID) {
            self.id = id; self.key = key; self.epoch = epoch
        }
        var hasInterestedWaiter: Bool { waiters.values.contains { !$0.isCancelled() } }
    }
    private var dashboardEncodingWork: [UUID: DashboardEncodingWork] = [:]
    private var joinableDashboardEncoding: UUID?
    /// Active library request leases only; no terminal or response data is exposed.
    public var dashboardEncodingWaiterCount: Int {
        dashboardEncodingWork.values.reduce(0) { count, work in
            count + work.waiters.values.reduce(0) { $0 + ($1.isCancelled() ? 0 : 1) }
        }
    }
    private struct LocalInventoryResponseKey: Equatable {
        let engineRevision: UInt64
        let webVersion: RemoteWebVersion?
        let urls: [String]
        let webPort: UInt16?
        let questionForms: [WebQuestionRequest]
        let screenShares: [TestScreenShare]
        let update: LANUpdateStatus
        let localAddressReady: Bool
    }
    private struct CachedLocalInventoryValidator {
        let key: LocalInventoryResponseKey
        let entityTag: String
        let acceptsGzip: Bool
    }
    private var cachedLocalInventoryValidator: CachedLocalInventoryValidator?
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
    private let inventoryChanges = RemoteTerminalChangeSignal()
    private let engineInventorySignal: RemoteTerminalChangeSignal
    private var engineInventoryObserver: UUID?
    private var inventoryWaiters = 0, dashboardWaiters = 0
    private var inventoryWatches: [String:(UUID,Task<Void,Never>)] = [:]
    private var inventoryWatchReads: [String:UUID] = [:]
    private var inventoryWatchDelay: [String:TimeInterval] = [:]
    private var inventoryWatchRetirement: Task<Void,Never>?
    public init(engine: ApprovalEngine, nodeID: String, name: String? = nil, bonjourEnabled: Bool = true, loopbackOnly: Bool = false, discoveryAddresses: (() -> [String])? = nil, discoveryHints: (@Sendable () -> [String])? = nil, webVersion: RemoteWebVersion? = RemoteWebVersion.current, advertisement: RemoteServiceAdvertising? = nil, dashboardEncodingPreparation: (@Sendable () async throws -> Void)? = nil, onStatus: @escaping (RemoteNetworkStatus) -> Void) {
        engineInventorySignal = engine.remoteInventoryChanges
        self.engine = engine; self.nodeID = nodeID
        updateArchive = LANUpdateArchive(directory: engine.paths.directory.appendingPathComponent("updates/offer"), nodeID: nodeID)
        updateReceiver = LANUpdateReceiver(engine: engine)
        publishedUpdates=PublishedUpdates(services:engine.publishedUpdateServices)
        self.loopbackOnly = loopbackOnly
        self.bonjourEnabled = bonjourEnabled && !loopbackOnly
        self.advertisement = advertisement ?? RemoteServiceAdvertisement()
        self.discoveryAddresses = discoveryAddresses ?? RemotePeerDiscovery.addresses
        self.cacheDiscoveryAddresses = discoveryAddresses.map { _ in false } ?? true
        if let discoveryHints { self.discoveryHints = discoveryHints }
        else if discoveryAddresses == nil { self.discoveryHints = { RemoteLAN.neighborURLs() } }
        else { self.discoveryHints = { [] } }
        self.name = name ?? Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        self.webVersion = webVersion?.isCompatible == true ? webVersion : nil
        self.onStatus = onStatus
        self.dashboardEncodingPreparation = dashboardEncodingPreparation
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
        let changes = inventoryChanges
        engineInventoryObserver = engine.remoteInventoryChanges.add { [weak changes] in changes?.notify() }
        stateReads.onChange = { [weak changes] in changes?.notify() }
    }
    deinit { if let engineInventoryObserver { engineInventorySignal.remove(engineInventoryObserver) } }

    private func stopInventoryWatches() {
        inventoryWatchRetirement?.cancel(); inventoryWatchRetirement = nil
        for (_,task) in inventoryWatches.values { task.cancel() }; inventoryWatches.removeAll()
        for (id,token) in inventoryWatchReads where stateReads.isCurrent(id:id,token:token) { stateReads.remove(id) }
        inventoryWatchReads.removeAll(); inventoryWatchDelay.removeAll()
    }
    private func beginInventoryWatches() {
        inventoryWatchRetirement?.cancel(); inventoryWatchRetirement = nil
        for peer in orderedDashboardPeers().filter({$0.available}).prefix(8) {
            let endpoint = connectionEndpoint(peer)
            guard inventoryWatches[peer.id] == nil, stateReads.value(for:peer.id,endpoint:endpoint)?.state?.networkWaitVersion == 1 else { continue }
            let token = UUID(), epoch = generation
            let task = Task { @MainActor [weak self] in
                defer { if self?.inventoryWatches[peer.id]?.0 == token { self?.inventoryWatches.removeValue(forKey:peer.id) } }
                while !Task.isCancelled {
                    guard let self,self.running,self.generation == epoch,let current=self.peers[peer.id],current.available else { return }
                    let value = await self.peerStateTask(current,watch:true).value
                    guard !Task.isCancelled else { return }
                    let delay = value.online ? self.inventoryWatchDelay[peer.id] ?? 2.5 : 2.5
                    do { try await Task.sleep(for:.seconds(delay)) } catch { return }
                }
            }
            inventoryWatches[peer.id] = (token,task)
        }
    }
    private func endInventoryWatches() {
        guard dashboardWaiters == 0 else { return }
        // Bridge the browser's response/next-request gap, then release every
        // owned upstream read when its last visible subscriber leaves.
        inventoryWatchRetirement?.cancel()
        inventoryWatchRetirement = Task { @MainActor [weak self] in
            do { try await Task.sleep(for:.milliseconds(250)) } catch { return }
            guard let self,self.dashboardWaiters == 0 else { return };self.stopInventoryWatches()
        }
    }
    private func waitForInventory(_ request:RemoteHTTPRequest,dashboard:Bool,read:() async throws -> RemoteHTTPResponse) async throws -> RemoteHTTPResponse {
        let requested = request.headers["prefer"]?.split(separator:",").compactMap { part -> Int? in
            let field=part.trimmingCharacters(in:.whitespaces)
            return field.hasPrefix("wait=") ? Int(field.dropFirst(5)) : nil
        }.first ?? 0
        guard requested > 0,request.headers["if-none-match"] != nil,
              (dashboard ? dashboardWaiters : inventoryWaiters) < 8 else { return try await read() }
        let epoch=generation,observation=inventoryChanges.observe(),until=ProcessInfo.processInfo.systemUptime+Double(min(dashboard ? 15:6,requested))
        if dashboard { dashboardWaiters+=1;beginInventoryWatches() } else { inventoryWaiters+=1 }
        defer { if dashboard { dashboardWaiters-=1;endInventoryWatches() } else { inventoryWaiters-=1 } }
        await observation.waitForChange(timeout:0)
        var response=try await read(),lastRead=ProcessInfo.processInfo.systemUptime
        while response.status == 304 {
            try Task.checkCancellation()
            guard running,generation == epoch else { throw RemoteHTTPError(503,"웹 연결이 다시 시작됐습니다.") }
            let remaining=until-ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { break }
            await observation.waitForChange(timeout:min(1,remaining))
            try Task.checkCancellation()
            guard running,generation == epoch else { throw RemoteHTTPError(503,"웹 연결이 다시 시작됐습니다.") }
            let coalesce=0.08-(ProcessInfo.processInfo.systemUptime-lastRead)
            if coalesce > 0 { try await Task.sleep(for:.seconds(coalesce)) }
            response=try await read();lastRead=ProcessInfo.processInfo.systemUptime
            if dashboard { beginInventoryWatches() }
        }
        response.waitApplied=true;return response
    }
    public func start(port preferredPort: UInt16 = 8765, allowPortFallback: Bool = false) throws {
        guard !running else { return }
        cachedDashboardValidator = nil
        cancelDashboardEncoding()
        nextWebPeerRefresh = .distantPast
        let port = preferredPort
        let parameters = listenerParameters(port:port)
        lanInterfaces = loopbackOnly ? [] : RemoteLAN.interfaces(refresh: true)
        cachedDirectAddresses = nil
        // Constrain the address here; NWListener remains the single source of
        // the selected port, including persisted ports and busy-port recovery.
        let listener = try NWListener(using: parameters, on:NWEndpoint.Port(rawValue:port)!)
        let epoch = UUID(); generation = epoch; running = true; self.listener = listener
        listenerPort = port; allowListenerPortFallback = allowPortFallback; listenerRetryDelay = 1
        publishedPortal = false
        configureListener(listener, port: port, epoch: epoch)
        status.enabled = true; status.detail = "웹 접속과 같은 네트워크의 Mac을 연결하고 있습니다."
        listener.start(queue: queue)
        startDiscovery(parameters: parameters, epoch: epoch)
    }

    private func listenerParameters(port:UInt16) -> NWParameters {
        let parameters = RemoteLAN.tcpParameters()
        listenerLoopbackHost=RemoteLoopback.host(requestedPort:port)
        if loopbackOnly {parameters.requiredLocalEndpoint = .hostPort(host:NWEndpoint.Host(listenerLoopbackHost),port:.any)}
        return parameters
    }

    private func configureListener(_ listener: NWListener, port: UInt16, epoch: UUID) {
        // Keep NWListener's lifetime accept budget unlimited. Concurrent requests are
        // bounded by connections.count below. Streams use only 12 of the 32
        // slots, leaving room for input, state, assets and normal API requests.
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            Task { @MainActor in
                guard let self, let listener, self.listener === listener, self.running, self.generation == epoch,
                      case .hostPort(let host, _) = connection.endpoint,
                      RemoteNetworkAddress.isLocalHost(String(describing: host)) else { connection.cancel(); return }
                if self.connections.count >= 32 {
                    guard self.pendingIdleAdmissions < 4 else { connection.cancel(); return }
                    self.pendingIdleAdmissions += 1
                    defer { self.pendingIdleAdmissions -= 1 }
                    for (id, candidate) in Array(self.connections) {
                        if self.connections.count < 32 { break }
                        if await candidate.retireIfIdle() { self.connections.removeValue(forKey:id); self.streamConnections.remove(id) }
                        guard self.listener === listener, self.running, self.generation == epoch else { connection.cancel(); return }
                    }
                }
                guard self.listener === listener, self.running, self.generation == epoch, self.connections.count < 32 else { connection.cancel(); return }
                let id = UUID()
                let deadlines: RemoteHTTPDeadlines
                if let existing = self.httpDeadlines { deadlines = existing }
                else { deadlines = RemoteHTTPDeadlines(queue:self.queue); self.httpDeadlines = deadlines }
                let client = RemoteHTTPConnection(connection, queue: self.queue, deadlines:deadlines, handler: { [weak self] request in
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
                    self.status.detail = self.loopbackOnly ? "이 Mac의 \(self.listenerLoopbackHost)에서만 접속할 수 있습니다." : "같은 네트워크의 휴대폰과 Mac에서 접속할 수 있습니다."
                    self.status.port = listener.port?.rawValue ?? port
                    self.status.loopbackURL=self.status.port.map {"http://\(self.listenerLoopbackHost):\($0)"}
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
                let listener = try NWListener(using:self.listenerParameters(port:self.listenerPort),on:NWEndpoint.Port(rawValue:self.listenerPort)!)
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
        let changed: @Sendable (NWPath,String) -> Void = { [weak self] path,source in
            let available = path.status == .satisfied,fingerprint = RemoteNetworkPathChanges.fingerprint(path)
            Task { @MainActor in
                guard let self, self.running, self.generation == epoch, self.status.ready, let port = self.port else { return }
                let restored = self.pathChanges.update(source:source,available:available,fingerprint:fingerprint)
                let interfaces = RemoteLAN.interfaces(refresh: true)
                if interfaces != self.lanInterfaces || restored {
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
                    self.nextWebPeerRefresh = .distantPast
                    self.nextHintRead = .distantPast; self.nextBlindProbe = .distantPast; self.directCursor = 0
                    self.directProbedAt.removeAll(); self.pendingHints.removeAll(); self.cachedDirectAddresses = nil
                    self.startDirectDiscovery(epoch: epoch)
                    self.publishService(port: port)
                    if restored,self.bonjourEnabled {self.startBrowser(parameters:RemoteLAN.tcpParameters(),epoch:epoch)}
                }
                self.status.port = port; self.updateNamedAddresses(); self.emitStatus()
            }
        }
        monitor.pathUpdateHandler = {changed($0,"default")}
        monitor.start(queue: queue)
        for kind in [NWInterface.InterfaceType.wifi,.wiredEthernet] {
            let scoped = NWPathMonitor(requiredInterfaceType:kind)
            scoped.pathUpdateHandler = {changed($0,String(describing:kind))}; scoped.start(queue:queue); interfaceMonitors.append(scoped)
        }
    }
    private func startBrowser(parameters: NWParameters, epoch: UUID) {
            browserRetry?.cancel();browserRetry = nil
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
                if self.stateReads.count > 0 || self.inventoryValidation.count > 0 {
                    let liveIDs = Set(self.peers.keys)
                    if self.stateReads.count > 0 { self.stateReads.prune(liveIDs: liveIDs) }
                    if self.inventoryValidation.count > 0 { self.inventoryValidation.prune(liveIDs: liveIDs) }
                }
                self.refreshWebPeers()
                await self.discoverDirectPeers(epoch: epoch)
                self.refreshWebPeers()
                self.checkLANUpdate()
                // Discovery already tracks its next useful work. Sleep until
                // that deadline instead of waking once a second to rediscover
                // that no probe is due; cap the idle delay for update/status
                // maintenance and drain passive hints in small batches.
                let delay: TimeInterval
                if !self.pendingHints.isEmpty { delay = 0.25 }
                else {
                    var deadline = min(self.nextHintRead,self.nextBlindProbe)
                    if self.webPeerTask == nil { deadline = min(deadline,self.nextWebPeerRefresh) }
                    // A probe can finish with an earlier retry/discovery
                    // deadline. Observe that completion before a long idle
                    // sleep, while retaining the quiet five-second cap at rest.
                    delay = min(self.webPeerTask == nil ? 5 : 0.25,max(0.25,deadline.timeIntervalSinceNow))
                }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }
    public func stop() {
        stopInventoryWatches(); inventoryChanges.notify()
        cancelLANUpdate()
        running = false; generation = UUID()
        pathChanges = RemoteNetworkPathChanges()
        cachedDashboardValidator = nil
        cancelDashboardEncoding()
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
        directProbedAt.removeAll(); nextDirectProbePrune = .distantPast; pendingHints.removeAll(); directCursor = 0
        namedAccess?.stop(); namedAccess = nil
        listener?.cancel(); listener = nil; browser?.cancel(); browser = nil
        pathMonitor?.cancel(); pathMonitor = nil
        interfaceMonitors.forEach {$0.cancel()}; interfaceMonitors.removeAll()
        let clients = Array(connections.values); connections.removeAll(); streamConnections.removeAll(); clients.forEach { $0.close() }
        if let deadlines = httpDeadlines {
            httpDeadlines = nil; queue.async { deadlines.stop() }
        }
        terminalFeeds.stop()
        peers = peers.filter { $0.value.manual }
        for id in Array(peers.keys) { peers[id]?.portal = false; peers[id]?.webVerifiedAt = nil }
        status = RemoteNetworkStatus(); emitStatus()
    }
    public func cancelLANUpdate() {
        updateReceiver.stop();pendingPublishedOffer=nil;publishedUpdates.stop()
        publishedUpdateMaintenance?.cancel();publishedUpdateMaintenance=nil
    }
    private func beginPublishedUpdate(_ offer:PublishedReleaseOffer) {
        pendingPublishedOffer=offer;checkLANUpdate()
        publishedUpdateMaintenance?.cancel()
        let epoch=generation
        // Explicit web updates must resume and recheck install guards even
        // when LAN discovery is disabled or waiting on another address.
        publishedUpdateMaintenance=Task { [weak self] in
            while !Task.isCancelled {
                do {try await Task.sleep(for:.seconds(5))} catch {return}
                guard let self,!Task.isCancelled,self.running,self.generation==epoch,self.pendingPublishedOffer != nil else {return}
                self.checkLANUpdate()
            }
        }
    }
    private func publishedVersionStatus()->PublishedUpdateStatus {
        var value=publishedUpdates.status
        value.host=webVersion;value.update=engine?.lanUpdate
        if let current=webVersion,let offer=publishedUpdates.record?.offer {
            value.canSync=offer.manifest.release>current && engine?.lanUpdate.enabled==true && (try? LANUpdateInstallation.currentApp()) != nil
            if offer.manifest.release<=current,value.phase=="ready" {value.detail=offer.manifest.release==current ? "호스트가 정식 최신 버전입니다." : "호스트가 정식 릴리스보다 높은 버전입니다. 현재 버전을 유지합니다."}
        } else if let latest=value.latestVersion,let current=webVersion,value.phase=="ready" {
            let order=latest.compare(current.version,options:.numeric)
            value.detail=order == .orderedDescending ? "새 버전의 자동 업데이트 파일을 준비 중입니다. 잠시 후 다시 확인해주세요." : order == .orderedAscending ? "호스트가 정식 릴리스보다 높은 버전입니다. 현재 버전을 유지합니다." : "호스트가 정식 최신 버전입니다."
        }
        return value
    }
    private func checkLANUpdate() {
        guard running, let webVersion else { return }
        if let offer=pendingPublishedOffer {
            if offer.manifest.release>webVersion {
                let epoch=generation
                updateReceiver.check(nodeID:offer.manifest.nodeID,release:offer.manifest.release,routeKey:offer.url.absoluteString,allowTunnelRestart:true) { [weak self] path in
                    guard let self,self.running,self.generation==epoch,self.pendingPublishedOffer==offer else {throw CancellationError()}
                    if path=="/api/update/manifest" {return try .json(offer.manifest)}
                    return try await self.publishedUpdates.read(path,offer:offer)
                }
                return
            }
            pendingPublishedOffer=nil
        }
        var selected: Peer?
        for peer in peers.values where verified(peer) {
            guard let release = peer.release, release.isCompatible, release > webVersion else { continue }
            if let previous = selected, let oldRelease = previous.release,
               oldRelease > release || (oldRelease == release && previous.id < peer.id) { continue }
            selected = peer
        }
        guard let peer = selected, let release = peer.release else { return }
        let epoch = generation
        updateReceiver.check(nodeID: peer.id, release: release, routeKey: peerEndpoints(peer).map { String(describing: $0) }.joined(separator: "|")) { [weak self] path in
            guard let self, self.running, self.generation == epoch, let current = self.peers[peer.id] else { throw CancellationError() }
            return try await self.exchange(current, path: path, timeout: path == "/api/update/manifest" ? 25 : 15)
        }
    }
    private func emitStatus() {
        inventoryChanges.notify()
        status.peerCount = peers.values.reduce(into: 0) { if $1.available { $0 += 1 } }
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
    /// Peer priority rarely changes between dashboard polls. Cache the expensive
    /// locale-aware ordering and rebuild it only when visible peer attributes do.
    /// Check the cached projection in one allocation-free pass: dashboard keys
    /// are requested before and after the async read as well as while building it.
    private func refreshDashboardPeerOrderCache() {
        let unchanged = peers.count == dashboardPeerKeysByID.count && peers.values.allSatisfy { peer in
            dashboardPeerKeysByID[peer.id] == DashboardPeerOrderKey(id:peer.id,name:peer.name,available:peer.available,verified:verified(peer),
                release:peer.release,directAddress:peer.directAddress,webURLs:peer.webURLs,webPort:peer.webPort)
        }
        if !unchanged {
            dashboardPeerOrderKeys = peers.values.map {
                DashboardPeerOrderKey(id:$0.id,name:$0.name,available:$0.available,verified:verified($0),
                    release:$0.release,directAddress:$0.directAddress,webURLs:$0.webURLs,webPort:$0.webPort)
            }.sorted { $0.id < $1.id }
            dashboardPeerKeysByID = Dictionary(uniqueKeysWithValues: dashboardPeerOrderKeys.map { ($0.id, $0) })
            dashboardPeerOrder = peers.values.sorted {
                if verified($0) != verified($1) { return verified($0) }
                if $0.available != $1.available { return $0.available }
                let comparison = $0.name.localizedStandardCompare($1.name)
                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
            }.map(\.id)
        }
    }
    private func orderedDashboardPeers() -> [Peer] {
        refreshDashboardPeerOrderCache()
        return dashboardPeerOrder.compactMap { peers[$0] }
    }
    private func orderedDashboardNodes(_ nodes: [RemoteNodeView]) -> [RemoteNodeView] {
        let keys = nodes.map { DashboardNodeOrderKey(id:$0.id,name:$0.name) }
        if keys != dashboardNodeOrderKeys {
            dashboardNodeOrder = nodes.indices.sorted { left, right in
                let comparison = nodes[left].name.localizedStandardCompare(nodes[right].name)
                return comparison == .orderedSame ? nodes[left].id < nodes[right].id : comparison == .orderedAscending
            }
            dashboardNodeOrderKeys = keys
        }
        return dashboardNodeOrder.map { nodes[$0] }
    }
    private func dashboardResponseKey(initial: Bool, selectedNode: String?, client: String?, localAddressReady: Bool) -> DashboardResponseKey? {
        guard let engine else { return nil }
        refreshDashboardPeerOrderCache()
        let gateway = preferredGateway(client:client)
        return DashboardResponseKey(initial:initial,selectedNode:selectedNode,client:client,
            engineRevision:engine.remoteDashboardRevision,stateReadsRevision:stateReads.revision,
            peers:dashboardPeerOrderKeys,discovery:discoveryError,webVersion:webVersion,
            urls:port.map { Self.addresses(port:$0,interfaces:lanInterfaces) } ?? [],webPort:port,
            questionForms:engine.webQuestions.pending(),screenShares:engine.testScreens.active,
            update:engine.lanUpdate,localAddressReady:localAddressReady,
            preferredGateway:gateway.map { DashboardGatewayKey(id:$0.id,name:$0.name,url:$0.url,release:$0.release) })
    }
    private func localInventoryResponseKey(localAddressReady: Bool) -> LocalInventoryResponseKey? {
        guard let engine else { return nil }
        return LocalInventoryResponseKey(engineRevision:engine.remoteDashboardRevision,webVersion:webVersion,
            urls:port.map { Self.addresses(port:$0,interfaces:lanInterfaces) } ?? [],webPort:port,
            questionForms:engine.webQuestions.pending(),screenShares:engine.testScreens.active,
            update:engine.lanUpdate,localAddressReady:localAddressReady)
    }
    private func cancelDashboardEncoding() {
        for work in dashboardEncodingWork.values {
            work.cancellation.cancel(); work.preparationTask?.cancel()
            work.promise.finish(.failure(CancellationError()))
        }
        dashboardEncodingWork.removeAll(); joinableDashboardEncoding = nil
    }
    private func releaseDashboardEncoding(_ work: DashboardEncodingWork, waiter: UUID) {
        guard work.waiters.removeValue(forKey: waiter) != nil else { return }
        work.promise.release(waiter)
        guard !work.hasInterestedWaiter else { return }
        work.cancellation.cancel(); work.preparationTask?.cancel()
        work.promise.finish(.failure(CancellationError()))
        dashboardEncodingWork.removeValue(forKey: work.id)
        if joinableDashboardEncoding == work.id { joinableDashboardEncoding = nil }
    }
    private func reserveDashboardEncoding(_ work: DashboardEncodingWork) -> DashboardEncodingLease? {
        let lease = DashboardEncodingLease()
        guard work.promise.reserve(lease.id, cancellation: lease.cancellation) else { return nil }
        work.waiters[lease.id] = lease.cancellation
        return lease
    }
    private func makeDashboardEncoding(_ value: RemoteDashboard, key: DashboardResponseKey?) -> (DashboardEncodingWork, DashboardEncodingLease) {
        let work = DashboardEncodingWork(id: UUID(), key: key, epoch: generation)
        // Reserve before enqueue: a fast worker can complete before the HTTP
        // continuation is installed, but cannot mistake its owner for no owner.
        let lease = DashboardEncodingLease()
        work.promise.reserve(lease.id, cancellation: lease.cancellation)
        work.waiters[lease.id] = lease.cancellation
        dashboardEncodingWork[work.id] = work
        if key != nil { joinableDashboardEncoding = work.id }
        let snapshot = RemoteDashboardEncodingSnapshot(value: value)
        if let preparation = dashboardEncodingPreparation {
            work.preparationTask = Task(priority: .userInitiated) { @MainActor [weak self] in
                do {
                    try Task.checkCancellation(); try await preparation(); try Task.checkCancellation()
                    guard let self, self.generation == work.epoch else { throw RemoteHTTPError(503, "웹 연결이 다시 시작됐습니다. 현재 목록을 다시 확인해주세요.") }
                    guard work.hasInterestedWaiter else { throw CancellationError() }
                    RemoteDashboardResponseEncoder.shared.enqueue(snapshot, cancellation: work.cancellation, promise: work.promise)
                } catch { work.promise.finish(.failure(error)) }
            }
        } else {
            RemoteDashboardResponseEncoder.shared.enqueue(snapshot, cancellation: work.cancellation, promise: work.promise)
        }
        return (work, lease)
    }
    private func dashboardEncodingResponse(_ work: DashboardEncodingWork, lease: DashboardEncodingLease,
                                           ifNoneMatch: String?, observedAt: Date) async throws -> RemoteHTTPResponse {
        defer { releaseDashboardEncoding(work, waiter: lease.id) }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let content: RemoteDashboardEncodedContent
            do {
                content = try await withCheckedThrowingContinuation { continuation in
                    work.promise.subscribe(lease.id, cancellation: lease.cancellation, continuation: continuation)
                }
            }
            catch {
                guard generation == work.epoch else { throw RemoteHTTPError(503, "웹 연결이 다시 시작됐습니다. 현재 목록을 다시 확인해주세요.") }
                throw error
            }
            guard generation == work.epoch else { throw RemoteHTTPError(503, "웹 연결이 다시 시작됐습니다. 현재 목록을 다시 확인해주세요.") }
            try Task.checkCancellation(); try lease.cancellation.check()
            if !work.validatorChecked, let key = work.key {
                let current = dashboardResponseKey(initial: key.initial, selectedNode: key.selectedNode, client: key.client, localAddressReady: key.localAddressReady)
                try lease.cancellation.whileActive {
                    work.validatorChecked = true
                    if current == key { cachedDashboardValidator = CachedDashboardValidator(key: key, entityTag: content.entityTag) }
                }
            }
            return try RemoteDashboardObservationEncoder.response(content, ifNoneMatch:ifNoneMatch, observedAt:observedAt)
        } onCancel: { [weak self] in
            // The synchronous flag also closes cancellation/cache-publication
            // races before this actor gets to release the interested lease.
            lease.cancellation.cancel(); work.promise.cancel(lease.id)
            Task { @MainActor in self?.releaseDashboardEncoding(work, waiter: lease.id) }
        }
    }
    private func localInventoryNotModified(_ validator: String?, cached: CachedLocalInventoryValidator,
                                           key: LocalInventoryResponseKey, acceptsGzip: Bool) -> RemoteHTTPResponse? {
        guard cached.key == key, cached.acceptsGzip == acceptsGzip,
              validator?.split(separator:",").contains(where: {
                  let value = $0.trimmingCharacters(in:.whitespaces)
                  return value == "*" || value == cached.entityTag || value == "W/" + cached.entityTag
              }) == true else { return nil }
        var response = RemoteHTTPResponse(status:304,body:Data())
        response.entityTag = cached.entityTag; response.observedAt = Date()
        return response
    }
    /// A conditional response may skip reconstruction while every usable
    /// inventory remains inside its TTL. A known unavailable
    /// background peer with no read has a deterministic offline view; discovery
    /// owns its health probes, while selecting it still requests a real read.
    private func dashboardPeerStatesFresh(selectedNode: String?) -> Bool {
        orderedDashboardPeers().allSatisfy { peer in
            let current = peers[peer.id] ?? peer
            if !current.available, peer.id != selectedNode, !stateReads.contains(peer.id) { return true }
            return stateReads.value(for:peer.id,endpoint:connectionEndpoint(current)) != nil
        }
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
        return RemoteLAN.preferredEndpoint(fallback, addresses: peer.webURLs, port: port, interfaces: lanInterfaces)
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
        let primary = connectionEndpoint(peer), interfaces = lanInterfaces
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
    private func refreshWebPeers(force: Bool = false) {
        let now = Date()
        guard webPeerTask == nil, force || now >= nextWebPeerRefresh else { return }
        let epoch = generation, token = UUID()
        let remembered = Dictionary(knownPeers.map { ($0.id,$0.lastSeen) },uniquingKeysWith:max)
        func recent(_ peer: Peer) -> Date {
            max(peer.directlySeen ?? .distantPast,peer.webVerifiedAt ?? .distantPast,remembered[peer.id] ?? .distantPast)
        }
        let candidates = Array(peers.values.filter { $0.nextProbe <= now }.sorted {
            if $0.failures != $1.failures { return $0.failures < $1.failures }
            if recent($0) != recent($1) { return recent($0) > recent($1) }
            if $0.manual != $1.manual { return $0.manual }
            if $0.nextProbe != $1.nextProbe { return $0.nextProbe < $1.nextProbe }
            return $0.id < $1.id
        }.prefix(100))
        guard !candidates.isEmpty else {
            nextWebPeerRefresh = peers.values.map(\.nextProbe).filter { $0 > now }.min() ?? now.addingTimeInterval(15)
            return
        }
        webPeerToken = token
        webPeerTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.webPeerToken == token {
                    self.webPeerTask = nil
                    let finishedAt = Date()
                    self.nextWebPeerRefresh = self.peers.values.contains(where: { $0.nextProbe <= finishedAt })
                        ? .distantPast
                        : (self.peers.values.map(\.nextProbe).filter { $0 > finishedAt }.min() ?? finishedAt.addingTimeInterval(15))
                }
            }
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
                var next = min(4,candidates.count)
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
                            if failures == 2 {
                                // DHCP can give an old saved address to a new
                                // machine. Re-identify it through discovery;
                                // original reads remain pinned to the old ID.
                                self.nextHintRead = .distantPast; self.nextBlindProbe = .distantPast
                            }
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
        guard let webVersion else { return nil }
        var selected: (release: RemoteWebVersion, id: String, gateway: RemoteWebGateway)?
        for peer in peers.values where verified(peer) {
            guard let release = peer.release, release.isCompatible, release > webVersion,
                  let candidate = gateway(peer, client:client) else { continue }
            if let selected, selected.release > release || (selected.release == release && selected.id < peer.id) { continue }
            selected = (release,peer.id,candidate)
        }
        return selected?.gateway
    }
    private func updateNamedAddresses() {
        guard running, status.ready, let port = status.port, !updatingNamedAccess else { return }
        if loopbackOnly {status.urls = ["http://\(listenerLoopbackHost):\(port)"];return}
        guard bonjourEnabled else { status.urls = Self.addresses(port: port, interfaces: lanInterfaces); return }
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
        status.urls = (namedAccess?.urls(port: port, anotherPortal: anotherPortal) ?? []) + Self.addresses(port: port, interfaces: lanInterfaces)
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
                && (advertisedURLs.isEmpty || previous?.webURLs == advertisedURLs)
            if !unchanged { stateReads.remove(id); inventoryValidation.remove(id) }
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
        refreshWebPeers(force: true)
    }
    private func discoverDirectPeers(epoch: UUID) async {
        if Date() >= nextHintRead {
            nextHintRead = Date().addingTimeInterval(15)
            let read = discoveryHints, hints = await Task.detached(priority: .utility) { read() }.value
            guard running, generation == epoch, !Task.isCancelled else { return }
            let known = knownDiscoveryAddresses()
            pendingHints = Array(hints.prefix(64)).filter { !known.contains($0) && directProbedAt[$0].map { Date().timeIntervalSince($0) < 60 } != true }
        }
        var addresses: [String] = []
        if !pendingHints.isEmpty { addresses = Array(pendingHints.prefix(8)); pendingHints.removeFirst(addresses.count) }
        else if Date() >= nextBlindProbe {
            // Preparing hundreds of subnet candidates also reads interface
            // metadata. Do it only when a blind probe is actually due, after
            // passive hints, rather than on every 250-ms maintenance tick.
            var seen = Set<String>()
            let candidates: [DirectDiscoveryAddress]
            if cacheDiscoveryAddresses, let cachedDirectAddresses {
                candidates = cachedDirectAddresses
            } else {
                let discovered = Array(discoveryAddresses().prefix(512)).filter { seen.insert($0).inserted }.map { address in
                    DirectDiscoveryAddress(address: address, lane: RemoteLAN.discoveryLane(address, interfaces: lanInterfaces))
                }
                candidates = discovered
                // The production provider derives this bounded list from the
                // active physical LAN subnets. Those routes change through the
                // path monitor, so don't rebuild/sort the same /24 candidates
                // or repeat their route/lane mapping on every blind-scan tick.
                // Injected providers remain live for deterministic tests and
                // custom discovery sources.
                if cacheDiscoveryAddresses { cachedDirectAddresses = discovered }
            }
            if candidates.isEmpty {
                // No usable interface/subnet candidates: Bonjour and neighbor
                // hints remain active, so retry the blind scan at a bounded
                // cadence instead of rebuilding an empty list every tick.
                nextBlindProbe = Date().addingTimeInterval(min(15, max(1, directDiscoveryInterval)))
            } else {
                let known = knownDiscoveryAddresses()
                let lanes = Set(candidates.map(\.lane))
                // Finding one Mac does not finish discovery on that LAN. Sweep
                // every candidate at the same bounded cadence; its own probe
                // timestamp supplies the idle interval after a complete sweep.
                nextBlindProbe = Date().addingTimeInterval(0.5)
                var selected = Set<String>()
                for _ in 0..<8 {
                    var selectedLanes = Set<String>(), added = false
                    for _ in 0..<candidates.count {
                        let candidate = candidates[directCursor % candidates.count]; directCursor = (directCursor + 1) % candidates.count
                        let address = candidate.address, lane = candidate.lane
                        if !known.contains(address), !selected.contains(address), !selectedLanes.contains(lane),
                           directProbedAt[address].map({ Date().timeIntervalSince($0) >= max(10, directDiscoveryInterval) }) ?? true {
                            addresses.append(address); selected.insert(address); selectedLanes.insert(lane); added = true
                            if addresses.count == 8 || selectedLanes.count == lanes.count { break }
                        }
                    }
                    if !added || addresses.count == 8 { break }
                }
                if addresses.isEmpty {
                    // The sweep found no address eligible for another probe.
                    // Sleep until the earliest per-address interval expires,
                    // rather than rebuilding and rescanning the same subnet
                    // every 500 ms.
                    let interval = max(10, directDiscoveryInterval)
                    let nextEligible = candidates.compactMap { candidate -> Date? in
                        guard !known.contains(candidate.address), let last = directProbedAt[candidate.address] else { return nil }
                        return last.addingTimeInterval(interval)
                    }.min()
                    nextBlindProbe = nextEligible ?? Date().addingTimeInterval(min(15, max(1, directDiscoveryInterval)))
                }
            }
        }
        for address in addresses { directProbedAt[address] = Date() }
        let pruneAt = Date()
        if !directProbedAt.isEmpty, pruneAt >= nextDirectProbePrune {
            directProbedAt = directProbedAt.filter { pruneAt.timeIntervalSince($0.value) < 300 }
            nextDirectProbePrune = pruneAt.addingTimeInterval(30)
        }
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
                nextWebPeerRefresh = .distantPast
                updateNamedAddresses(); emitStatus()
            }
        }
    }
    private func knownDiscoveryAddresses() -> Set<String> {
        // A repeatedly failed identity is no longer proof of who owns its IP.
        // A healthy peer at that same address still excludes redundant probes.
        Set(peers.values.filter { $0.failures < 2 }.flatMap { [$0.directAddress].compactMap { $0 } + $0.webURLs })
    }
    private func localState(localAddressReady: Bool? = nil) throws -> RemoteNodeState {
        guard let engine else { throw RemoteHTTPError(503, "앱이 종료되었습니다.") }
        return RemoteNodeState(id: nodeID, name: name, snapshot: engine.snapshot, sessions: engine.remoteSessionViews(),
            release: webVersion, webURLs: port.map { Self.addresses(port: $0, interfaces: lanInterfaces) }, webPort: port,
            questionForms: engine.webQuestions.pending(), screenShares: engine.testScreens.active, update: engine.lanUpdate,
            localAddressReady:localAddressReady ?? (LocalDashboardAddress.status() == .ready),terminalWireVersion:RemoteTerminalWire.version,networkWaitVersion:1)
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
    private func peerStateTask(_ peer: Peer, foreground: Bool = false, watch: Bool = false) -> Task<RemoteNodeView, Never> {
        let endpoint = connectionEndpoint(peer)
        // A selected bookmark may replace a queued background/negative read.
        // Existing fresh success and simultaneous selected readers still share.
        if foreground, foregroundStateReads[peer.id] == nil, stateReads.value(for:peer.id,endpoint:endpoint)?.online != true {
            stateReads.remove(peer.id)
        }
        let retained = stateReads.value(for:peer.id,endpoint:endpoint)
        let wait = watch && retained?.online == true && retained?.state?.networkWaitVersion == 1 ? 6 : 0
        if let task = stateReads.task(for: peer.id, endpoint: endpoint), wait == 0 || inventoryWatchReads[peer.id] != nil { return task }
        let epoch = generation, token = UUID()
        foregroundStateReads[peer.id] = foreground ? token : nil
        let task = Task { @MainActor [weak self] () -> RemoteNodeView in
            guard let self else { return RemoteNodeView(id: peer.id, name: peer.name, local: false, online: false, error: "웹 연결이 종료되었습니다.", release: peer.release) }
            defer {
                if self.foregroundStateReads[peer.id] == token { self.foregroundStateReads.removeValue(forKey:peer.id) }
                if self.inventoryWatchReads[peer.id] == token { self.inventoryWatchReads.removeValue(forKey:peer.id) }
            }
            let result: RemoteNodeView
            do {
                try Task.checkCancellation()
                guard self.stateReads.isCurrent(id:peer.id,token:token) else { throw CancellationError() }
                let compact = peer.release.map { $0 >= RemoteWebVersion(version:"0.2.61",build:76,api:1) } == true
                let tag = compact ? self.inventoryValidation.requestTag(for: peer.id, endpoint: endpoint) : nil
                let response: RemoteHTTPResponse
                if wait > 0, let tag {
                    // One bounded watch per peer; keep ordinary GET traffic slots
                    // available. A healthy held response must not trigger hedges.
                    do {
                        let watched = try await self.readConnections.read(endpoint:endpoint,path:"/api/inventory",expectedNodeID:peer.id,timeout:7,entityTag:tag,retryReads:false,wait:wait)
                        if [502,503,504].contains(watched.status) { throw RemoteHTTPError(watched.status,"Mac의 상태 대기 연결을 다시 확인합니다.") }
                        response = watched
                        self.inventoryWatchDelay[peer.id] = watched.waitApplied ? 0.08 : 2.5
                    } catch {
                        // A closed/stalled long poll does not prove the Mac is
                        // offline. Confirm with one ordinary identity-pinned GET,
                        // including its existing LAN alternate, before publishing
                        // failure. Never retain a stale success or retry a denied,
                        // malformed, wrong-node or cancelled response.
                        guard RemoteReadRecovery.isTransient(error) else { throw error }
                        try Task.checkCancellation()
                        guard self.running,self.generation == epoch,self.stateReads.isCurrent(id:peer.id,token:token) else { throw CancellationError() }
                        self.inventoryWatchDelay[peer.id] = 2.5
                        response = try await RemoteDashboardTraffic.shared.read(foreground:foreground) { @MainActor in
                            try await self.exchange(peer,path:"/api/inventory",timeout:4,entityTag:tag,allowUnavailableRead:true)
                        }
                    }
                } else {
                    response = try await RemoteDashboardTraffic.shared.read(foreground:foreground) { @MainActor in
                        try await self.exchange(peer,path:compact ? "/api/inventory" : "/api/state",timeout:4,entityTag:tag,allowUnavailableRead:foreground)
                    }
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
        if wait > 0 { inventoryWatchReads[peer.id] = token }
        stateReads.insert(task, id: peer.id, token: token, endpoint: endpoint,preservingValue:wait > 0)
        return task
    }
    private func unavailablePeerState(_ peer: Peer) -> RemoteNodeView {
        RemoteNodeView(id:peer.id,name:peer.name,local:false,online:false,
            error:"이 Mac이 네트워크에서 연결 해제되었습니다.",release:peer.release)
    }
    public func dashboard(initial: Bool = false, selectedNode: String? = nil, client: String? = nil,
                          localAddressReady: Bool? = nil) async throws -> RemoteDashboard {
        let own = try localState(localAddressReady:localAddressReady).inventory
        let candidates = orderedDashboardPeers()
        var completed: [String:(NWEndpoint,RemoteNodeView)] = [:]
        func value(_ peer: Peer) -> RemoteNodeView? {
            let current = peers[peer.id] ?? peer
            // With no cached or in-flight read, an unavailable background
            // peer's view cannot depend on a parsed/resolved network route.
            if !current.available, peer.id != selectedNode, completed[peer.id] == nil,
               !stateReads.contains(peer.id) { return unavailablePeerState(current) }
            let endpoint = connectionEndpoint(current)
            if let result = stateReads.value(for:peer.id,endpoint:endpoint) { completed[peer.id] = (endpoint,result) }
            if let result = completed[peer.id].flatMap({ $0.0 == endpoint ? $0.1 : nil }) { return result }
            // exchange already rejects this background read before any I/O.
            // Avoid reserving a task, traffic slot and waiter just to reject it.
            // Preserve in-flight foreground work and do not memoize this view:
            // discovery can make the peer available while other reads suspend.
            guard !current.available, peer.id != selectedNode,
                  stateReads.task(for:peer.id,endpoint:endpoint) == nil else { return nil }
            stateReads.remove(peer.id)
            return unavailablePeerState(current)
        }
        func waitForReads(_ peers: [Peer], progressive: Bool = false) async throws {
            for peer in peers where peer.id == selectedNode || value(peer) == nil {
                _ = peerStateTask(peer,foreground:peer.id == selectedNode)
            }
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
                updatedAt:Date(),discovery:discoveryError,gatewayRelease:webVersion,preferredGateway:preferredGateway(client:client),partial:true,terminalWireVersion:RemoteTerminalWire.version,networkWaitVersion:1)
        }
        let requested = Array(candidates.prefix(100))
        try await waitForReads(requested,progressive:true)
        let other = orderedDashboardNodes(requested.map { peer in
            value(peer) ?? RemoteNodeView(id:peer.id,name:peer.name,local:false,online:false,release:peer.release,loading:true)
        })
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
            gatewayRelease: webVersion, preferredGateway: preferredGateway(client:client),partial:other.contains(where:{$0.loading == true}) ? true : nil,terminalWireVersion:RemoteTerminalWire.version,networkWaitVersion:1)
    }
    private func inventoryResponse(_ request:RemoteHTTPRequest) async throws -> RemoteHTTPResponse {
        let acceptsGzip = RemoteGzipEncoder.accepts(request.headers["accept-encoding"])
        let localAddressReady = LocalDashboardAddress.status() == .ready
        let before = localInventoryResponseKey(localAddressReady:localAddressReady)
        if let before, let cached = cachedLocalInventoryValidator,
           let unchanged = localInventoryNotModified(request.headers["if-none-match"],cached:cached,
               key:before,acceptsGzip:acceptsGzip) { return unchanged }
        let inventory = try localState(localAddressReady:localAddressReady).inventory
        let response = try await inventory.response(ifNoneMatch:request.headers["if-none-match"],acceptsGzip:acceptsGzip)
        let afterReady = LocalDashboardAddress.status() == .ready
        let after = localInventoryResponseKey(localAddressReady:afterReady)
        if before == after, let after, let entityTag = response.entityTag {
            cachedLocalInventoryValidator = CachedLocalInventoryValidator(key:after,entityTag:entityTag,acceptsGzip:acceptsGzip)
        }
        return response
    }
    private func dashboardResponse(_ request:RemoteHTTPRequest) async throws -> RemoteHTTPResponse {
        let initial = request.parameter("initial") == "1", selectedNode = request.parameter("node")
        let client = request.clientAddress, validator = request.headers["if-none-match"]
        let localAddressReady = LocalDashboardAddress.status() == .ready
        let before = dashboardResponseKey(initial:initial,selectedNode:selectedNode,client:client,localAddressReady:localAddressReady)
        // A matching key proves the complete dashboard inputs are
        // unchanged. Return before rebuilding the local inventory,
        // sorting peers, or waiting for their bounded reads. The
        // key is checked again after a fresh build on cache misses.
        if dashboardPeerStatesFresh(selectedNode:selectedNode), let before, let cached = cachedDashboardValidator,
           cached.key == before, RemoteDashboard.matches(validator,entityTag:cached.entityTag) {
            var response = RemoteHTTPResponse(status:304,body:Data())
            response.entityTag = cached.entityTag; response.observedAt = Date()
            return response
        }
        // Share only work still owned by interested requests, and
        // only after this request's fresh full key/peer check.
        if let id = joinableDashboardEncoding, let work = dashboardEncodingWork[id], let before,
           work.epoch == generation, work.key == before, work.hasInterestedWaiter,
           dashboardPeerStatesFresh(selectedNode:selectedNode), let lease = reserveDashboardEncoding(work) {
            return try await dashboardEncodingResponse(work, lease: lease, ifNoneMatch:validator, observedAt:Date())
        }
        let current = try await dashboard(initial:initial,selectedNode:selectedNode,client:client,localAddressReady:localAddressReady)
        let afterReady = LocalDashboardAddress.status() == .ready
        let after = dashboardResponseKey(initial:initial,selectedNode:selectedNode,client:client,localAddressReady:afterReady)
        if before == after, let after, let cached = cachedDashboardValidator,
           cached.key == after, RemoteDashboard.matches(validator,entityTag:cached.entityTag) {
            var response = RemoteHTTPResponse(status:304,body:Data())
            response.entityTag = cached.entityTag; response.observedAt = Date()
            return response
        }
        let (work, lease) = makeDashboardEncoding(current, key:before == after ? after : nil)
        return try await dashboardEncodingResponse(work, lease: lease, ifNoneMatch:validator, observedAt:current.updatedAt)
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
                case "/api/version":
                    guard request.parameter("node")==nil || request.parameter("node")==nodeID else {throw RemoteHTTPError(400,"접속 중인 호스트에서 확인해주세요.")}
                    return try .json(publishedVersionStatus())
                case "/", "/index.html":
                    if let expected = request.parameter("webNode"), expected != nodeID { throw RemoteHTTPError(409, "이 주소의 Mac이 바뀌었습니다. 원래 즐겨찾기나 Mac의 접속 링크로 다시 열어주세요.") }
                    // Every client owns its entry document. A newer/offline Mac
                    // cannot delay or redirect a phone's first byte or local alias.
                    return try asset("index.html", type: "text/html; charset=utf-8")
                case "/app.css": return try asset("app.css", type: "text/css; charset=utf-8")
                case "/app.js": return try asset("app.js", type: "text/javascript; charset=utf-8")
                case "/agent-accounts.js": return try asset("agent-accounts.js",type:"text/javascript; charset=utf-8")
                case "/vendor/account-crypto.js": return try asset("vendor/account-crypto.js",type:"text/javascript; charset=utf-8")
                case "/api/agent-account/key":
                    if let forwarded=try await forward(request) {return forwarded}
                    guard let engine else {throw RemoteHTTPError(503,"Mac에 다시 연결해주세요.")}
                    return try await .object(engine.agentAccounts.hello(node:nodeID,pin:engine.readAccountPIN()))
                case "/terminal-wire.js": return try asset("terminal-wire.js", type: "text/javascript; charset=utf-8")
                case "/terminal-history.js": return try asset("terminal-history.js", type:"text/javascript; charset=utf-8")
                case "/pty.js": return try asset("pty.js", type: "text/javascript; charset=utf-8")
                case "/input-channel.js": return try asset("input-channel.js", type: "text/javascript; charset=utf-8")
                case "/screen-control.js": return try asset("screen-control.js",type:"text/javascript; charset=utf-8")
                case "/api/input/socket":
                    let handshake = try RemoteWebSocketParser.handshake(request)
                    var response = RemoteHTTPResponse(status:101,body:Data())
                    let epoch = generation
                    response.inputSocket = (handshake,RemoteInputProtocol(target:request.parameter("node"),handler:{ [weak self] input in
                        guard let self,!Task.isCancelled,self.generation == epoch else { return .error(RemoteHTTPError(503,"앱 연결이 종료됐습니다.")) }
                        // A socket owns its sequence and never retries. Avoid
                        // rewriting the HTTP receipt archive for every key.
                        if input.parameter("node") == nil || input.parameter("node") == self.nodeID {
                            do {
                                guard let engine = self.engine else { throw RemoteHTTPError(503,"앱이 종료되었습니다.") }
                                let object = try input.json()
                                if input.path == "/api/input/bind" { return try .object(object["mode"] as? String=="screen" ? engine.testScreens.bindControl(object):engine.validateInputChannel(object)) }
                                if input.path == "/api/screen/input" {return try .object(engine.testScreens.screenInput(object))}
                                if input.path == "/api/screen/control" {
                                    switch object["action"] as? String {
                                    case "heartbeat":return try .object(engine.testScreens.heartbeatControl(object))
                                    case "end":return try .object(engine.testScreens.endControl(object))
                                    default:throw RemoteInputPacket.invalid()
                                    }
                                }
                                if input.path == "/api/pty/input" { return try await .object(engine.ptyInput(object)) }
                                if input.path == "/api/input" { return try await .object(engine.remoteInput(object)) }
                                throw RemoteInputPacket.invalid()
                            } catch { return .error(error) }
                        }
                        return await self.handle(input)
                    }))
                    return response
                case "/vendor/xterm.js", "/vendor/xterm-fit.js": return try asset(String(request.path.dropFirst()), type: "text/javascript; charset=utf-8")
                case "/vendor/xterm.css": return try asset("vendor/xterm.css", type: "text/css; charset=utf-8")
                case "/favicon.svg": return try asset("favicon.svg", type: "image/svg+xml")
                case "/api/state":
                    if let forwarded = try await forward(request) { return forwarded }
                    return try .json(localState())
                case "/api/inventory":
                    return try await waitForInventory(request,dashboard:false) { try await self.inventoryResponse(request) }
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
                    var object: JSONObject = ["service": "autoapprove", "version": 1, "id": nodeID, "name": name,
                        "urls": port.map { Self.addresses(port: $0, interfaces: lanInterfaces) } ?? [], "port": Int(port ?? 0), "portal": namedAccess?.ownsPortal == true]
                    if let webVersion { object["release"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(webVersion)) }
                    return try .object(object)
                case "/api/network":
                    return try await waitForInventory(request,dashboard:true) { try await self.dashboardResponse(request) }
                case "/api/test-screen":
                    if let forwarded = try await forward(request) { return forwarded }
                    guard let id = request.parameter("share"), let engine else { throw RemoteHTTPError(400, "화면 공유를 지정해주세요.") }
                    return try await engine.testScreens.response(id,entityTag:request.headers["if-none-match"])
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
                case "/api/connection/quality":
                    if let forwarded = try await forward(request) {return forwarded}
                    guard let engine else {throw RemoteHTTPError(503,"앱이 종료되었습니다.")}
                    return try .json(engine.tunnelStatus.quality)
                case "/api/terminal":
                    if let forwarded = try await forward(request) { return forwarded }
                    guard let id = request.parameter("session"), let engine else { throw RemoteHTTPError(400, "세션을 지정해주세요.") }
                    let frame = try await RemoteTerminalReadRecovery.read {
                        try await engine.remoteTerminal(sessionID:id,renderWindow:request.parameter("view") == "screen",initial:request.parameter("initial") == "1")
                    }
                    return try RemoteTerminalPerformance.shared.measure(.responseEncoding) {
                        try .terminalJSON(RemoteTerminalUpdate(frame, knownRevision:request.parameter("revision")))
                    }
                case "/api/terminal/history":
                    if let forwarded=try await forward(request) {return forwarded}
                    guard let id=request.parameter("session"),let engine else {throw RemoteHTTPError(400,"세션을 지정해주세요.")}
                    let rawPage=request.parameter("page"),page=rawPage.flatMap(Int.init)
                    guard rawPage==nil || page.map({$0>=0})==true,
                          request.parameter("snapshot").map({UUID(uuidString:$0) != nil}) ?? true else {throw RemoteHTTPError(400,"기록 조회 구간을 확인해주세요.")}
                    return try await .json(engine.remoteTerminalHistory(sessionID:id,snapshot:request.parameter("snapshot"),page:page,refresh:request.parameter("refresh")=="1"))
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
                    let delta = request.parameter("delta") == "1", wireVersion = RemoteTerminalWire.negotiated(request.parameter("wire"))
                    let binary = wireVersion != nil
                    let base = delta ? terminalFeeds.base(key:key,revision:request.parameter("revision"),stream:request.parameter("stream"),current:frame) : nil
                    let output: RemoteTerminalBodyStream
                    do {
                        output = try RemoteTerminalBodyStream(initial:frame,emitInitial:false,delta:delta,copy:request.parameter("copy") == "1",
                            resume:base,compact:request.parameter("compact") == "1" && !renderWindow,paced:true,binary:binary,wireVersion:wireVersion ?? 2,
                            onCancel:{ subscription.cancel() }) { try await subscription.next() }
                    } catch { subscription.cancel(); throw error }
                    // The verified first event is ready. Send it with the headers,
                    // without another main-actor hop or a second small TCP write.
                    return .eventStream(output, nodeID: nodeID, initialData: output.initialEvent,binary:binary,wireVersion:wireVersion ?? 2)
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
                        let wireVersion = RemoteTerminalWire.negotiated(request.parameter("wire")), binary = wireVersion != nil
                        return .eventStream(try RemotePTYBodyStream(terminal: terminal, offset: offset, client: client,binary:binary,wireVersion:wireVersion ?? 2), nodeID: nodeID,binary:binary,wireVersion:wireVersion ?? 2)
                    }
                    let output = try RemotePTYBodyStream(terminal: terminal, offset: offset, client: client, emitInitial: false)
                    defer { output.cancel() }
                    return try await .json(output.readUpdate(timeout: 0.75))
                default: throw RemoteHTTPError(404, "페이지를 찾지 못했습니다.")
                }
            }
            let object = try request.json()
            switch request.path {
            case "/api/agent-account":
                if let forwarded=try await forward(request) {return forwarded}
                guard let engine else {throw RemoteHTTPError(503,"Mac에 다시 연결해주세요.")}
                return try await .object(engine.agentAccounts.encrypted(object,node:nodeID,pin:engine.readAccountPIN()))
            case "/api/screen/control":
                if let forwarded=try await forward(request) {return forwarded}
                guard let engine else {throw RemoteHTTPError(503,"앱이 종료되었습니다.")}
                switch object["action"] as? String {
                case "begin":return try .json(engine.testScreens.beginControl(object))
                case "heartbeat":return try .object(engine.testScreens.heartbeatControl(object))
                case "end":return try .object(engine.testScreens.endControl(object))
                default:throw RemoteScreenInput.invalid()
                }
            case "/api/screen/input":
                if let forwarded=try await forward(request) {return forwarded}
                guard let engine else {throw RemoteHTTPError(503,"앱이 종료되었습니다.")}
                return try .object(engine.testScreens.screenInput(object))
            case "/api/version/check", "/api/version/sync":
                guard request.parameter("node")==nil || request.parameter("node")==nodeID else {throw RemoteHTTPError(400,"외부 접속을 제공하는 호스트에서 확인해주세요.")}
                let epoch=generation
                await publishedUpdates.check()
                guard generation==epoch else {throw CancellationError()}
                if request.path=="/api/version/sync" {
                    guard let engine,engine.lanUpdate.enabled else {throw RemoteHTTPError(409,"Mac의 연결 설정에서 자동 업데이트를 켜주세요.")}
                    guard (try? LANUpdateInstallation.currentApp()) != nil else {throw RemoteHTTPError(409,"설치된 AutoApprove 앱에서 지원합니다. 먼저 설치 파일을 적용해주세요.")}
                    guard let raw=object["client"],let client=try? JSONDecoder().decode(RemoteWebVersion.self,from:JSONSerialization.data(withJSONObject:raw)),client.isCompatible,
                          let current=webVersion else {throw RemoteHTTPError(400,"웹 클라이언트 버전을 확인하지 못했습니다.")}
                    guard let offer=publishedUpdates.record?.offer,offer.manifest.release>=client else {
                        throw RemoteHTTPError(409,"웹 버전에 맞는 정식 업데이트 파일이 아직 없습니다. 잠시 후 다시 확인해주세요.")
                    }
                    if offer.manifest.release>current {beginPublishedUpdate(offer)}
                }
                return try .json(publishedVersionStatus())
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
                updateNamedAddresses(); emitStatus(); refreshWebPeers(force: true)
                return try .object(["id": state.id, "name": state.name])
            case "/api/input/bind":
                if let forwarded = try await forward(request) { return forwarded }
                guard let engine else { throw RemoteHTTPError(503,"앱이 종료되었습니다.") }
                return try .object(object["mode"] as? String=="screen" ? engine.testScreens.bindControl(object):engine.validateInputChannel(object))
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
        let response = try await exchange(peer,path:forwardedPath(request),method:request.method,body:request.body,
            entityTag:read && request.path=="/api/test-screen" ? request.headers["if-none-match"]:nil,allowUnavailableRead:read)
        // Only an exact fresh identity can restore a saved/offline read route.
        // Legacy peers without the header still use metadata discovery first.
        if !peer.available, response.nodeID != peer.id {
            throw RemoteHTTPError(502,"저장한 주소의 Mac을 확인하지 못했습니다. 목록을 새로고침해주세요.",diagnostics:["failureKind":"identity"])
        }
        if read, [200,304].contains(response.status), response.nodeID == peer.id { markPeerRead(peer) }
        succeeded = response.status < 400
        return response
    }
    private enum PeerStreamResult: Sendable { case stagger; case opened(Int,RemotePTYPeerBodyStream,TimeInterval,RemotePeerStreamOpening) }
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
        let path = forwardedPath(request), expectedID = peer.id, wireVersion = RemoteTerminalWire.negotiated(request.parameter("wire"))
        let allowsBinary = wireVersion != nil
        let open: @Sendable (Int) async throws -> PeerStreamResult = { index in
            try Task.checkCancellation()
            let started = ProcessInfo.processInfo.systemUptime
            let output = try RemotePTYPeerBodyStream(endpoint: endpoints[index], path: path, expectedNodeID: expectedID,
                timeout: max(0.05, deadline - started),allowsBinary:allowsBinary,maximumWireVersion:wireVersion ?? 2)
            do {
                let initial = try await output.openContent(); try Task.checkCancellation()
                return .opened(index,output,ProcessInfo.processInfo.systemUptime-started,initial)
            } catch { output.cancel(); throw error }
        }
        // Keep opening latency separate from finite bodies. Failed transports
        // wake the alternate immediately; healthy but busy peers avoid duplicates.
        let opened = try await withThrowingTaskGroup(of: PeerStreamResult.self) { group -> (Int,RemotePTYPeerBodyStream,TimeInterval,RemotePeerStreamOpening) in
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
        return .eventStream(opened.1, nodeID: nodeID, initialData: opened.3.data,binary:opened.3.binary,wireVersion:opened.3.wireVersion)
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
    static func addresses(port: UInt16, interfaces: [RemoteLANInterface]? = nil) -> [String] {
        (interfaces ?? RemoteLAN.interfaces()).map { "http://\($0.address):\(port)" }
    }
}
