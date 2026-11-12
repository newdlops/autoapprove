#if DEBUG
import Foundation
@testable import AutoApproveCore

extension ApprovalTests {
    func testIndependentLoginCopiesAccountWithoutSharingCredentialFile()throws {
        let root=URL(fileURLWithPath:"/private/tmp/aa-independent-copy-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let groups=CodexLoginGroupStore(directory:root.appendingPathComponent("groups"))
        let independent=CodexIndependentLoginStore(directory:root.appendingPathComponent("independent"))
        let source=try groups.create(name:"Source"),destination=try independent.create(name:"Separate")
        let bytes=Data(#"{"OPENAI_API_KEY":"owned-independent-fixture"}"#.utf8)
        let auth=source.home+"/auth.json"
        try expect(FileManager.default.createFile(atPath:auth,contents:bytes,attributes:[.posixPermissions:0o600]))
        let credential=try CodexCredentialFile.capture(home:source.home)
        try credential.copyConfigurationForIndependentLogin(to:destination.home)
        try credential.copyForIndependentLogin(to:destination.home)
        try CodexCredentialFile.requireIndependent(credential,CodexCredentialFile.capture(home:destination.home))
        try expectEqual(try Data(contentsOf:URL(fileURLWithPath:destination.home+"/auth.json")),bytes)
        let writer=try FileHandle(forWritingTo:URL(fileURLWithPath:auth))
        try writer.truncate(atOffset:0);try writer.write(contentsOf:Data("changed-source-login".utf8));try writer.close()
        try expectEqual(try Data(contentsOf:URL(fileURLWithPath:destination.home+"/auth.json")),bytes)
        try expectEqual(try groups.list(),[source])
    }
    @MainActor func testIndependentLoginDoesNotEnrollOrStartServer() async throws {
        let root=URL(fileURLWithPath:"/private/tmp/aa-independent-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let engine=try ApprovalEngine(paths:.init(directory:root),processReader:{[]},
            codexManagedServers:.init(inspect:{_,_ in throw AppError.message("Must not inspect a server")},
                prepare:{_,_ in throw AppError.message("Must not start a server")}))
        let shared=try await engine.createCodexLoginGroup(name:"Shared")
        let independent=try await engine.createCodexIndependentLogin(name:"Independent")
        try expect(shared.home != independent.home)
        try expectEqual(try await engine.codexLoginGroups(),[shared])
        try expectEqual(try await engine.codexIndependentLogins(),[independent])
        try expect(try engine.codexIndependentLoginStore.contains(home:independent.home))
        try expectEqual(try String(contentsOfFile:independent.home+"/config.toml",encoding:.utf8),
            "cli_auth_credentials_store = \"file\"\n[features]\ndaemon_auto_start = false\n")
        try expect(!FileManager.default.fileExists(atPath:independent.home+"/auth.json"))
        let restored=try ApprovalEngine(paths:.init(directory:root),processReader:{[]})
        try expectEqual(try await restored.codexIndependentLogins(),[independent])
        try expectEqual(try await restored.codexLoginGroups(),[shared])
        try expect(engine.codexAccountTransitionStates.isEmpty && engine.snapshot.sessions.isEmpty)
    }
}
#endif
