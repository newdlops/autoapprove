// Private direct-key delivery checks. No real windows, TCC requests or event posts.
import Foundation
import JavaScriptCore
#if !TERMINAL_KEYBOARD_ISOLATED
import AutoApproveCore
#endif
import CoreGraphics
import ApplicationServices

private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw AppError.message(message) }
}

private func preparationContext() -> JSContext {
        let context = JSContext()!
        context.evaluateScript("""
        var childAXChecks = 0, systemEvents = 0, writes = [], front = true, wrongTab = false, changed = false, processes = ['codex'];
        var ObjC = {import:()=>{}}; var $ = {AXIsProcessTrusted:()=>{childAXChecks++; return false;}};
        var tab = {tty:()=>'/dev/ttys081', contents:()=>changed ? 'changed' : 'screen', processes:()=>processes};
        var win = {id:()=>96, tabs:()=>[tab]};
        Object.defineProperty(win, 'selectedTab', {set:()=>{}, get:()=>()=>wrongTab ? {tty:()=>'/dev/other'} : tab});
        function Application(id) {
          if (id === 'com.apple.systemevents') { systemEvents++; throw Error('System Events must never receive a command'); }
          return {running:()=>true, windows:()=>[win], frontmost:()=>front, activate:()=>{}, doScript:text=>writes.push(text)};
        }
        """)
    return context
}

#if !KEYBOARD_PREFLIGHT_ONLY
private final class NativeProbe: @unchecked Sendable {
    enum Fault: CaseIterable { case sourceStart, sourceExit, sourceTTY, sourceForeground, sourceParent, ownerStart, ownerBundle, windowID, windowOwner, selected, minimized, windowTTY, focus, focusRole, permission, posting, cancelled, deadline }
    struct Pair {
        let pid: Int32
        let down: CGEventType, up: CGEventType
        let key: Int64, downFlags: UInt64, upFlags: UInt64
        let text: String, units: [UniChar], releaseText: String
    }
    private let lock = NSLock()
    var records = ProcessDiscovery.parse("""
    81000 1 ?? 81000 0 Mon Oct 5 09:00:00 2026 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
    81001 81000 ttys081 81001 81001 Mon Oct 5 09:00:01 2026 /private/fixture/codex
    """)
    var window = TerminalWindowMetadata(tty: "/dev/ttys081", windowID: 96, ownerPID: 81000, ownerBundleID: "com.apple.Terminal", selected: true, minimized: false)
    var trusted = true, posting = true, focused = true, cancelled = false, ownerBundle = "com.apple.Terminal", now: TimeInterval = 0
    var focusedRole = kAXTextAreaRole
    var metadataReads = 0, prepares = 0, faultAt = 0, fault: Fault?, throwPairAt = 0
    var pairs = [Pair]()
    func read<T>(_ body: (NativeProbe) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(self) }
    func mutate(_ body: (NativeProbe) -> Void) { lock.lock(); defer { lock.unlock() }; body(self) }
    var target: ScreenTarget { read { ScreenTarget(tty: "/dev/ttys081", jobPIDs: [81001], sourcePID: 81001, sourceStarted: $0.records[1].started) } }
    func metadata(_ tty: String) -> TerminalWindowMetadata? {
        lock.lock(); defer { lock.unlock() }
        metadataReads += 1
        if metadataReads == faultAt, let fault {
            switch fault {
            case .sourceStart: records[1].started = "replaced original"
            case .sourceExit: records.remove(at: 1)
            case .sourceTTY: records[1].tty = "ttys999"
            case .sourceForeground: records[1].foregroundGroup = 99
            case .sourceParent: records[1].parent = 99
            case .ownerStart: records[0].started = "replaced owner"
            case .ownerBundle: ownerBundle = "other.owner"
            case .windowID: window.windowID = 97
            case .windowOwner: window.ownerPID = 999
            case .selected: window.selected = false
            case .minimized: window.minimized = true
            case .windowTTY: window.tty = "/dev/ttys999"
            case .focus: focused = false
            case .focusRole: focusedRole = kAXTextFieldRole
            case .permission: trusted = false
            case .posting: posting = false
            case .cancelled: cancelled = true
            case .deadline: now = 10
            }
        }
        return window
    }
    func submit(_ pid: Int32, _ down: CGEvent, _ up: CGEvent) throws {
        func unicode(_ event: CGEvent) -> [UniChar] {
            var units = [UniChar](repeating: 0, count: 32), length = 0
            event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
            return Array(units.prefix(length))
        }
        let units = unicode(down), released = unicode(up)
        let pair = Pair(pid: pid, down: down.type, up: up.type, key: down.getIntegerValueField(.keyboardEventKeycode),
            downFlags: down.flags.rawValue, upFlags: up.flags.rawValue, text: String(decoding: units, as: UTF16.self), units: units,
            releaseText: String(decoding: released, as: UTF16.self))
        let fail = read { $0.pairs.count + 1 == $0.throwPairAt }
        mutate { $0.pairs.append(pair) }
        if fail { throw AppError.message("Private paired submission outcome unavailable") }
    }
    var environment: TerminalKeyboard.Environment {
        TerminalKeyboard.Environment(trusted: { self.read { $0.trusted } }, postingAllowed: { self.read { $0.posting } }, run: { script in
            self.mutate { $0.prepares += 1 }
            let context = preparationContext()
            if self.read({ $0.records.last?.agent == .claude }) { context.evaluateScript("processes = ['claude'];") }
            let value = context.evaluateScript(script)?.toString()
            guard context.exception == nil, let value else { throw AppError.message("Private JXA preflight failed") }
            try require(context.evaluateScript("childAXChecks + systemEvents + writes.length")?.toInt32() == 0,
                "Native delivery must not depend on child AX/System Events or make JXA input writes")
            return value
        }, metadata: { self.metadata($0) }, ownerBundle: { _ in self.read { $0.ownerBundle } }, focused: { _ in self.read { $0.focused && $0.focusedRole == kAXTextAreaRole } },
           processes: { self.read { $0.records } }, postPair: { try self.submit($0, $1, $2) }, clock: { self.read { $0.now } }, cancelled: { self.read { $0.cancelled } })
    }
}
#endif

