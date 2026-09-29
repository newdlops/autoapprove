import Foundation
import JavaScriptCore
import AutoApproveCore

private func procargs(argv: [String], environment: [String]) -> [UInt8] {
    var bytes = withUnsafeBytes(of: Int32(argv.count)) { Array($0) }
    bytes += Array("/usr/local/bin/codex".utf8) + [0, 0, 0, 0]
    for value in argv + environment { bytes += Array(value.utf8) + [0] }
    return bytes + [0] + Array("ptr_munge=".utf8) + [0]
}

private func host(_ environment: [String: String], ancestry: String = """
    1 0 ?? 1 0 Mon Sep 21 09:00:00 2026 /sbin/launchd
    10 1 ?? 10 0 Mon Sep 21 09:00:01 2026 /Applications/Unknown.app/Contents/MacOS/Unknown
    11 10 ttys001 11 12 Mon Sep 21 09:00:02 2026 /bin/zsh
    """) -> AgentSession? {
    let records = ProcessDiscovery.parse(ancestry + "\n12 11 ttys001 12 12 Mon Sep 21 09:00:03 2026 /usr/local/bin/codex")
    return ProcessDiscovery.sessions(records, environment: { $0.pid == 12 ? environment : nil }).first
}

extension ApprovalTests {
    func testLaunchEnvironmentKeepsOnlyTerminalIdentity() throws {
        let bytes = procargs(argv: ["codex", "TERM_PROGRAM=argument"], environment: [
            "HOME=/Users/fixture", "TERM_PROGRAM=iTerm.app", "ORCA_AGENT_HOOK_TOKEN=secret", "ORCA_TERMINAL_HANDLE=term_1", "ITERM_SESSION_ID=w0t0p0:ABC"
        ])
        let parsed = ProcessEnvironment.parse(bytes)
        try expectEqual(parsed, ["TERM_PROGRAM": "iTerm.app", "ORCA_TERMINAL_HANDLE": "term_1", "ITERM_SESSION_ID": "w0t0p0:ABC"],
            "Arguments and unlisted variables, including tokens, never leave the parser")
        try expectEqual(ProcessEnvironment.parse([1, 0]), [:])
        try expectEqual(ProcessEnvironment.parse(procargs(argv: [], environment: [])), [:])
        // A PID that no longer matches the scanned start time never lends its environment.
        let own = try ProcessDiscovery.read().first { $0.pid == getpid() }
        try expectNotNil(own)
        try expectNotNil(ProcessEnvironment.read(own!), "The checks process can read its own launch variables")
        var reused = own!; reused.started = "Mon Sep 21 09:00:03 2026"
        try expectNil(ProcessEnvironment.read(reused))
        reused.started = "fixture"
        try expectNil(ProcessEnvironment.read(reused))
    }

