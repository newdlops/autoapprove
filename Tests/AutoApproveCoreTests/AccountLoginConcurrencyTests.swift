import AutoApproveCore
import CryptoKit
import Foundation

func waitForFixtureSignal(_ signal: DispatchSemaphore, timeout: DispatchTimeInterval) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: signal.wait(timeout: .now() + timeout) == .success) }
    }
}

extension ApprovalTests {
    @MainActor func testAccountLoginIsolationAndCancellationDuringPreparation() async throws {
        let launch: AgentAccountServices.PreparedLaunch = {
            try ManagedPTY(cwd: "/private/tmp", command: ["/bin/sleep", "30"])
        }
        let services = AgentAccountServices(home: "/private/tmp", check: { .init(agent: $0, phase: "signedOut") }, launch: { _ in try launch() })
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), spawned = DispatchSemaphore(value: 0)
        var slow = services
        slow.prepareLaunch = { _ in
            entered.signal()
            guard release.wait(timeout: .now() + 5) == .success else { throw AppError.message("Fixture preparation timed out") }
            return { spawned.signal(); return try launch() }
        }
        let native = slow
        let accounts = AgentAccounts(services: services, codexServices: { _ in native })
        defer { release.signal(); accounts.stop() }
        let pin = try RemoteTunnelPIN.create("123456")
        let node = UUID().uuidString
        let hello = accounts.hello(node: node, pin: pin)
        let client = Curve25519.KeyAgreement.PrivateKey()
        let server = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(base64Encoded: hello["publicKey"] as! String)!)
        let secret = try client.sharedSecretFromKeyAgreement(with: server)
        let keyID = hello["keyID"] as! String
        func request(_ object: JSONObject) async throws -> JSONObject {
            let id = UUID().uuidString
            let aad = Data("AutoApprove accounts v1:\(node):\(keyID):\(id)".utf8)
            let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: aad, outputByteCount: 32)
            var body = object
            body["time"] = Date().timeIntervalSince1970 * 1000
            let data = try ChaChaPoly.seal(JSONSerialization.data(withJSONObject: body), using: key, authenticating: aad)
            let response = try await accounts.encrypted(["version": 1, "keyID": keyID, "request": id,
                "publicKey": client.publicKey.rawRepresentation.base64EncodedString(), "payload": data.combined.base64EncodedString()], node: node, pin: pin)
            let box = try ChaChaPoly.SealedBox(combined: Data(base64Encoded: response["payload"] as! String)!)
            return try JSONSerialization.jsonObject(with: ChaChaPoly.open(box, using: key, authenticating: aad + Data(".reply".utf8))) as! JSONObject
        }
        let unlock = try await request(["action": "unlock", "pin": "123456"])
        guard let token = unlock["token"] as? String else { throw AppError.message("Fixture login grant failed") }
        let started = try await request(["action": "begin", "agent": "claude", "id": UUID().uuidString, "token": token])
        try expectEqual(started["phase"] as? String, "starting")
        try expect(accounts.busy && !accounts.codexLoginActive)
        let original = accounts.privateTTYs
        try expectEqual(original.count, 1)
        try accounts.beginNativeCodexLogin(.init(home: "/private/tmp", executable: "codex"))
        try expect(await waitForFixtureSignal(entered, timeout: .seconds(2)))
        try expect(accounts.codexLoginActive)
        let duplicate = try await request(["action": "begin", "agent": "codex", "id": UUID().uuidString, "token": token])
        try expectEqual(duplicate["status"] as? Int, 409)
        accounts.cancelNativeCodexLogin()
        release.signal()
        try expectEqual(accounts.nativeCodexLogin?.phase, "cancelled")
        try expect(accounts.busy && !accounts.codexLoginActive)
        try expectEqual(accounts.privateTTYs, original)
        try expect(await !waitForFixtureSignal(spawned, timeout: .milliseconds(150)))
    }
}
