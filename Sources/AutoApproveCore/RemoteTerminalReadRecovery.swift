import Foundation

/// Only read-only terminal observations use this retry. An input that replaces
/// an in-flight screen read is transient; identity/permission errors stay final.
@MainActor public enum RemoteTerminalReadRecovery {
    public static func read(_ operation: @MainActor () async throws -> RemoteTerminalFrame) async throws -> RemoteTerminalFrame {
        for attempt in 0...2 {
            try Task.checkCancellation()
            do { return try await operation() }
            catch {
                // A shared observation can be cancelled while this viewer is
                // still connected. Only caller cancellation ends this read;
                // retrying a fresh observation never repeats an input.
                try Task.checkCancellation()
                let response=error as? RemoteHTTPError
                guard error is CancellationError || response?.status == 409 && response?.diagnostics?["failureKind"] == "observationChanged" else {throw error}
                if attempt == 2 {
                    throw RemoteHTTPError(503,response?.message ?? "화면 조회가 바뀌어 같은 터미널에 다시 연결합니다.",
                        diagnostics:["failureKind":"observationChanged"])
                }
                try await Task.sleep(for:.milliseconds(30*(attempt+1)))
            }
        }
        throw CancellationError()
    }
}
