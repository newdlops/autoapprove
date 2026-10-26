import Foundation

/// Eight bytes of framing; identity is bound once, never repeated per key.
/// Acknowledgements are cumulative. Neither endpoint replays uncertain input.
public struct RemoteInputPacket: Sendable {
    public enum Kind: UInt8, Sendable { case bind = 0, ready, pty, native, ack, failure, ping, pong }
    public static let maximumPayload = 16_001
    public static let windowMessages = 16
    public static let windowBytes = 64_000
    public static let nativeKeys = ["characters", "enter", "escape", "interrupt", "up", "down", "left", "right", "backspace", "delete", "home", "end", "tab"]
    public let kind: Kind
    public let sequence: UInt32
    public let payload: Data
    public init(kind: Kind, sequence: UInt32 = 0, payload: Data = Data()) {
        self.kind = kind; self.sequence = sequence; self.payload = payload
    }
    public func encoded() throws -> Data {
        guard payload.count <= Self.maximumPayload else { throw Self.invalid() }
        var result = Data([65, 73, 1, kind.rawValue])
        for shift in [24, 16, 8, 0] { result.append(UInt8(truncatingIfNeeded:sequence >> shift)) }
        result.append(payload); return result
    }
    public static func decode(_ data: Data) throws -> Self {
        guard (8...(maximumPayload+8)).contains(data.count) else { throw invalid() }
        let bytes = [UInt8](data.prefix(8))
        guard bytes[0...2] == [65, 73, 1], let kind = Kind(rawValue:bytes[3]) else { throw invalid() }
        let sequence = bytes[4...7].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return Self(kind:kind,sequence:sequence,payload:Data(data.dropFirst(8)))
    }
    static func invalid() -> RemoteHTTPError { RemoteHTTPError(400,"실시간 입력 형식이나 순서를 확인하지 못했습니다. 화면을 다시 연결해주세요.") }
}

struct RemoteInputBinding {
    let mode: String
    let values: JSONObject
    let sequenceBase: Int
    init(_ data: Data) throws {
        guard data.count <= 4096, let object = try JSONSerialization.jsonObject(with:data) as? JSONObject,
              let mode = object["mode"] as? String, ["pty","native"].contains(mode),
              let stream = object["streamID"] as? String, !stream.isEmpty, stream.utf8.count <= 512 else { throw RemoteInputPacket.invalid() }
        self.mode = mode
        if mode == "pty" {
            guard let id = object["ptyID"] as? String, UUID(uuidString:id) != nil,
                  let client = object["clientID"] as? String, UUID(uuidString:client) != nil,
                  let base = object["sequenceBase"] as? Int, (0...1_000_000_000).contains(base) else { throw RemoteInputPacket.invalid() }
            sequenceBase = base; values = ["mode":mode,"ptyID":id,"streamID":stream,"clientID":client,"sequenceBase":base]
        } else {
            guard let id = object["sessionID"] as? String, !id.isEmpty, id.utf8.count <= 512,
                  let revision = object["revision"] as? String, !revision.isEmpty, revision.utf8.count <= 512 else { throw RemoteInputPacket.invalid() }
            sequenceBase = 0; values = ["mode":mode,"sessionID":id,"streamID":stream,"revision":revision,"relay":true]
        }
    }
    func input(_ packet: RemoteInputPacket) throws -> (path:String, body:Data) {
        var object = values
        object.removeValue(forKey:"mode"); object.removeValue(forKey:"sequenceBase")
        object["requestID"] = UUID().uuidString
        if mode == "pty" {
            guard packet.kind == .pty, !packet.payload.isEmpty, packet.payload.count <= 16_000 else { throw RemoteInputPacket.invalid() }
            object["sequence"] = sequenceBase + Int(packet.sequence)
            object["data"] = packet.payload.base64EncodedString()
        } else {
            guard packet.kind == .native, let key = packet.payload.first, Int(key) < RemoteInputPacket.nativeKeys.count,
                  let text = String(data:packet.payload.dropFirst(),encoding:.utf8) else { throw RemoteInputPacket.invalid() }
            let kind = RemoteInputPacket.nativeKeys[Int(key)]
            guard kind == "characters" ? !text.isEmpty && text.utf8.count <= 8000 : text.isEmpty else { throw RemoteInputPacket.invalid() }
            object["kind"] = kind; object["text"] = text
        }
        return (mode == "pty" ? "/api/pty/input":"/api/input",try JSONSerialization.data(withJSONObject:object,options:[.withoutEscapingSlashes]))
    }
}

/// Main-actor handler calls remain serial across awaits. Only the socket's
/// bounded drain invokes receive; no independent task may dispatch a later key.
@MainActor final class RemoteInputProtocol {
    private let target: String?
    private let handler: @MainActor (RemoteHTTPRequest) async -> RemoteHTTPResponse
    private var binding: RemoteInputBinding?
    private var sequence: UInt32 = 0
    private var cancelled = false
    init(target:String?,handler:@escaping @MainActor (RemoteHTTPRequest) async -> RemoteHTTPResponse) { self.target = target; self.handler = handler }
    func cancel() { cancelled = true }
    func receive(_ data:Data) async throws -> Data {
        guard !cancelled, !Task.isCancelled else { throw CancellationError() }
        let packet = try RemoteInputPacket.decode(data)
        if packet.kind == .ping {
            guard packet.sequence == 0, packet.payload.count == 8 else { throw RemoteInputPacket.invalid() }
            return try RemoteInputPacket(kind:.pong,payload:packet.payload).encoded()
        }
        if packet.kind == .bind {
            guard binding == nil, packet.sequence == 0 else { throw RemoteInputPacket.invalid() }
            let value = try RemoteInputBinding(packet.payload)
            let response = await dispatch("/api/input/bind",body:try JSONSerialization.data(withJSONObject:value.values))
            try check(response); guard !cancelled, !Task.isCancelled else { throw CancellationError() }
            binding = value
            return try RemoteInputPacket(kind:.ready).encoded()
        }
        guard let binding, sequence < UInt32.max, packet.sequence == sequence+1 else { throw RemoteInputPacket.invalid() }
        let input = try binding.input(packet)
        // Reserve before awaiting. Failure ends the channel, with no replay.
        sequence = packet.sequence
        let started = RemoteTerminalPerformance.now
        let response = await dispatch(input.path,body:input.body)
        RemoteTerminalPerformance.shared.observe(.inputDispatch,elapsed:RemoteTerminalPerformance.now-started,succeeded:response.status < 400)
        try check(response); guard !cancelled, !Task.isCancelled else { throw CancellationError() }
        return try RemoteInputPacket(kind:.ack,sequence:sequence).encoded()
    }
    private func dispatch(_ path:String,body:Data) async -> RemoteHTTPResponse {
        var components = URLComponents(); components.path = path
        if let target { components.queryItems = [URLQueryItem(name:"node",value:target)] }
        return await handler(RemoteHTTPRequest(method:"POST",target:components.string!,headers:["host":"127.0.0.1","origin":"http://127.0.0.1","sec-fetch-site":"same-origin","content-type":"application/json"],body:body))
    }
    private func check(_ response:RemoteHTTPResponse) throws {
        guard response.status == 200 else {
            let object = try? JSONSerialization.jsonObject(with:response.body) as? JSONObject
            throw RemoteHTTPError(response.status,object?["error"] as? String ?? "입력 전달을 확인하지 못했습니다. 화면을 확인해주세요.")
        }
    }
}