    func testTerminalHostIdentification() throws {
        let iterm = host(["TERM_PROGRAM": "iTerm.app", "__CFBundleIdentifier": "com.googlecode.iterm2", "ITERM_SESSION_ID": "w0t0p0:1"])
        try expectEqual(iterm?.terminal, .iterm); try expectEqual(iterm?.hostTitle, "iTerm2")
        let server = host([:], ancestry: """
        1 0 ?? 1 0 Mon Sep 21 09:00:00 2026 /sbin/launchd
        10 1 ?? 10 0 Mon Sep 21 09:00:01 2026 /Users/fixture/Library/Application Support/iTerm2/iTermServer-3.7.3
        11 10 ttys001 11 12 Mon Sep 21 09:00:02 2026 /bin/zsh
        """)
        try expectEqual(server?.terminal, .iterm, "iTermServer reparents shells away from iTerm.app")
        let orca = host(["TERM_PROGRAM": "Orca", "ORCA_TERMINAL_HANDLE": "term_a", "__CFBundleIdentifier": "com.stablyai.orca"])
        try expectEqual(orca?.terminal, .orca); try expectEqual(orca?.orcaHandle, "term_a"); try expect(orca?.canReveal == true)
        let dropped = host(["ORCA_TERMINAL_HANDLE": "term_b", "__CFBundleIdentifier": "com.stablyai.orca"])
        try expectEqual(dropped?.terminal, .orca, "Orca can drop TERM_PROGRAM but keeps its pane handle")
        let unaddressable = host(["TERM_PROGRAM": "Orca"])
        try expectEqual(unaddressable?.terminal, .unknown); try expectEqual(unaddressable?.hostTitle, "Orca")
        try expectFalse(unaddressable?.canReveal == true, "A pane without its handle cannot be targeted")
        let tmux = host(["TMUX": "/private/tmp/tmux-501/default,1,0", "TERM_PROGRAM": "tmux", "ITERM_SESSION_ID": "w0t0p0:1", "ORCA_TERMINAL_HANDLE": "term_c"])
        try expectEqual(tmux?.terminal, .unknown, "Host input into a multiplexer could reach another pane")
        try expectEqual(tmux?.hostTitle, "tmux"); try expectNil(tmux?.orcaHandle)
        let cursor = host(["TERM_PROGRAM": "vscode", "__CFBundleIdentifier": "com.todesktop.230313mzl4w4u92"])
        try expectEqual(cursor?.terminal, .unknown, "A variable alone never makes a session a VS Code target"); try expectEqual(cursor?.hostTitle, "Cursor")
        try expectFalse(cursor?.canReveal == true)
        try expectEqual(host(["TERM_PROGRAM": "Apple_Terminal", "__CFBundleIdentifier": "com.apple.Terminal"])?.terminal, .unknown,
            "Without Terminal.app in the ancestry the tab is unproven")
        let warp = host(["TERM_PROGRAM": "WarpTerminal", "__CFBundleIdentifier": "dev.warp.Warp-Stable"])
        try expectEqual(warp?.terminal, .unknown); try expectEqual(warp?.hostTitle, "Warp"); try expectEqual(warp?.hostBundleID, "dev.warp.Warp-Stable")
        let bundleOnly = host(["__CFBundleIdentifier": "com.example.Shell"])
        try expectEqual(bundleOnly?.hostTitle, "com.example.Shell")
        try expectEqual(host([:])?.hostTitle, "터미널 미확인")
        let terminal = host(["TERM_PROGRAM": "iTerm.app"], ancestry: """
        1 0 ?? 1 0 Mon Sep 21 09:00:00 2026 /sbin/launchd
        10 1 ?? 10 0 Mon Sep 21 09:00:01 2026 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
        11 10 ttys001 11 12 Mon Sep 21 09:00:02 2026 -zsh
        """)
        try expectEqual(terminal?.terminal, .terminal, "Ancestry outranks an inherited variable")
        var reads = 0
        let chained = ProcessDiscovery.parse("""
        1 0 ?? 1 0 Mon Sep 21 09:00:00 2026 /sbin/launchd
        10 1 ?? 10 0 Mon Sep 21 09:00:01 2026 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
        11 10 ttys001 11 12 Mon Sep 21 09:00:02 2026 -zsh
        12 11 ttys001 12 12 Mon Sep 21 09:00:03 2026 /usr/local/bin/codex
        20 1 ?? 20 0 Mon Sep 21 09:00:04 2026 /Applications/Visual Studio Code.app/Contents/MacOS/Code
        21 20 ttys002 21 22 Mon Sep 21 09:00:05 2026 /bin/zsh
        22 21 ttys002 22 22 Mon Sep 21 09:00:06 2026 claude
        """)
        let existing = ProcessDiscovery.sessions(chained, environment: { _ in reads += 1; return ["TERM_PROGRAM": "iTerm.app", "ORCA_TERMINAL_HANDLE": "term_x"] })
        try expectEqual(existing.map(\.terminal), [.terminal, .vscode])
        try expectEqual(reads, 0, "Terminal and VS Code sessions never read launch variables")
        let nested = host(["TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w0t0p0:1"], ancestry: """
        1 0 ?? 1 0 Mon Sep 21 09:00:00 2026 /sbin/launchd
        9 1 ttys000 9 9 Mon Sep 21 09:00:00 2026 /usr/bin/script
        11 9 ttys001 11 12 Mon Sep 21 09:00:02 2026 /bin/zsh
        """)
        try expectEqual(nested?.terminal, .unknown, "A PTY opened inside another session is not the host's tab")
    }

