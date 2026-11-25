import Foundation

actor CodexProfileLaunchBatch {
    @TaskLocal static var current: CodexProfileLaunchBatch?
    private var verified: [String: (CodexNativePeerIdentity, CodexProfileLaunchRuntime)] = [:]

    func runtime(for entry: TerminalProfileEntry,
                 peer: @Sendable (String) throws -> CodexNativePeerIdentity? = { try CodexCohortRuntime.peer(home: $0) },
                 attest: @Sendable (String) throws -> CodexNativePeerIdentity = { try CodexOfficialExecutable.verifyServer(CodexQueueConnection(home: $0)) },
                 prepare: @Sendable () async throws -> CodexProfileLaunchRuntime) async throws -> CodexProfileLaunchRuntime {
        let home = try CodexAccountTransitionTarget.canonicalHome(entry.providerHome ?? NSHomeDirectory() + "/.codex")
        let before = try? peer(home)
        if let before, let (expected, runtime) = verified[home], expected == before {
            return runtime
        }
        verified.removeValue(forKey: home)
        let runtime = try await prepare()
        if !runtime.standalone, let before, (try? attest(home)) == before {
            verified[home] = (before, runtime)
        }
        return runtime
    }
}
