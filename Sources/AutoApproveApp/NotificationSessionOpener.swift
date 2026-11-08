import Foundation
import AutoApproveCore

/// One notification target, independent of unrelated screen/history polling.
@MainActor enum NotificationSessionOpener {
    static func open(_ id:String,engine:ApprovalEngine,reveal:(AgentSession) async throws -> Void) async throws {
        try await open(id,sessions:{engine.snapshot.sessions},discovered:{engine.initialDiscoveryComplete},wait:{try await Task.sleep(for:.milliseconds(100))},reveal:reveal)
    }

    static func open(_ id:String,sessions:() -> [AgentSession],discovered:() -> Bool,
                     wait:() async throws -> Void,reveal:(AgentSession) async throws -> Void) async throws {
        // Cold launch may still be discovering the original. Wait only for that
        // inventory; never join global screen or conversation history polling.
        for attempt in 0...50 {
            try Task.checkCancellation()
            let session:AgentSession
            do {session=try AttentionRequest.target(sessionID:id,sessions:sessions())}
            catch {
                guard !discovered(),attempt<50 else {throw error}
                try await wait();continue
            }
            // Reveal itself revalidates PID/start/TTY against the live process.
            // Do not retry a failed reveal or activate a different session.
            try await reveal(session)
            return
        }
    }
}