    func testITermScriptingContract() throws {
        let context = JSContext()!
        // JavaScriptCore mock of iTerm2.sdef: sessions report scrollback plus the visible rows, padded with a space.
        context.evaluateScript("""
        var writes = [], selected = [], activated = 0, job = '42';
        var screen = 'old scrollback \\nWould you like to run the following command? \\n \\n  $ npm test \\n \\n› 1. Yes, proceed (y) \\n  2. No (esc) \\n \\nPress enter to confirm or esc to cancel \\n \\n';
        var target = {tty: () => '/dev/ttys042', rows: () => 9, contents: () => screen, name: () => 'codex',
          variable: (options) => options.named === 'jobPid' ? job : '', write: (options) => writes.push(options.text), select: () => selected.push('session')};
        var tab = {sessions: () => [{tty: () => { throw Error('closed session (-1728)'); }}, {tty: () => '/dev/ttys001', contents: () => { throw Error('must not read unrelated session'); }}, target],
          select: () => selected.push('tab')};
        var window = {tabs: () => [tab], miniaturized: true, select: () => selected.push('window'), bounds: () => ({x: 10, y: 20, width: 800, height: 600})};
        function Application(id) { return {running: () => true, windows: () => [{tabs: () => { throw Error('closed window (-1728)'); }}, window], activate: () => { activated++; }}; }
        """)
        let value = context.evaluateScript(try ITermAdapter.screenScript(ttys: ["/dev/ttys042"]))
        try expectNil(context.exception)
        let result = try JSONDecoder().decode(TerminalSnapshot.self, from: Data(value!.toString().utf8))
        try expectEqual(result.screens.count, 1); try expectEqual(result.failures.count, 2)
        let visible = result.screens[0].contents
        try expectFalse(visible.contains("old scrollback"), "Only the visible rows are a screen")
        try expectFalse(visible.split(separator: "\n").contains { $0.hasSuffix(" ") }, "Row padding is removed")
        try expectEqual(result.screens[0].title, "codex")
        let prompt = PromptDetector.detect(visible, agent: .codex)
        try expectNotNil(prompt)
        func approve(_ pids: [Int32] = [42, 41], tty: String = "/dev/ttys042") throws -> String? {
            context.evaluateScript(try ITermAdapter.approvalScript(target: ScreenTarget(tty: tty, jobPIDs: pids), expectedScreen: visible, agent: .codex))?.toString()
        }
        try expectEqual(try approve(), "sent")
        try expectEqual(context.evaluateScript("writes.join(',')")?.toString(), "1")
        try expectEqual(try approve([7]), "agentMissing", "A different foreground job must not receive the answer")
        context.evaluateScript("job = ''")
        try expectEqual(try approve([7]), "sent", "Without a reported job the dialog check still applies")
        try expectEqual(try approve(tty: "/dev/other"), "missingTarget")
        context.evaluateScript("screen = screen.replace('npm test', 'rm -rf build')")
        try expectEqual(try approve(), "screenChanged")
        try expectEqual(context.evaluateScript("writes.length")?.toInt32(), 2)
        let bounds = context.evaluateScript(try ITermAdapter.revealScript(tty: "/dev/ttys042"))
        try expectNil(context.exception)
        let frame = try JSONDecoder().decode(TerminalWindowBounds.self, from: Data(bounds!.toString().utf8))
        try expectEqual(frame.width, 800)
        try expectEqual(context.evaluateScript("selected.join(',') + ':' + activated + ':' + window.miniaturized")?.toString(), "tab,session,window:1:false")
        context.evaluateScript(try ITermAdapter.revealScript(tty: "/dev/missing"))
        try expectNotNil(context.exception)
        let denied = JSContext()!
        denied.evaluateScript("function Application() { return {running: () => true, windows: () => [{tabs: () => { const error = Error('denied'); error.errorNumber = -1743; throw error; }}]}; }")
        denied.evaluateScript(try ITermAdapter.screenScript(ttys: ["/dev/ttys042"]))
        try expect(denied.exception?.toString().contains("denied") == true, "Automation denial must not look like a closed tab")
    }