@main struct TerminalKeyboardChecks {
    @MainActor static func main() async throws {
        let context = preparationContext()
        let target = ScreenTarget(tty: "/dev/ttys081", jobPIDs: [81001])
        let input = RemoteTerminalInput(kind: .characters, text: "한글 🧪", relay: true)
        let script = try RemoteTerminalAdapter.script(host: .terminal, target: target, expected: "screen", agent: .codex, input: input)
        let prepared = context.evaluateScript(script)?.toString()
        try require(prepared == "ready:96" && context.exception == nil,
            "Direct-key preflight must identify the exact window without requiring child AX or System Events")
        try require(context.evaluateScript("childAXChecks + systemEvents + writes.length")?.toInt32() == 0,
            "JXA direct-key preflight must never check child AX, send System Events commands or write terminal input")
        context.evaluateScript("wrongTab = true;")
        try require(context.evaluateScript(script)?.toString() == "missingTarget", "Another selected TTY must fail before native delivery")
        context.evaluateScript("wrongTab = false; front = false;")
        try require(context.evaluateScript(script)?.toString() == "missingTarget", "Unfocused exact window must fail before native delivery")
        var checks = ["exact original JXA preparation uses no child AX, System Events or terminal writes"]
#if !KEYBOARD_PREFLIGHT_ONLY
        let unicode = NativeProbe(), text = "한글 🧪 e\u{301} " + String(repeating: "a", count: 19) + "🧪" + String(repeating: "끝", count: 30)
        let unicodeInput = RemoteTerminalInput(kind: .characters, text: text, relay: true)
        try require(try TerminalKeyboard.deliver(target: unicode.target, expected: "screen", agent: .codex, input: unicodeInput, environment: unicode.environment) == .sent,
            "Original Unicode must be submitted by the native sender")
        let unicodePairs = unicode.read { $0.pairs }
        try require(unicodePairs.count > 1 && unicodePairs.map(\.text).joined() == text.precomposedStringWithCanonicalMapping,
            "Unicode chunks must preserve the original composed text exactly once")
        try require(unicodePairs.allSatisfy { $0.pid == 81000 && $0.down == .keyDown && $0.up == .keyUp && $0.units.count <= 20 && $0.text == $0.releaseText
            && !$0.units.first.map({ (0xdc00...0xdfff).contains($0) })! && !$0.units.last.map({ (0xd800...0xdbff).contains($0) })!
            && $0.downFlags == 0 && $0.upFlags == 0 }, "Every Unicode pair must target only the exact owner and keep complete surrogate sequences without modifiers")
        checks.append("bounded Unicode down/up pairs target only the original owner, with no surrogate cuts or modifier leakage")

        let special = NativeProbe()
        let keyCodes: [(RemoteTerminalInput.Kind, Int64)] = [(.enter,36),(.escape,53),(.interrupt,8),(.up,126),(.down,125),(.left,123),(.right,124),(.backspace,51),(.delete,117),(.home,115),(.end,119),(.tab,48)]
        for (kind, code) in keyCodes {
            try require(try TerminalKeyboard.deliver(target: special.target, expected: "screen", agent: .codex,
                input: RemoteTerminalInput(kind: kind, relay: true), environment: special.environment) == .sent, "Native special key must be submitted")
            let pair = special.read { $0.pairs.last! }
            try require(pair.pid == 81000 && pair.key == code && pair.down == .keyDown && pair.up == .keyUp
                && pair.downFlags == (kind == .interrupt ? CGEventFlags.maskControl.rawValue : 0) && pair.upFlags == 0,
                "Special keys must use explicit virtual keys and release modifiers in the same complete pair")
        }
        try require(special.read({ $0.pairs.count }) == keyCodes.count, "Every special input must submit exactly one pair")
        let claude = NativeProbe(); claude.mutate { $0.records[1].executable = "/private/fixture/claude" }
        try require(try TerminalKeyboard.deliver(target: claude.target, expected: "screen", agent: .claude,
            input: .init(kind: .left, relay: true), environment: claude.environment) == .sent, "The original Claude foreground job must use the same exact native route")
        checks.append("all special keys and both CLI kinds use one explicit owner-bound pair, with Control only on interrupt keydown")

        for postingOnly in [false, true] {
            let blocked = NativeProbe(); blocked.mutate { if postingOnly { $0.posting = false } else { $0.trusted = false } }
            do { _ = try TerminalKeyboard.deliver(target: blocked.target, expected: "screen", agent: .codex, input: unicodeInput, environment: blocked.environment)
                throw AppError.message("Missing current-process permission must reject native delivery") }
            catch let error as RemoteHTTPError { try require(error.status == 409, "Permission refusal must be409") }
            try require(blocked.read { $0.pairs.isEmpty && $0.prepares == 0 }, "Permission denial must make zero preparation calls or posts")
        }
        for missing in ["pid", "start", "job", "tty"] {
            let blocked = NativeProbe(); var invalid = blocked.target
            switch missing { case "pid": invalid.sourcePID = nil; case "start": invalid.sourceStarted = "replaced"; case "job": invalid.jobPIDs = [999]; default: invalid.tty = "/dev/ttys999" }
            try require(try TerminalKeyboard.deliver(target: invalid, expected: "screen", agent: .codex, input: unicodeInput, environment: blocked.environment) == .agentMissing,
                "Exact original source fields must match the positive foreground job on the original TTY")
            try require(blocked.read { $0.pairs.isEmpty && $0.prepares == 0 }, "Unbound source must fail before any reveal or post")
        }
        checks.append("current app permissions and exact PID/start/job/TTY are mandatory before preparation or input")

        for fault in NativeProbe.Fault.allCases {
            let changed = NativeProbe(); changed.mutate { $0.fault = fault; $0.faultAt = 2 }
            do { _ = try TerminalKeyboard.deliver(target: changed.target, expected: "screen", agent: .codex, input: unicodeInput, environment: changed.environment)
                throw AppError.message("A changed source/window/permission must reject its first pair: \(fault)") }
            catch is RemoteHTTPError {} catch is CancellationError {}
            try require(changed.read { $0.pairs.isEmpty }, "Identity/focus/permission/cancellation/deadline changes must make zero posts: \(fault)")
        }
        checks.append("every pair rechecks selected window, owner, original source, foreground job, permission, deadline and cancellation")

        for fault in NativeProbe.Fault.allCases {
            let partial = NativeProbe(); partial.mutate { $0.fault = fault; $0.faultAt = 3 }
            do { _ = try TerminalKeyboard.deliver(target: partial.target, expected: "screen", agent: .codex, input: unicodeInput, environment: partial.environment)
                throw AppError.message("A changed later pair must stop: \(fault)") }
            catch let error as RemoteHTTPError {
                try require(error.status == 409 && error.message.contains("전달되었을 수") && error.message.contains("다시 보내지"),
                    "Any outcome after a submitted pair must be explicitly uncertain and never recommend replay")
            }
            try require(partial.read { $0.pairs.count == 1 }, "Later failure must keep the original complete pair and stop further submissions")
        }
        let uncertain = NativeProbe(); uncertain.mutate { $0.throwPairAt = 1 }
        do { _ = try TerminalKeyboard.deliver(target: uncertain.target, expected: "screen", agent: .codex, input: unicodeInput, environment: uncertain.environment)
            throw AppError.message("A throwing paired submission cannot be called definitely unsent") }
        catch let error as RemoteHTTPError { try require(error.message.contains("전달되었을 수"), "Submission callback failure must remain uncertain") }
        try require(uncertain.read { $0.pairs.count == 1 }, "An uncertain pair must never be automatically retried")
        checks.append("later identity/permission/deadline/cancel failures and submission errors report uncertain delivery without retry")
#if !TERMINAL_KEYBOARD_ISOLATED
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("autoapprove-native-receipt-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let receiptProbe = NativeProbe(), receiptRecords = receiptProbe.read { $0.records }
        let adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: "screen") }) },
            approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, input: { target, expected, agent, input in
                try TerminalKeyboard.deliver(target: target, expected: expected, agent: agent, input: input, environment: receiptProbe.environment)
            })
        let capture = TerminalWindowCapture(permissions: { TerminalWindowPermissions(screen: false, keyboard: true, automation: true) },
            requestPermissions: {}, metadata: { _ in throw AppError.message("Ordinary native input must not inspect a screen capture") },
            capture: { _ in throw AppError.message("Ordinary native input must not capture pixels") })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { receiptRecords }, screenAdapters: [.terminal: adapter], terminalWindowCapture: capture)
        defer { engine.stop() }
        let session = ProcessDiscovery.sessions(receiptRecords)[0]
        engine.updateDiscovery([session], records: receiptRecords); await engine.connectTerminal()
        let frame = try await engine.remoteTerminal(sessionID: session.id, realtime: true)
        let network = RemoteNetworkService(engine: engine, nodeID: UUID().uuidString, onStatus: { _ in })
        let body: JSONObject = ["requestID": UUID().uuidString, "sessionID": session.id, "revision": frame.revision, "streamID": frame.streamID!, "relay": true, "kind": "characters", "text": "한글 original"]
        let data = try JSONSerialization.data(withJSONObject: body)
        let request = try RemoteHTTPRequest.parse(Data("POST /api/input HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\n\r\n".utf8) + data)!
        let first = await network.handle(request), repeatRequest = await network.handle(request)
        try require(first.status == 200 && repeatRequest.status == 200 && receiptProbe.read({ $0.pairs.count }) == 1,
            "The real original HTTP route must carry exact PID/start/TTY into native delivery and receipt duplicates must not replay it")
        try require(engine.managedPTY.inventory.isEmpty && engine.snapshot.sessions[0].pid == session.pid && engine.snapshot.sessions[0].tty == session.tty,
            "Native original input must keep the same CLI/TTY and create no PTY")
        checks.append("original HTTP receipts deliver the exact source once with no window capture or CLI/PTY creation")
#endif
#endif
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["checks": checks, "actualEventPosts": 0, "realPermissionPrompts": 0, "ownedPTYCreations": 0]), as: UTF8.self))
    }
}
