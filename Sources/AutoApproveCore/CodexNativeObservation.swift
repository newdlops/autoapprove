import Foundation
import Darwin

struct CodexNativeObservation: Sendable {
    let data: Data
    let nonce: String
    let peer: CodexNativeKernelPeer

    /// One read-only local diagnostic request; no conversation or account RPC.
    static func query(path: String) async throws -> Self {
        let child = Task.detached(priority: .utility) { try read(path: path) }
        return try await withTaskCancellationHandler(operation: {
            let result = try await child.value
            try Task.checkCancellation()
            return result
        }, onCancel: { child.cancel() })
    }

    private static func read(path: String) throws -> Self {
        let deadline = CodexNativeLineConnection.deadline
        let connection = try CodexNativeLineConnection(path: path, deadline: deadline)
        defer { connection.close() }
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let request = try JSONEncoder().encode(["nonce": nonce])
        let data = try connection.exchange(request, deadline: deadline)
        return Self(data: data, nonce: nonce, peer: connection.peer)
    }
}

extension CodexNativeDisplayedConnection {
    static func observe(tuiSocket: String, serverSocket: String) async throws -> Self {
        async let tui = CodexNativeObservation.query(path: tuiSocket)
        async let server = CodexNativeObservation.query(path: serverSocket)
        let (client, host) = try await (tui, server)
        return try validate(tui: client.data, server: host.data, expectedTUINonce: client.nonce,
            expectedServerNonce: host.nonce, tuiSocketPeer: client.peer, serverSocketPeer: host.peer)
    }
}