    func testOrcaCommandContract() throws {
        let ok = try OrcaAdapter.parse(#"{"id":"1","ok":true,"result":{"terminal":{"handle":"term_a","source":"screen","tail":["Do you want to proceed?","❯ 1. Yes","  2. No","Esc to cancel"]}}}"#)
        let screen = try OrcaAdapter.screen(from: ok)
        try expectNotNil(PromptDetector.detect(screen, agent: .claude), "Orca's rendered rows omit blank lines; the dialog still matches")
        try expectThrows(try OrcaAdapter.screen(from: ["terminal": ["source": "stream", "tail": ["Do you want to proceed?"]]]))
        do {
            _ = try OrcaAdapter.screen(from: ["terminal": ["source": "screen-unavailable", "tail": ["codex approved"]]])
            throw AppError.message("Stream fallback text must not be treated as a screen")
        } catch let error as OrcaAdapterError { try expect(error.localizedDescription.contains("screen_unavailable")) }
        do {
            _ = try OrcaAdapter.screen(from: ["terminal": ["tail": ["Do you want to proceed?"]]])
            throw AppError.message("A host without the source field predates screen reads")
        } catch let error as OrcaAdapterError { try expect(error.localizedDescription.contains("screen_unsupported")) }
        do {
            _ = try OrcaAdapter.parse(#"{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal_handle_stale"}}"#)
            throw AppError.message("A failed envelope must throw")
        } catch let error as OrcaAdapterError {
            try expectEqual(error, .cli(code: "terminal_handle_stale", message: "terminal_handle_stale"))
        }
        try expectThrows(try OrcaAdapter.parse("Orca is not running"))
        let codex = "Would you like to run the following command?\n  $ npm test\n› 1. Yes, proceed (y)\n  2. No (esc)\nPress enter to confirm or esc to cancel"
        let dialog = PromptDetector.detect(codex, agent: .codex)!.dialog
        try expectEqual(OrcaAdapter.activeDialog("history\n" + codex + "\n\n", dialog: dialog, agent: .codex), dialog)
        try expectNil(OrcaAdapter.activeDialog("history only", dialog: dialog, agent: .codex))
        try expect(OrcaAdapter.activeDialog(codex.replacingOccurrences(of: "npm test", with: "npm publish"), dialog: dialog, agent: .codex) != dialog)
        try expectEqual(try OrcaAdapter.approve(target: ScreenTarget(tty: "/dev/x"), expectedScreen: codex, agent: .codex), .missingTarget,
            "Without a handle Orca is never asked to write")
    }

    func testScreenHostConnectionsAreIndependent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-hosts-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let requests = HostRequestProbe()
        let prompt = "Would you like to run the following command?\n  $ npm test\n› 1. Yes, proceed (y)\n  2. No (esc)\nPress enter to confirm or esc to cancel"
        func adapter(_ host: ScreenHost) -> ScreenHostAdapter {
            ScreenHostAdapter(screens: { targets in
                requests.record(host, targets)
                return TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: prompt) })
            }, approve: { _, _, _ in .sent }, reveal: { _ in nil })
        }
        let adapters = Dictionary(uniqueKeysWithValues: [ScreenHost.iterm, .orca].map { ($0, adapter($0)) })
        let paths = AppPaths(directory: directory)
        let engine = try ApprovalEngine(paths: paths, terminalReader: { _ in throw AppError.message("Terminal is not connected in this check") }, screenAdapters: adapters)
        var iterm = AgentSession(id: "process:51:hosts", agent: .codex, pid: 51, started: "hosts", tty: "/dev/iterm-fixture", cwd: "/tmp/hosts", terminal: .iterm)
        iterm.hostName = "iTerm2"
        var orca = AgentSession(id: "process:52:hosts", agent: .codex, pid: 52, started: "hosts", tty: "/dev/orca-fixture", cwd: "/tmp/hosts", terminal: .orca)
        orca.orcaHandle = "term_fixture"
        engine.updateDiscovery([iterm, orca], records: [])
        await engine.refreshScreens()
        try expect(requests.hosts.isEmpty, "Never read a host the user has not connected")
        await engine.connectScreenHost(.iterm)
        try expectEqual(requests.hosts, [.iterm])
        var current = engine.snapshot.sessions.first { $0.id == iterm.id }!
        try expectEqual(current.channel, .itermScreen); try expectEqual(current.phase, .approval)
        try expectEqual(engine.snapshot.sessions.first { $0.id == orca.id }?.channel, ApprovalChannel.none, "Connecting iTerm2 does not connect Orca")
        try expect(engine.snapshot.health.screen(.iterm).connected); try expectFalse(engine.snapshot.health.terminalRequested)
        await engine.connectScreenHost(.orca)
        try expectEqual(requests.targets(.orca), [ScreenTarget(tty: "/dev/orca-fixture", handle: "term_fixture")], "Orca reads the pane named by the agent's handle")
        try expectEqual(engine.snapshot.sessions.first { $0.id == orca.id }?.channel, .orcaScreen)
        let restarted = try ApprovalEngine(paths: paths, terminalReader: { _ in TerminalSnapshot() }, screenAdapters: adapters)
        try expect(restarted.snapshot.health.screen(.iterm).requested && restarted.snapshot.health.screen(.orca).requested, "Connections restore after restart")
        try expectFalse(restarted.snapshot.health.terminalRequested)
        engine.disconnectScreenHost(.iterm)
        current = engine.snapshot.sessions.first { $0.id == iterm.id }!
        try expectEqual(current.channel, ApprovalChannel.none); try expectEqual(current.phase, .unknown)
        try expectEqual(engine.snapshot.sessions.first { $0.id == orca.id }?.channel, .orcaScreen, "Disconnecting one host leaves the other")
        let afterDisconnect = try ApprovalEngine(paths: paths, screenAdapters: adapters)
        try expectFalse(afterDisconnect.snapshot.health.screen(.iterm).requested)
        try expect(afterDisconnect.snapshot.health.screen(.orca).requested)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(engine.snapshot)) as! JSONObject
        var health = legacy["health"] as! JSONObject; health.removeValue(forKey: "screenHosts"); legacy["health"] = health
        let decoded = try JSONDecoder().decode(EngineSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        try expectEqual(decoded.health.screen(.orca), ScreenHostHealth(), "Older snapshots have no iTerm2 or Orca state")
    }
}

private final class HostRequestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(ScreenHost, [ScreenTarget])] = []
    func record(_ host: ScreenHost, _ targets: [ScreenTarget]) { lock.lock(); calls.append((host, targets)); lock.unlock() }
    var hosts: [ScreenHost] { lock.lock(); defer { lock.unlock() }; return calls.map(\.0) }
    func targets(_ host: ScreenHost) -> [ScreenTarget] { lock.lock(); defer { lock.unlock() }; return calls.last { $0.0 == host }?.1 ?? [] }
}
