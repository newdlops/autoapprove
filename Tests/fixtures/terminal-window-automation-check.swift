// Injected Automation-denial boundary. No live Apple events or TCC prompts.
import Foundation
import AutoApproveCore

private final class ReadCounter: @unchecked Sendable {
    let lock = NSLock(); private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
private final class AutomationGrant: @unchecked Sendable {
    let lock = NSLock(); private var value = true
    func revoke() { lock.lock(); value = false; lock.unlock() }
    var granted: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

@main struct AutomationReadChecks {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let records = ProcessDiscovery.parse("85001 1 ttys085 85001 85001 Mon Oct 5 09:00:01 2026 /private/fixture/codex")
        var session = ProcessDiscovery.sessions(records)[0]; session.terminal = .terminal
        let counter = ReadCounter()
        let capture = TerminalWindowCapture(permissions: { TerminalWindowPermissions(screen: false, keyboard: false, automation: false) },
            requestPermissions: { fatalError("A GET must never request a grant") }, metadata: { _ in fatalError("Denied Automation must not query metadata") }, capture: { _ in fatalError("Denied grants must not capture pixels") })
        let adapter = ScreenHostAdapter(screens: { targets in
            counter.increment()
            return TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: "private legacy text") })
        }, approve: { _, _, _ in .missingTarget }, reveal: { _ in fatalError("A GET must never reveal any tab") })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { records }, screenAdapters: [.terminal: adapter], terminalWindowCapture: capture)
        defer { engine.stop() }
        engine.updateDiscovery([session], records: records); await engine.connectTerminal()
        let baseline = counter.count
        let frame = try await engine.remoteTerminal(sessionID: session.id, realtime: true, renderWindow: true)
        guard counter.count == baseline else { throw AppError.message("GET must not run the legacy Apple-event reader when nonprompt Automation preflight is denied") }
        guard frame.nativeDisplay?.state == .permissionRequired, frame.screen.isEmpty, frame.keys.isEmpty,
              frame.inputReason != nil else { throw AppError.message("Automation-denied original frame must be explicit, empty and read-only") }
        let grant = AutomationGrant()
        let revokingCapture = TerminalWindowCapture(permissions: { TerminalWindowPermissions(screen: true, keyboard: true, automation: grant.granted) },
            requestPermissions: { fatalError("A GET must never request a grant") },
            metadata: { tty in TerminalWindowMetadata(tty: tty, windowID: 91, ownerPID: 900, ownerBundleID: "com.apple.Terminal", selected: true, minimized: false) },
            capture: { _ in grant.revoke(); return TerminalNativeImage(data: "invalid-private-JPEG", width: 4, height: 4) })
        let pending = try ApprovalEngine(paths: AppPaths(directory: directory.appendingPathComponent("revoked")), processReader: { records }, screenAdapters: [.terminal: adapter], terminalWindowCapture: revokingCapture)
        defer { pending.stop() }
        pending.updateDiscovery([session], records: records); await pending.connectTerminal()
        let beforePending = counter.count
        let revoked = try await pending.remoteTerminal(sessionID: session.id, realtime: true, renderWindow: true)
        guard counter.count == beforePending, revoked.nativeDisplay?.state == .permissionRequired, revoked.screen.isEmpty,
              revoked.keys.isEmpty else { throw AppError.message("Automation revoked during native capture must be rechecked before legacy read") }

        let screenOnly = TerminalWindowCapture(permissions: { TerminalWindowPermissions(screen: false, keyboard: false, automation: true) },
            requestPermissions: { fatalError("A GET must never request a grant") }, metadata: { _ in fatalError("Missing screen grant must not query metadata") }, capture: { _ in fatalError("Missing screen grant must not capture pixels") })
        let textFallback = try ApprovalEngine(paths: AppPaths(directory: directory.appendingPathComponent("screen-only")), processReader: { records }, screenAdapters: [.terminal: adapter], terminalWindowCapture: screenOnly)
        defer { textFallback.stop() }
        textFallback.updateDiscovery([session], records: records); await textFallback.connectTerminal()
        let basic = try await textFallback.remoteTerminal(sessionID: session.id, realtime: true, renderWindow: true)
        guard basic.screen == "private legacy text", basic.keys.contains("text"), basic.keys.contains("submit"), basic.inputReason == nil else {
            throw AppError.message("Only missing screen/keyboard grants must preserve safe legacy text/compose")
        }
        print("Automation GET boundaries PASS: denied, revoked-during-capture, screen-only basic fallback")
    }
}
