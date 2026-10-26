import Foundation
import CryptoKit
import Network

/// RFC 6455 without extensions. Client masking, fragmentation, control frames,
/// canonical lengths and bounded messages are checked before any input runs.
public struct RemoteWebSocketParser {
    public enum Event: Equatable { case message(Data), ping(Data), pong(Data), close(Data) }
    public static let maximumMessage = RemoteInputPacket.maximumPayload+8
    private var buffer = Data(), fragments = Data()
    private var fragmented = false
    public init() {}
    public mutating func append(_ data:Data) throws -> [Event] {
        guard buffer.count+data.count <= 128_000 else { throw RemoteInputPacket.invalid() }
        buffer.append(data)
        var events:[Event] = []
        while buffer.count >= 2 {
            let start = buffer.startIndex, first = buffer[start], second = buffer[start+1]
            let final = first & 0x80 != 0, code = first & 15, count = Int(second & 127)
            guard first & 0x70 == 0, second & 0x80 != 0, [0,2,8,9,10].contains(code), code < 8 || final && count <= 125 else { throw RemoteInputPacket.invalid() }
            var length = count, head = 2
            if count == 126 {
                guard buffer.count >= 4 else { break }
                length = Int(buffer[start+2]) << 8 | Int(buffer[start+3]); head = 4
                guard length >= 126 else { throw RemoteInputPacket.invalid() }
            } else if count == 127 { throw RemoteInputPacket.invalid() } // Above our message bound.
            guard length <= Self.maximumMessage, code >= 8 || fragments.count+length <= Self.maximumMessage else { throw RemoteInputPacket.invalid() }
            guard buffer.count >= head+4+length else { break }
            let mask = Array(buffer[(start+head)..<(start+head+4)])
            var payload = Data(capacity:length)
            for offset in 0..<length { payload.append(buffer[start+head+4+offset] ^ mask[offset & 3]) }
            buffer.removeFirst(head+4+length)
            switch code {
            case 8:
                if !payload.isEmpty {
                    guard payload.count >= 2, String(data:payload.dropFirst(2),encoding:.utf8) != nil else { throw RemoteInputPacket.invalid() }
                    let code = UInt16(payload[payload.startIndex]) << 8 | UInt16(payload[payload.startIndex+1])
                    guard [1000,1001,1002,1003,1007,1008,1009,1010,1011,1012,1013,1014].contains(code) || (3000...4999).contains(code) else { throw RemoteInputPacket.invalid() }
                }
                events.append(.close(payload)); return events
            case 9: events.append(.ping(payload))
            case 10: events.append(.pong(payload))
            case 2:
                guard !fragmented else { throw RemoteInputPacket.invalid() }
                if final { events.append(.message(payload)) } else { fragments = payload; fragmented = true }
            default:
                guard fragmented else { throw RemoteInputPacket.invalid() }
                fragments.append(payload)
                if final { events.append(.message(fragments)); fragments = Data(); fragmented = false }
            }
        }
        return events
    }
    public static func frame(_ payload:Data,code:UInt8 = 2) -> Data {
        var result = Data([0x80 | code])
        if payload.count < 126 { result.append(UInt8(payload.count)) }
        else { result.append(contentsOf:[126,UInt8(truncatingIfNeeded:payload.count >> 8),UInt8(truncatingIfNeeded:payload.count)]) }
        result.append(payload); return result
    }
    public static func handshake(_ request:RemoteHTTPRequest) throws -> Data {
        func tokens(_ key:String) -> [String] { request.headers[key]?.lowercased().split(separator:",").map {$0.trimmingCharacters(in:.whitespaces)} ?? [] }
        guard request.method == "GET", request.body.isEmpty, request.headers["origin"] != nil,
              tokens("connection").contains("upgrade"), tokens("upgrade") == ["websocket"],
              request.headers["sec-websocket-version"] == "13", tokens("sec-websocket-protocol").contains("autoapprove-input.v1"),
              let key = request.headers["sec-websocket-key"], Data(base64Encoded:key)?.count == 16 else { throw RemoteHTTPError(426,"실시간 입력 연결을 다시 준비해주세요.") }
        let accept = Data(Insecure.SHA1.hash(data:Data((key+"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        return Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\nSec-WebSocket-Protocol: autoapprove-input.v1\r\nCache-Control: no-store\r\n\r\n".utf8)
    }
}

final class RemoteInputWebSocket: @unchecked Sendable {
    private let connection:NWConnection,queue:DispatchQueue,channel:RemoteInputProtocol
    private let onClose:()->Void
    private var parser = RemoteWebSocketParser()
    private var pending:[Data] = [],pendingBytes = 0,outgoing:[Data] = [],outgoingBytes = 0
    private var draining = false,sending = false,closed = false,closing = false,started = false
    private var initialBytes = Data()
    private var task:Task<Void,Never>?,timer:DispatchSourceTimer?
    private var lastReceived = ProcessInfo.processInfo.systemUptime
    init(connection:NWConnection,queue:DispatchQueue,channel:RemoteInputProtocol,onClose:@escaping ()->Void) { self.connection = connection; self.queue = queue; self.channel = channel; self.onClose = onClose }
    func start() {
        guard !started,!closed else { return };started = true
        let timer = DispatchSource.makeTimerSource(queue:queue); self.timer = timer
        timer.setEventHandler { [weak self] in
            guard let self,!self.closed else { return }
            guard ProcessInfo.processInfo.systemUptime-self.lastReceived < 45 else { self.onClose(); return }
            self.send(Data(),code:9)
        }
        timer.schedule(deadline:.now()+15,repeating:15); timer.resume()
        // The bridge uses this authenticated greeting to finish its upgrade.
        send((try? RemoteInputPacket(kind:.ready,payload:Data([1])).encoded()) ?? Data())
        let bytes = initialBytes;initialBytes = Data();if !bytes.isEmpty { receive(bytes) }
    }
    func receive(_ data:Data) {
        guard !closed,!closing else { return }
        if !started { guard initialBytes.count+data.count <= 128_000 else { onClose();return };initialBytes.append(data);return }
        do {
            for event in try parser.append(data) {
                lastReceived = ProcessInfo.processInfo.systemUptime
                switch event {
                case .message(let bytes):
                    guard pending.count < RemoteInputPacket.windowMessages+2, pendingBytes+bytes.count <= RemoteInputPacket.windowBytes+8192 else { throw RemoteInputPacket.invalid() }
                    pending.append(bytes); pendingBytes += bytes.count
                case .ping(let bytes): send(bytes,code:10)
                case .pong: break
                case .close(let bytes): closing = true; pending.removeAll(); pendingBytes = 0; task?.cancel(); send(bytes,code:8)
                }
            }
            drain()
        } catch { fail(error) }
    }
    private func drain() {
        guard !closed,!closing,!draining,!pending.isEmpty else { return }
        draining = true
        let data = pending.removeFirst(); pendingBytes -= data.count
        task = Task { @MainActor [weak self,channel] in
            do {
                let reply = try await channel.receive(data)
                self?.queue.async { [weak self] in guard let self,!self.closed,!self.closing else { return };self.draining = false;self.task = nil;self.send(reply);self.drain() }
            } catch { self?.queue.async { [weak self] in self?.fail(error) } }
        }
    }
    private func fail(_ error:Error) {
        guard !closed,!closing else { return };closing = true;task?.cancel();pending.removeAll();pendingBytes = 0
        let message = (try? JSONSerialization.data(withJSONObject:["status":(error as? RemoteHTTPError)?.status ?? 409,"message":String(error.localizedDescription.prefix(512))])) ?? Data()
        if let packet = try? RemoteInputPacket(kind:.failure,payload:message).encoded() { send(packet) }
        send(Data([3,240]),code:8) // 1008: no uncertain input is replayed.
    }
    private func send(_ payload:Data,code:UInt8 = 2) {
        guard !closed else { return }
        let data = RemoteWebSocketParser.frame(payload,code:code)
        guard outgoingBytes+data.count <= 64_000 else { onClose(); return }
        outgoing.append(data);outgoingBytes += data.count;pump()
    }
    private func pump() {
        guard !closed,!sending,!outgoing.isEmpty else { if closing && !sending && outgoing.isEmpty { onClose() };return }
        sending = true;let data = outgoing.removeFirst();outgoingBytes -= data.count
        connection.send(content:data,completion:.contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {guard !self.closed else { return };self.sending = false;if error != nil {self.onClose()} else {self.pump()}}
        })
    }
    func cancel() {
        guard !closed else { return };closed = true;task?.cancel();task = nil
        timer?.setEventHandler {};timer?.cancel();timer = nil;pending.removeAll();outgoing.removeAll()
        Task { @MainActor [channel] in channel.cancel() }
    }
}
