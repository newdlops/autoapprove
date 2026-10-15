import Foundation

/// Only read-only terminal observations use this retry. An input that replaces
/// an in-flight screen read is transient; identity/permission errors stay final.
@MainActor public enum RemoteTerminalReadRecovery {
    public static func read(_ operation: @MainActor () async throws -> RemoteTerminalFrame) async throws -> RemoteTerminalFrame {
        for attempt in 0...2 {
            try Task.checkCancellation()
            do { return try await operation() }
            catch let error as RemoteHTTPError where error.status == 409 && error.diagnostics?["failureKind"] == "observationChanged" {
                if attempt == 2 { throw RemoteHTTPError(503,error.message,diagnostics:error.diagnostics) }
                try await Task.sleep(for:.milliseconds(30*(attempt+1)))
            }
        }
        throw CancellationError()
    }
}
