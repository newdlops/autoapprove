import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AutoApproveCore

private final class NativeIdentityProbe: @unchecked Sendable {
    private let lock = NSLock()
    let original = ProcessDiscovery.parse("887001 1 ttys990 887001 887001 Thu Oct 22 09:00:00 2026 /fixture/codex")[0]
    var replacement: ProcessRecord?
    var changesAt = Int.max, failsAt = Int.max
    private var targets: [Int32] = [], reads = 0, reveals = 0, captures = 0
    func targeted(_ pid: Int32) throws -> [ProcessRecord] {
        lock.lock(); defer { lock.unlock() }
        targets.append(pid)
        if targets.count >= failsAt { throw AppError.message("synthetic identity read failed") }
        if targets.count >= changesAt { return replacement.map { [$0] } ?? [] }
        return [original]
    }
    func full(changing: Bool = false) -> [ProcessRecord] {
        lock.lock(); defer { lock.unlock() }; reads += 1
        if changing && reads >= changesAt { return replacement.map { [$0] } ?? [] }
        return [original]
    }
    func reveal() { lock.lock(); reveals += 1; lock.unlock() }
    func capture() { lock.lock(); captures += 1; lock.unlock() }
    var counts: (targets: [Int32], full: Int, reveals: Int, captures: Int) {
        lock.lock(); defer { lock.unlock() }; return (targets, reads, reveals, captures)
    }
    var adapter: ScreenHostAdapter {
        ScreenHostAdapter(screens: { targets in
            TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: "Synthetic original\nREADY> ") })
        }, approve: { _,_,_ in throw AppError.message("Read-only identity tests cannot send input") },
        reveal: { [self] _ in reveal(); return nil })
    }
    var session: AgentSession {
        AgentSession(id: original.key, agent: .codex, pid: original.pid, started: original.started,
            tty: "/dev/" + original.tty, cwd: "/fixture/native-identity", terminal: .terminal)
    }
}

