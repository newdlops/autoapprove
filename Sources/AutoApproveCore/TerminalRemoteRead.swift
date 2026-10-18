import Foundation

/// Native reads enforce authorization on the actual send. The compatibility
/// script retains its existing consent behavior behind a fresh permission check.
public enum TerminalRemoteRead {
    public static func read(native: () throws -> TerminalSnapshot?,
                            fallbackPermission: () throws -> Bool,
                            script: () throws -> TerminalSnapshot) throws -> TerminalSnapshot {
        try Task.checkCancellation()
        let nativeValue = try native()
        try Task.checkCancellation()
        if let nativeValue { return nativeValue }
        guard try fallbackPermission() else { throw TerminalAdapterError.permissionDenied }
        try Task.checkCancellation()
        let snapshot = try script()
        try Task.checkCancellation()
        return snapshot
    }
}
