import Foundation
import AutoApproveCore

extension ApprovalTests {
    func testRemoteNativeReadKeepsAuthorizationAndExactFallback() throws {
        let raw = "원본 예 🙂\n\u{1b}[31mtext\u{1b}[0m\u{0}\n"
        let frame = TerminalSnapshot(screens: [TerminalScreen(tty: "/dev/original", contents: raw,
            title: "fixture", cursor: TerminalCursor(offset: 1),
            display: TerminalTextSnapshot(screen: raw, cursor: TerminalCursor(offset: 1)))])
        var reads = 0, checks = 0, scripts = 0
        let result = try TerminalRemoteRead.read(native: { reads += 1; return frame },
            fallbackPermission: { checks += 1; return true }, script: { scripts += 1; return TerminalSnapshot() })
        try expectEqual(reads, 1)
        try expectEqual(checks, 0, "An OS-authorized native read must not repeat the fallback permission query")
        try expectEqual(scripts, 0)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try expectEqual(try encoder.encode(result), try encoder.encode(frame), "Text bytes, title, cursor and display must pass through unchanged")

        for granted in [false, true] {
            var order = [String]()
            do {
                let result = try TerminalRemoteRead.read(native: { order.append("native"); return nil },
                    fallbackPermission: { order.append("permission"); return granted },
                    script: { order.append("script"); return frame })
                try expect(granted)
                try expectEqual(try encoder.encode(result), try encoder.encode(frame))
            } catch let error as TerminalAdapterError {
                try expect(!granted); try expectEqual(error, .permissionDenied)
            }
            try expectEqual(order, granted ? ["native", "permission", "script"] : ["native", "permission"])
        }
        for error: Error in [TerminalAdapterError.permissionDenied, TerminalAdapterError.automationDenied("Terminal"),
                             NSError(domain: NSOSStatusErrorDomain, code: -1712), CancellationError()] {
            var reads = 0, checks = 0, scripts = 0
            var caught: Error?
            do { _ = try TerminalRemoteRead.read(native: { reads += 1; throw error },
                fallbackPermission: { checks += 1; return true }, script: { scripts += 1; return frame }) }
            catch { caught = error }
            try expectNotNil(caught)
            try expectEqual((caught! as NSError).domain, (error as NSError).domain)
            try expectEqual((caught! as NSError).code, (error as NSError).code)
            try expectEqual(reads, 1); try expectEqual(checks, 0); try expectEqual(scripts, 0, "A failed native read cannot begin a second response path")
        }
        var nativeCalls = 0, permissionCalls = 0, scriptCalls = 0
        let failure = NSError(domain: "fixture-permission-query", code: 9)
        var caught: Error?
        do { _ = try TerminalRemoteRead.read(native: { nativeCalls += 1; return nil },
            fallbackPermission: { permissionCalls += 1; throw failure }, script: { scriptCalls += 1; return frame }) }
        catch { caught = error }
        try expectEqual((caught as NSError?)?.domain, failure.domain)
        try expectEqual(nativeCalls, 1); try expectEqual(permissionCalls, 1); try expectEqual(scriptCalls, 0)

        // No earlier success can authorize a later read after revocation.
        var allowed = true, currentReads = 0, laterChecks = 0, laterScripts = 0
        func read() throws -> TerminalSnapshot {
            try TerminalRemoteRead.read(native: {
                currentReads += 1
                guard allowed else { throw TerminalAdapterError.permissionDenied }
                return frame
            }, fallbackPermission: { laterChecks += 1; return allowed }, script: { laterScripts += 1; return frame })
        }
        _ = try read(); allowed = false
        try expectThrows(read())
        try expectEqual(currentReads, 2); try expectEqual(laterChecks, 0); try expectEqual(laterScripts, 0)
    }

    func testRemoteNativeReadCancellationStopsEveryBoundary() async throws {
        for boundary in ["before", "native", "native-nil", "permission", "script"] {
            let task = Task { () throws -> Bool in
                var native = 0, permission = 0, script = 0
                if boundary == "before" { withUnsafeCurrentTask { $0?.cancel() } }
                do {
                    _ = try TerminalRemoteRead.read(native: {
                        native += 1
                        if boundary == "native" { withUnsafeCurrentTask { $0?.cancel() }; return TerminalSnapshot() }
                        if boundary == "native-nil" { withUnsafeCurrentTask { $0?.cancel() } }
                        return nil
                    }, fallbackPermission: {
                        permission += 1
                        if boundary == "permission" { withUnsafeCurrentTask { $0?.cancel() } }
                        return true
                    }, script: {
                        script += 1
                        withUnsafeCurrentTask { $0?.cancel() }
                        return TerminalSnapshot()
                    })
                    return false
                } catch is CancellationError {
                    return native == (boundary == "before" ? 0 : 1)
                        && permission == (["permission", "script"].contains(boundary) ? 1 : 0)
                        && script == (boundary == "script" ? 1 : 0)
                }
            }
            try expect(try await task.value, "Cancellation at \(boundary) cannot release a frame or start another read")
        }
    }
}