extension ApprovalTests {
    @MainActor func testNativeIdentityReadsOnlyTheRequestedPIDAtEveryConnectionStage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-native-identity-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for failureStage in [0,1,2,3] {
            let probe = NativeIdentityProbe()
            if failureStage > 0 { probe.changesAt = failureStage }
            let engine = try ApprovalEngine(paths: AppPaths(directory: root.appendingPathComponent(String(failureStage))),
                claudeRegistryReader: { _ in [] }, processReader: { probe.full() }, screenAdapters: [.terminal: probe.adapter],
                terminalInputAvailable: { false }, singleProcessReader: { try probe.targeted($0) })
            defer { engine.stop() }
            engine.updateDiscovery([probe.session], records: [probe.original])
            if failureStage == 0 {
                let frame = try await engine.connectRemoteTerminal(["sessionID": probe.session.id])
                try expectEqual(frame.sessionID, probe.session.id); try expectEqual(frame.screen, "Synthetic original\nREADY> ")
                try expectEqual(probe.counts.targets, Array(repeating: probe.original.pid, count: 3))
                try expectEqual(probe.counts.reveals, 1)
            } else {
                do { _ = try await engine.connectRemoteTerminal(["sessionID": probe.session.id]); throw AppError.message("A changed identity was connected") }
                catch let error as RemoteHTTPError { try expectEqual(error.status, 409) }
                try expectEqual(probe.counts.targets, Array(repeating: probe.original.pid, count: failureStage))
                try expectEqual(probe.counts.reveals, failureStage == 3 ? 1 : 0)
            }
        }
        for field in ["pid", "started", "tty", "agent", "foreground"] {
            let probe = NativeIdentityProbe(); probe.changesAt = 2
            var changed = probe.original
            switch field {
            case "pid": changed.pid += 1
            case "started": changed.started += " replaced"
            case "tty": changed.tty = "ttys991"
            case "agent": changed.executable = "/fixture/claude"
            default: changed.foregroundGroup = changed.processGroup + 1
            }
            probe.replacement = changed
            let engine = try ApprovalEngine(paths: AppPaths(directory: root.appendingPathComponent(field)),
                claudeRegistryReader: { _ in [] }, processReader: { probe.full() }, screenAdapters: [.terminal: probe.adapter],
                terminalInputAvailable: { false }, singleProcessReader: { try probe.targeted($0) })
            defer { engine.stop() }
            engine.updateDiscovery([probe.session], records: [probe.original])
            do { _ = try await engine.connectRemoteTerminal(["sessionID": probe.session.id]); throw AppError.message("Identity field was ignored: " + field) }
            catch let error as RemoteHTTPError { try expectEqual(error.status, 409) }
            try expectEqual(probe.counts.targets.count, 2); try expectEqual(probe.counts.reveals, 0)
        }
    }

    @MainActor func testNativeIdentityFailureDoesNotFallbackAndCustomReaderStaysAuthoritative() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-native-reader-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = NativeIdentityProbe(); probe.failsAt = 1
        let engine = try ApprovalEngine(paths: AppPaths(directory: root.appendingPathComponent("failure")),
            claudeRegistryReader: { _ in [] }, processReader: { probe.full() }, screenAdapters: [.terminal: probe.adapter],
            terminalInputAvailable: { false }, singleProcessReader: { try probe.targeted($0) })
        defer { engine.stop() }
        engine.updateDiscovery([probe.session], records: [probe.original])
        let before = probe.counts.full
        do { _ = try await engine.connectRemoteTerminal(["sessionID": probe.session.id]); throw AppError.message("A failed reader was ignored") }
        catch { try expectEqual(error.localizedDescription, "synthetic identity read failed") }
        try expectEqual(probe.counts.full, before, "A targeted failure cannot fall back to a different authority")
        try expectEqual(probe.counts.targets, [probe.original.pid]); try expectEqual(probe.counts.reveals, 0)

        let custom = NativeIdentityProbe(); custom.changesAt = 2
        let compatible = try ApprovalEngine(paths: AppPaths(directory: root.appendingPathComponent("custom")),
            claudeRegistryReader: { _ in [] }, processReader: { custom.full(changing: true) },
            screenAdapters: [.terminal: custom.adapter], terminalInputAvailable: { false })
        defer { compatible.stop() }
        compatible.updateDiscovery([custom.session], records: [custom.original])
        do { _ = try await compatible.connectRemoteTerminal(["sessionID": custom.session.id]); throw AppError.message("A custom identity change was ignored") }
        catch let error as RemoteHTTPError { try expectEqual(error.status, 409) }
        try expectEqual(custom.counts.full, 2); try expectEqual(custom.counts.reveals, 0)
        try expect(custom.counts.targets.isEmpty)
    }

    @MainActor func testNativeIdentityPreviewAndCachedPreviewRejectChangedProcesses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-native-preview-identity-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pixels = Data(repeating: 127, count: 64)
        let provider = CGDataProvider(data: pixels as CFData)!
        let image = CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let encoded = NSMutableData(), destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil); try expect(CGImageDestinationFinalize(destination))
        let jpeg = TerminalNativeImage(data: (encoded as Data).base64EncodedString(), width: 4, height: 4)
        for changeAt in [2,5] {
            let probe = NativeIdentityProbe(); probe.changesAt = changeAt
            let capture = TerminalWindowCapture(permissions: { TerminalWindowPermissions(screen: true, keyboard: false, automation: true) },
                requestPermissions: { }, metadata: { tty in
                    TerminalWindowMetadata(tty: tty, windowID: 91, ownerPID: 900, ownerBundleID: "com.apple.Terminal", selected: true, minimized: false)
                }, capture: { _ in probe.capture(); return jpeg })
            let engine = try ApprovalEngine(paths: AppPaths(directory: root.appendingPathComponent(String(changeAt))),
                claudeRegistryReader: { _ in [] }, processReader: { probe.full() }, screenAdapters: [.terminal: probe.adapter],
                terminalWindowCapture: capture, terminalInputAvailable: { false }, singleProcessReader: { try probe.targeted($0) })
            defer { engine.stop() }
            engine.updateDiscovery([probe.session], records: [probe.original]); await engine.connectTerminal()
            if changeAt == 5 {
                let fresh = try await engine.remoteTerminal(sessionID: probe.session.id, renderWindow: true)
                let cached = try await engine.remoteTerminal(sessionID: probe.session.id, renderWindow: true)
                try expectEqual(fresh.nativeDisplay?.state, .live); try expectEqual(cached.nativeDisplay?.image, jpeg)
                try expectEqual(probe.counts.targets.count, 4); try expectEqual(probe.counts.captures, 1)
            }
            do { _ = try await engine.remoteTerminal(sessionID: probe.session.id, renderWindow: true); throw AppError.message("A changed original retained live pixels") }
            catch let error as RemoteHTTPError { try expectEqual(error.status, 409) }
            try expectEqual(probe.counts.targets.count, changeAt + 1, "The failed capture is revalidated and rejected, never rescued by the full reader")
            try expectEqual(probe.counts.captures, 1)
        }
    }
}
