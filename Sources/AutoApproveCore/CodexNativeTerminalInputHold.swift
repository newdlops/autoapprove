import Foundation

/// One utility-task owner. This pauses terminal input only; it cannot authorize
/// migration, stop accepted work, or attest the client's complete thread scope.
final class CodexNativeTerminalInputHold {
    enum Operation: String { case inspect, pause, status, renew, release }
    struct Reply: Decodable {
        let schemaVersion: Int, producer: String, pid: UInt32
        let nonce: String, generation: String, leaseId: String?
        let leaseActive: Bool, terminalInputBlocked: Bool, leaseTTLMillis: UInt32
        let acceptedWorkStopped: Bool, membershipComplete: Bool, migrationAuthorized: Bool
    }
    private enum Phase { case ready, held, closed }
    private let connection: CodexNativeLineConnection
    private var phase: Phase = .ready
    private var generation: String?
    private var leaseID: String?
    private static var failure: AppError {
        .message("선택한 Codex 창의 입력 차단 상태를 확인하지 못했습니다. 이동을 진행하지 않습니다.")
    }
    init(path: String, expected: CodexNativeDisplayedConnection) throws {
        connection = try CodexNativeLineConnection(path: path)
        do {
            guard connection.peer.identity == expected.tuiPeer else { throw Self.failure }
            let inspected = try call(.inspect)
            generation = inspected.generation
        } catch {
            connection.close()
            throw error
        }
    }
    deinit { connection.close() }
    func close() { phase = .closed; connection.close() }
    func pause() throws {
        guard phase == .ready else { throw Self.failure }
        let reply = try call(.pause)
        leaseID = reply.leaseId; phase = .held
    }
    func status() throws { guard phase == .held else { throw Self.failure }; _ = try call(.status) }
    func renew() throws { guard phase == .held else { throw Self.failure }; _ = try call(.renew) }
    func release() throws {
        guard phase == .held else { throw Self.failure }
        defer { close() }
        _ = try call(.release)
    }
    private func call(_ operation: Operation) throws -> Reply {
        do {
            let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            var request = ["op": operation.rawValue, "nonce": nonce]
            if let generation { request["generation"] = generation }
            if let leaseID { request["leaseId"] = leaseID }
            let data = try connection.exchange(JSONEncoder().encode(request))
            return try Self.validate(data, operation: operation, nonce: nonce,
                peer: connection.peer.identity, generation: generation, leaseID: leaseID)
        } catch {
            close()
            throw error
        }
    }
    static func validate(_ data: Data, operation: Operation, nonce: String,
        peer: CodexNativePeerIdentity, generation: String?, leaseID: String?) throws -> Reply {
        do {
            guard (1...65_536).contains(data.count), nonce.utf8.count == 32,
                  nonce.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw failure }
            let reply = try JSONDecoder().decode(Reply.self, from: data)
            let held = operation != .inspect && operation != .release
            guard reply.schemaVersion == 1, reply.producer == "autoapprove-native-tui-input-hold",
                  reply.pid == peer.pid, reply.nonce == nonce,
                  UUID(uuidString: reply.generation)?.uuidString.lowercased() == reply.generation,
                  generation == nil || reply.generation == generation,
                  !reply.acceptedWorkStopped, !reply.membershipComplete, !reply.migrationAuthorized,
                  reply.leaseActive == held, reply.terminalInputBlocked == held,
                  held ? (1...30_000).contains(reply.leaseTTLMillis) : reply.leaseTTLMillis == 0
            else { throw failure }
            if operation == .inspect {
                guard generation == nil, leaseID == nil, reply.leaseId == nil else { throw failure }
            } else {
                guard generation != nil, let id = reply.leaseId,
                      UUID(uuidString: id)?.uuidString.lowercased() == id,
                      operation == .pause ? leaseID == nil : id == leaseID else { throw failure }
            }
            return reply
        } catch { throw failure }
    }
}
