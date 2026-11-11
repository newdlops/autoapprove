import Foundation
import Darwin
import CNativePeer

struct CodexNativePeerIdentity: Codable, Equatable, Sendable {
    let source: String
    let pid: UInt32
    let effectiveUid: UInt32
    let effectiveGid: UInt32
    let auditPidVersion: UInt32
}

/// A kernel witness cannot be constructed by decoding an observation response.
struct CodexNativeKernelPeer: Equatable, Sendable {
    let identity: CodexNativePeerIdentity
    private init(_ value: aa_native_peer_identity) {
        identity = .init(source: "macos-audit-token", pid: value.pid,
            effectiveUid: value.effective_uid, effectiveGid: value.effective_gid,
            auditPidVersion: value.audit_pid_version)
    }
    static func connectedSocket(_ fd: Int32) throws -> Self {
        var value = aa_native_peer_identity()
        guard aa_native_peer_from_socket(fd, &value) == 0 else {
            throw AppError.message("Codex 연결의 실제 프로세스를 확인하지 못했습니다.")
        }
        return Self(value)
    }
}

/// Proves only one displayed transport association. It grants no migration,
/// retained-thread ownership, complete census or stable-revision permission.
struct CodexNativeDisplayedConnection: Equatable, Sendable {
    let serverGeneration: String
    let connectionID: UInt64
    let logicalBackendID: String
    let connectionNonce: String
    let tuiPeer: CodexNativePeerIdentity
    let serverPeer: CodexNativePeerIdentity

    private init(serverGeneration: String, connectionID: UInt64, logicalBackendID: String,
        connectionNonce: String, tuiPeer: CodexNativePeerIdentity, serverPeer: CodexNativePeerIdentity) {
        self.serverGeneration = serverGeneration; self.connectionID = connectionID
        self.logicalBackendID = logicalBackendID; self.connectionNonce = connectionNonce
        self.tuiPeer = tuiPeer; self.serverPeer = serverPeer
    }

    private struct Transport: Decodable {
        let connectionNonce: String
        let serverPeer: CodexNativePeerIdentity
    }
    private struct Backend: Decodable {
        let logicalBackendId: String
        let transport: Transport
        let ownershipVerified: Bool
    }
    private struct TUI: Decodable {
        let schemaVersion: Int, producer: String, cliVersion: String, nonce: String
        let pid: UInt32
        let processIdentity: CodexNativePeerIdentity
        let displayedBackend: Backend
        let backendBindingComplete: Bool, membershipComplete: Bool, admissionGranted: Bool
    }
    private struct Connection: Decodable {
        let connectionID: UInt64
        let initialized: Bool, nativePeerIdentified: Bool
        let nativePeer: CodexNativePeerIdentity?
        let nativeConnectionNonce: String?
        let clientInventoryBound: Bool
    }
    private struct Server: Decodable {
        let schemaVersion: Int, producer: String, cliVersion: String, nonce: String
        let pid: UInt32
        let serverGeneration: String
        let connections: [Connection]
        let consistentRevision: Bool, membershipComplete: Bool, admissionGranted: Bool
        let error: String?
    }
    private static var failure: AppError {
        .message("Codex 창과 연결 서버의 동일 접속을 확인하지 못했습니다.")
    }
    private static func challenge(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }
    static func validate(tui: Data, server: Data, expectedTUINonce: String,
        expectedServerNonce: String, tuiSocketPeer: CodexNativeKernelPeer,
        serverSocketPeer: CodexNativeKernelPeer) throws -> Self {
        do {
            guard (1...1_048_576).contains(tui.count), (1...1_048_576).contains(server.count),
                  challenge(expectedTUINonce), challenge(expectedServerNonce) else { throw failure }
            let decoder = JSONDecoder()
            let client = try decoder.decode(TUI.self, from: tui)
            let host = try decoder.decode(Server.self, from: server)
            let owner = tuiSocketPeer.identity, backend = serverSocketPeer.identity
            let displayed = client.displayedBackend
            let nonce = displayed.transport.connectionNonce
            guard client.schemaVersion == 1, host.schemaVersion == 1,
                  client.producer == "autoapprove-native-tui-prototype",
                  host.producer == "autoapprove-native-server-prototype",
                  client.cliVersion == "0.167.1", host.cliVersion == client.cliVersion,
                  client.nonce == expectedTUINonce, host.nonce == expectedServerNonce,
                  host.error == nil,
                  client.pid == owner.pid, client.processIdentity == owner,
                  host.pid == backend.pid, displayed.transport.serverPeer == backend,
                  owner.effectiveUid == getuid(), backend.effectiveUid == getuid(),
                  !client.backendBindingComplete, !client.membershipComplete, !client.admissionGranted,
                  !displayed.ownershipVerified, !host.consistentRevision,
                  !host.membershipComplete, !host.admissionGranted,
                  UUID(uuidString: host.serverGeneration)?.uuidString.lowercased() == host.serverGeneration,
                  !displayed.logicalBackendId.isEmpty, displayed.logicalBackendId.utf8.count <= 128,
                  !displayed.logicalBackendId.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  let decodedNonce = Data(base64Encoded: nonce), decodedNonce.count == 16,
                  decodedNonce.base64EncodedString() == nonce,
                  host.connections.count <= 4096,
                  Set(host.connections.map(\.connectionID)).count == host.connections.count
            else { throw failure }
            let matches = host.connections.filter {
                $0.initialized && $0.nativePeerIdentified && !$0.clientInventoryBound
                && $0.nativePeer == owner && $0.nativeConnectionNonce == nonce
            }
            guard matches.count == 1 else { throw failure }
            return Self(serverGeneration: host.serverGeneration, connectionID: matches[0].connectionID,
                logicalBackendID: displayed.logicalBackendId, connectionNonce: nonce,
                tuiPeer: owner, serverPeer: backend)
        } catch { throw failure }
    }
}
