import Foundation

/// Numeric connection health only. No keys, URLs, request IDs or terminal data.
public struct RemoteTunnelQuality: Codable, Equatable, Sendable {
    public var samples = 0
    public var medianMS: Double?, p95MS: Double?, lastMS: Double?
    public var checkedAt: Date?, succeeded: Bool?, edge: String?
    public var connectorMS: Double?, connectorProtocol: String?
    public var connectorLocations: [String] = []
    public var connections: Int?, lostPackets: UInt64?
    public var reconnects: UInt64 = 0, failedProbes: UInt64 = 0
    public var relayCompatibility: Bool?
    public init() {}
}

public final class RemoteTunnelQualityTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var value = RemoteTunnelQuality(), durations:[Double] = []
    public init() {}
    public func snapshot() -> RemoteTunnelQuality { lock.lock();defer {lock.unlock()};return value }
    public func recordProbe(milliseconds:Double?,ray:String?,at:Date = Date()) {
        lock.lock();defer {lock.unlock()}
        value.checkedAt = at
        guard let ms = milliseconds,ms.isFinite,(0...60000).contains(ms) else {
            value.succeeded = false;value.failedProbes = Self.increment(value.failedProbes);return
        }
        value.succeeded = true;value.lastMS = ms
        durations.append(ms);if durations.count > 64 {durations.removeFirst()}
        let sorted = durations.sorted();value.samples = sorted.count
        value.medianMS = sorted[max(0,Int(ceil(Double(sorted.count)*0.5))-1)]
        value.p95MS = sorted[max(0,Int(ceil(Double(sorted.count)*0.95))-1)]
        let edge = ray?.split(separator:"-").last.map(String.init)
        value.edge = edge.flatMap {$0.range(of:#"^[A-Z]{3}$"#,options:.regularExpression) != nil ? $0:nil}
    }
    public func reconnected() {
        lock.lock();defer {lock.unlock()};value.reconnects = Self.increment(value.reconnects)
        value.connectorMS = nil;value.connectorProtocol = nil;value.connectorLocations = []
        value.connections = nil;value.lostPackets = nil;value.relayCompatibility = nil
    }
    func relayFeatures(_ features:UInt8) {lock.lock();defer {lock.unlock()};value.relayCompatibility = features & 1 == 0;value.connectorProtocol = "WSS 443"}
    public func connectorPing(milliseconds:Double) {
        guard milliseconds.isFinite,(0...60000).contains(milliseconds) else {return}
        lock.lock();defer {lock.unlock()};value.connectorMS = milliseconds;value.connectorProtocol = "WSS 443"
    }
    public func registration(_ line:String) {
        guard line.contains("Registered tunnel connection") else {return}
        let transport = ["quic","http2"].first {line.contains("protocol="+$0)}
        let location = line.range(of:#"location=[a-z]{3}[0-9]{2}(?:\s|$)"#,options:.regularExpression).map {String(line[$0].dropFirst(9).prefix(3)).uppercased()}
        lock.lock();defer {lock.unlock()}
        if let transport {
            let next = transport == "quic" ? "QUIC":"HTTP/2"
            if value.connectorProtocol != next {value.connectorMS = nil;value.lostPackets = nil}
            value.connectorProtocol = next
        }
        if let location,!value.connectorLocations.contains(location) {value.connectorLocations = Array((value.connectorLocations+[location]).sorted().prefix(8))}
    }
    public func metrics(_ text:String) {
        guard text.utf8.count <= 262144 else {return}
        var rtts:[Double] = [],connections:Int?,lost:Double = 0,hasLost = false,hasLocations = false,locations = Set<String>()
        for line in text.split(separator:"\n") where !line.hasPrefix("#") {
            let fields = line.split(whereSeparator:{$0 == " " || $0 == "\t"})
            guard fields.count >= 2,let number = Double(fields[1]),number.isFinite,number >= 0 else {continue}
            let name = fields[0].split(separator:"{").first.map(String.init)
            if name == "quic_client_smoothed_rtt",number <= 60000,rtts.count < 16 {rtts.append(number)}
            if name == "cloudflared_tunnel_ha_connections",number <= 32 {connections = Int(number)}
            if name == "quic_client_lost_packets",number <= 1e15 {lost += number;hasLost = true}
            if name == "cloudflared_tunnel_server_locations" {
                hasLocations = true
                if number == 1,let range = fields[0].range(of:#"edge_location=\"[a-zA-Z]{3}(?:[0-9]{2})?\""#,options:.regularExpression),locations.count < 16 {
                    locations.insert(String(fields[0][range].dropFirst(15).prefix(3)).uppercased())
                }
            }
        }
        lock.lock();defer {lock.unlock()}
        if !rtts.isEmpty,value.connectorProtocol != "HTTP/2" {rtts.sort();value.connectorMS = rtts[(rtts.count-1)/2]} else {value.connectorMS = nil}
        value.connections = connections
        if hasLocations {value.connectorLocations = Array(locations.sorted().prefix(8))}
        if hasLost,lost <= Double(UInt64.max/2),value.connectorProtocol != "HTTP/2" {value.lostPackets = UInt64(lost)} else {value.lostPackets = nil}
    }
    private static func increment(_ number:UInt64) -> UInt64 {number == .max ? .max:number+1}
}

final class RemoteTunnelProbeClient: @unchecked Sendable {
    static let shared = RemoteTunnelProbeClient()
    private let session:URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral;config.httpShouldSetCookies = false;config.httpCookieStorage = nil;config.urlCache = nil
        config.timeoutIntervalForRequest = 3;config.timeoutIntervalForResource = 4
        session = URLSession(configuration:config,delegate:TunnelRedirectPolicy(),delegateQueue:nil)
    }
    deinit {session.invalidateAndCancel()}
    func probe(_ request:URLRequest,maximum:Int = 1024) async throws -> CloudflareHTTPReply {
        let (bytes,response) = try await session.bytes(for:request)
        var data = Data()
        for try await byte in bytes {guard data.count < maximum else {throw URLError(.dataLengthExceedsMaximum)};data.append(byte)}
        let reply = response as? HTTPURLResponse
        return CloudflareHTTPReply(data:data,status:reply?.statusCode ?? 0,headers:reply?.value(forHTTPHeaderField:"CF-Ray").map {["cf-ray":$0]} ?? [:])
    }
}

@MainActor final class RemoteTunnelMonitor {
    private let origin:String,nonce:String,tracker:RemoteTunnelQualityTracker
    private let probe:@Sendable(URLRequest) async throws -> CloudflareHTTPReply
    private let onUpdate:@MainActor(RemoteTunnelQuality)->Void
    private let client = RemoteTunnelProbeClient()
    private var task:Task<Void,Never>?,metricsPort:UInt16?
    private var sampling = false
    private var generation = UUID()
    init(origin:String,nonce:String,tracker:RemoteTunnelQualityTracker,probe:@escaping @Sendable(URLRequest) async throws -> CloudflareHTTPReply = {try await RemoteTunnelProbeClient.shared.probe($0)},onUpdate:@escaping @MainActor(RemoteTunnelQuality)->Void) {
        self.origin = origin;self.nonce = nonce;self.tracker = tracker;self.probe = probe;self.onUpdate = onUpdate
    }
    func start() {
        stop()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {return}
                await self.sample()
                do {try await Task.sleep(for:.seconds(30))} catch {return}
            }
        }
    }
    func stop() {generation = UUID();task?.cancel();task = nil}
    func setMetricsPort(_ port:UInt16?) {metricsPort = port}
    func sample() async {
        guard !sampling else {return};sampling = true;defer {sampling = false}
        let epoch = generation
        guard let url = URL(string:origin+"/auth/probe") else {return}
        var request = URLRequest(url:url);request.timeoutInterval = 3;request.cachePolicy = .reloadIgnoringLocalCacheData
        let began = ProcessInfo.processInfo.systemUptime
        do {
            let reply = try await probe(request)
            guard !Task.isCancelled,generation == epoch else {return}
            guard reply.status == 200,reply.data.count < 1024,let object = try JSONSerialization.jsonObject(with:reply.data) as? [String:String],object["probe"] == nonce else {throw URLError(.badServerResponse)}
            tracker.recordProbe(milliseconds:(ProcessInfo.processInfo.systemUptime-began)*1000,ray:reply.headers["cf-ray"])
        } catch {guard !Task.isCancelled,generation == epoch else {return};tracker.recordProbe(milliseconds:nil,ray:nil)}
        if let port = metricsPort {
            var metrics = URLRequest(url:URL(string:"http://127.0.0.1:\(port)/metrics")!);metrics.timeoutInterval = 1
            if let reply = try? await client.probe(metrics,maximum:262144),reply.status == 200,generation == epoch,!Task.isCancelled {
                tracker.metrics(String(decoding:reply.data,as:UTF8.self))
            }
        }
        guard !Task.isCancelled,generation == epoch else {return};onUpdate(tracker.snapshot())
    }
}
