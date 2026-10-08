import Foundation
import AutoApproveCore

/// macOS sleep as the tests see it: every change is recorded and shows up in later reads. Nothing here
/// reaches sudo or pmset.
private final class FakePower: @unchecked Sendable {
    private let lock = NSLock()
    private var state = PowerReading()
    private var installed = true
    private var file = true
    private var installFailure: String?
    private var failing = false
    private var log: (changes: [Bool], attempts: Int, sleeps: Int, reads: Int, installs: Int, removals: Int, floors: [Int], running: Bool) =
        ([], 0, 0, 0, 0, 0, [], false)
    private func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
    var reading: PowerReading { get { locked { state } } set { locked { state = newValue } } }
    var rule: Bool { get { locked { installed } } set { locked { installed = newValue } } }
    var ruleFile: Bool { get { locked { file } } set { locked { file = newValue } } }
    var installError: String? { get { locked { installFailure } } set { locked { installFailure = newValue } } }
    var failChanges: Bool { get { locked { failing } } set { locked { failing = newValue } } }
    var changes: [Bool] { locked { log.changes } }
    var attempts: Int { locked { log.attempts } }
    var sleeps: Int { locked { log.sleeps } }
    var reads: Int { locked { log.reads } }
    var installs: Int { locked { log.installs } }
    var removals: Int { locked { log.removals } }
    var guardFloors: [Int] { locked { log.floors } }
    var guardRunning: Bool { locked { log.running } }
    var control: PowerControl {
        PowerControl(
            read: { self.locked { self.log.reads += 1; return self.state } },
            ruleInstalled: { self.locked { self.installed } },
            ruleFile: { self.locked { self.file } },
            installRule: {
                try self.locked {
                    self.log.installs += 1
                    if let failure = self.installFailure { throw AppError.message(failure) }
                    self.installed = true; self.file = true
                }
            },
            removeRule: { self.locked { self.log.removals += 1; self.installed = false; self.file = false } },
            setSleepDisabled: { value in
                try self.locked {
                    self.log.attempts += 1
                    if self.failing { throw AppError.message("sudo: 실패") }
                    self.log.changes.append(value); self.state.sleepDisabled = value
                }
            },
            sleepNow: { self.locked { self.log.sleeps += 1 } },
            startGuard: { _, floor in
                self.locked { self.log.floors.append(floor); self.log.running = true }
                return KeepAwakeGuard(isRunning: { self.locked { self.log.running } }, stop: { self.locked { self.log.running = false } })
            })
    }
}

@MainActor private final class ManualClock { var now = Date(timeIntervalSince1970: 1_800_000_000) }

private func codexScreen(_ rows: [Int: String]) -> String { (0..<30).map { rows[$0] ?? "" }.joined(separator: "\n") }
private let workingScreen = codexScreen([1: "  >_ OpenAI Codex (v0.158.0)", 7: "› 테스트를 고치자.", 20: "• Working (12s • esc to interrupt)",
    26: "› Ask Codex to do anything", 28: "  gpt-5.5 high · ~/project/demo"])
private let idleScreen = codexScreen([1: "  >_ OpenAI Codex (v0.158.0)", 7: "› 테스트를 고치자.", 12: "• 테스트를 모두 고쳤습니다.",
    26: "› Ask Codex to do anything", 28: "  gpt-5.5 high · ~/project/demo", 29: "  ← for agents · ? for shortcuts"])

private func waitUntil(_ seconds: Double = 20, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if condition() { return true }; Thread.sleep(forTimeInterval: 0.05) }
    return condition()
}

extension ApprovalTests {
    @MainActor func testMouseActivityIndependentAndRestored() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-mouse-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let power = FakePower(), mouse = FakeMouseActivity(), paths = AppPaths(directory: directory)
        power.reading = PowerReading(onBattery: true, batteryPercent: 1, thermal: .critical)
        let engine = try ApprovalEngine(paths: paths, powerControl: power.control, mouseActivityControl: mouse.control)
        try engine.setPaused(true)
        try expectEqual(engine.snapshot.sessions.count, 0)
        // The setting is independent of work, the global approval pause, battery and temperature.
        let reply = try await engine.remoteAction(["action": "mouseActivity", "enabled": true])
        try expect((reply["mouseActivity"] as? JSONObject)?["enabled"] as? Bool == true)
        mouse.now += 60; engine.evaluateMouseActivity(); try expectEqual(mouse.pulses.count, 1)
        try expectEqual(power.reads, 0); try expectEqual(power.changes, [])
        engine.stop(); mouse.now += 60; engine.evaluateMouseActivity(); try expectEqual(mouse.pulses.count, 1)
        let restored = try ApprovalEngine(paths: paths, powerControl: power.control, mouseActivityControl: mouse.control)
        try expectEqual(restored.snapshot.mouseActivity?.enabled, true)
        mouse.now += 60; restored.evaluateMouseActivity(); try expectEqual(mouse.pulses.count, 2)
        try expectEqual(restored.snapshot.paused, true)
        try restored.setMouseActivity(false); mouse.now += 60; restored.evaluateMouseActivity()
        try expectEqual(mouse.pulses.count, 2)
        restored.stop()
        let off = try ApprovalEngine(paths: paths, powerControl: power.control, mouseActivityControl: mouse.control)
        try expectEqual(off.snapshot.mouseActivity?.enabled, false)
        off.stop(); try expectEqual(mouse.requests, 0)
    }

    func testKeepAwakeWorkingSessions() throws {
        func session(_ phase: SessionPhase, automatic: Bool = true, agent: AgentKind = .codex, _ change: (inout AgentSession) -> Void = { _ in }) -> AgentSession {
            var value = AgentSession(id: UUID().uuidString, agent: agent, pid: 1, started: "", tty: "/dev/ttys1", cwd: "/tmp/demo", terminal: .terminal)
            value.phase = phase; value.automatic = automatic; value.channel = .terminalScreen
            change(&value)
            return value
        }
        func count(_ sessions: [AgentSession], paused: Bool = false) -> Int { KeepAwake.working(sessions, paused: paused).count }
        try expectEqual(count([session(.working)]), 1)
        try expectEqual(count([session(.working, automatic: false)]), 0, "A manual session stops at its next approval")
        try expectEqual(count([session(.working)], paused: true), 0)
        try expectEqual(count([session(.working, agent: .shell)]), 0)
        try expectEqual(count([session(.approval)]), 1, "An approval AutoApprove answers is about to continue")
        try expectEqual(count([session(.approval) { $0.pendingSummary = "rm -rf build"; $0.pendingInTerminal = true }]), 0,
            "An approval left for the user waits for them")
        try expectEqual(count([session(.unknown), session(.idle), session(.input), session(.ended)]), 0)
        try expectEqual(count([session(.idle) { $0.backgroundMonitoring = true }]), 0, "Background jobs alone wait for the next message")
        for phase in [CapacityResume.Phase.scheduled, .sending, .awaiting] {
            try expectEqual(count([session(.idle) { $0.capacityResume = CapacityResume(phase: phase, attempt: 1, limit: 5) }]), 1, "capacity \(phase)")
        }
        for phase in [CapacityResume.Phase.paused, .unavailable, .review, .exhausted, .cancelled] {
            try expectEqual(count([session(.idle) { $0.capacityResume = CapacityResume(phase: phase, attempt: 1, limit: 5) }]), 0, "capacity \(phase)")
        }
        try expectEqual(count([session(.idle) { $0.backgroundSessions = [session(.working, automatic: false)] }]), 1,
            "A background agent works under its main's switch")
    }

    func testKeepAwakeHoldsWhileWorkRemains() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-keep-awake-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = ProcessDiscovery.parse("43 1 ttys902 43 43 Mon Sep 21 09:00:00 2026 /usr/local/bin/codex")[0]
        let clock = ManualClock()
        func makeEngine(_ power: FakePower, home: URL) throws -> (ApprovalEngine, String) {
            let adapter = ScreenHostAdapter(screens: { _ in TerminalSnapshot() }, approve: { _, _, _ in .sent }, reveal: { _ in nil })
            let engine = try ApprovalEngine(paths: AppPaths(directory: home), processReader: { [record] },
                screenAdapters: [.terminal: adapter], powerControl: power.control)
            engine.keepAwakeClock = { clock.now }
            var session = AgentSession(id: record.key, agent: .codex, pid: 43, started: record.started, tty: "/dev/ttys902", cwd: "/tmp/keep-awake", terminal: .terminal)
            session.channel = .terminalScreen
            engine.updateDiscovery([session], records: [record])
            return (engine, session.id)
        }
        let home = directory.appendingPathComponent("home")
        let marker = home.appendingPathComponent("keep-awake.hold").path
        func held() -> Bool { FileManager.default.fileExists(atPath: marker) }
        var power = FakePower()
        var (engine, id) = try makeEngine(power, home: home)
        func show(_ screen: String) { engine.receiveScreen(sessionID: id, raw: screen, generation: "terminal:\(id)", at: clock.now) }
        func finish() { show(idleScreen); clock.now += 2.5; show(idleScreen) }
        func pass(_ seconds: TimeInterval = 0) async { clock.now += seconds; await engine.evaluateKeepAwake() }
        func phase() -> KeepAwakeStatus.Phase? { engine.snapshot.keepAwake?.phase }

        // Off: macOS sleep is neither read nor changed.
        show(workingScreen)
        await pass()
        try expectEqual(power.reads, 0); try expectEqual(power.attempts, 0); try expectEqual(phase(), .off)

        // On with the rule in place: no password, and a manual session keeps nothing awake.
        try await engine.setKeepAwake(true)
        try expectEqual(power.installs, 0); try expectEqual(power.changes, []); try expectEqual(phase(), .ready)

        // Auto-approval on: the working session holds, with the marker and one guard at the battery floor.
        try engine.setAutomatic(id, enabled: true)
        await pass()
        try expectEqual(power.changes, [true]); try expect(held())
        try expectEqual(power.guardFloors, [20]); try expectEqual(phase(), .holding)
        try expectEqual(engine.snapshot.keepAwake?.working, 1)
        await pass(5)
        try expectEqual(power.changes, [true], "A held Mac is not changed again"); try expectEqual(power.guardFloors, [20])

        // The turn ends: the hold lasts through the grace period, then ends. An open lid is not slept.
        finish()
        await pass(1)
        try expectEqual(power.changes, [true]); try expectEqual(phase(), .holding)
        try expectNotNil(engine.snapshot.keepAwake?.releaseAt, "A finished hold shows when it ends")
        await pass(engine.keepAwakeGrace)
        try expectEqual(power.changes, [true, false]); try expectEqual(power.sleeps, 0)
        try expectFalse(held()); try expectFalse(power.guardRunning); try expectEqual(phase(), .ready)

        // A closed lid that would have slept the Mac sleeps it once the work is done.
        show(workingScreen); await pass(1)
        power.reading.lidClosed = true
        finish(); await pass(engine.keepAwakeGrace + 1)
        try expectEqual(power.changes, [true, false, true, false]); try expectEqual(power.sleeps, 1)
        // An external display on power keeps a closed Mac awake by itself: released, not slept.
        power.reading.lidCausesSleep = false
        show(workingScreen); await pass(1)
        finish(); await pass(engine.keepAwakeGrace + 1)
        try expectEqual(Array(power.changes.suffix(2)), [true, false]); try expectEqual(power.sleeps, 1)
        power.reading.lidClosed = false; power.reading.lidCausesSleep = true

        // Battery floor: at 20% on battery the work no longer holds, and a closed lid sleeps.
        show(workingScreen); await pass(1)
        try expectEqual(power.changes.last, true)
        power.reading.onBattery = true; power.reading.batteryPercent = 21
        await pass(5)
        try expectEqual(power.changes.last, true, "Above the floor the hold stays")
        power.reading.batteryPercent = 20; power.reading.lidClosed = true
        await pass(5)
        try expectEqual(power.changes.last, false); try expectEqual(power.sleeps, 2); try expectEqual(phase(), .lowBattery)
        power.reading.onBattery = false; power.reading.lidClosed = false
        await pass(5)
        try expectEqual(power.changes.last, true, "On power again, the work holds again"); try expectEqual(phase(), .holding)

        // Heat ends it the same way; it holds again only after the Mac has stayed cool for the cool-down.
        power.reading.thermal = .serious
        await pass(5)
        try expectEqual(power.changes.last, false); try expectEqual(phase(), .hot)
        power.reading.thermal = .fair
        await pass(5)
        try expectEqual(power.changes.last, false, "A Mac that just cooled doesn't hold yet"); try expectEqual(phase(), .hot)
        power.reading.thermal = .serious
        await pass(engine.keepAwakeCoolDown - 10)
        power.reading.thermal = .fair
        await pass(engine.keepAwakeCoolDown - 10)
        try expectEqual(power.changes.last, false, "Heat again restarts the cool-down")
        await pass(20)
        try expectEqual(power.changes.last, true)

        // Pausing every session ends the hold without the grace period.
        try engine.setPaused(true); await pass(1)
        try expectEqual(power.changes.last, false); try expectFalse(held())
        try engine.setPaused(false); await pass(1)
        try expectEqual(power.changes.last, true)

        // Turning it off releases at once.
        try await engine.setKeepAwake(false)
        try expectEqual(power.changes.last, false); try expectFalse(held()); try expectEqual(phase(), .off)

        // A disablesleep the user turned on is theirs: never changed or released.
        power.reading.sleepDisabled = true
        try await engine.setKeepAwake(true)
        try expectEqual(phase(), .external)
        let untouched = power.attempts
        finish(); await pass(engine.keepAwakeGrace + 1)
        try expectEqual(power.attempts, untouched); try expect(power.reading.sleepDisabled)
        power.reading.sleepDisabled = false

        // A failed change leaves nothing half held and waits before trying again.
        show(workingScreen)
        power.failChanges = true
        await pass(1)
        try expectEqual(phase(), .failed); try expectFalse(held())
        let failed = power.attempts
        power.failChanges = false
        await pass(engine.keepAwakeRetryDelay / 2)
        try expectEqual(power.attempts, failed, "No retry before the delay")
        await pass(engine.keepAwakeRetryDelay)
        try expectEqual(power.changes.last, true); try expectEqual(phase(), .holding)

        // Quitting releases at once and never sleeps a closed Mac.
        power.reading.lidClosed = true
        let sleeps = power.sleeps
        engine.stop()
        try expectEqual(power.changes.last, false); try expectEqual(power.sleeps, sleeps); try expectFalse(held())

        // A hold left by a crashed run is adopted while work remains, then released.
        power = FakePower()
        power.reading.sleepDisabled = true
        try expect(FileManager.default.createFile(atPath: marker, contents: nil))
        (engine, id) = try makeEngine(power, home: home)
        try expectEqual(phase(), .checking)
        try engine.setAutomatic(id, enabled: true)
        show(workingScreen); await pass(1)
        try expectEqual(power.changes, [], "The earlier hold is kept, not set again"); try expectEqual(power.guardFloors, [20])
        finish(); await pass(engine.keepAwakeGrace + 1)
        try expectEqual(power.changes, [false]); try expectFalse(held())
        engine.stop()

        // Without the rule, turning it on asks for the password; a cancel keeps it off.
        power = FakePower()
        power.rule = false; power.ruleFile = false; power.installError = "관리자 암호 입력을 취소했습니다."
        (engine, id) = try makeEngine(power, home: directory.appendingPathComponent("fresh"))
        var cancelled = false
        do { try await engine.setKeepAwake(true) } catch { cancelled = true }
        try expect(cancelled); try expectEqual(power.installs, 1); try expectEqual(engine.snapshot.keepAwake?.enabled, false)
        power.installError = nil
        try await engine.setKeepAwake(true)
        try expectEqual(power.installs, 2); try expectEqual(engine.snapshot.keepAwake?.enabled, true); try expectEqual(phase(), .ready)
        try expectEqual(engine.snapshot.keepAwake?.ruleFile, true)
        // Removing the rule turns the setting off first.
        try await engine.removeKeepAwakeRule()
        try expectEqual(power.removals, 1); try expectEqual(engine.snapshot.keepAwake?.enabled, false)
        try expectEqual(engine.snapshot.keepAwake?.ruleFile, false)
        engine.stop()
    }

    func testKeepAwakeGuardScript() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-guard-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func path(_ name: String) -> String { directory.appendingPathComponent(name).path }
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let log = path("log"), battery = path("battery"), lid = path("lid"), failure = path("fail")
        func stub(_ name: String, _ body: String) throws -> String {
            try ("#!/bin/sh\n" + body + "\n").write(toFile: path(name), atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path(name))
            return path(name)
        }
        let sudo = try stub("sudo", "printf '%s\\n' \"$*\" >> \(quoted(log))\n[ -f \(quoted(failure)) ] && exit 1\nexit 0")
        let pmset = try stub("pmset", "[ \"$1\" = -g ] && cat \(quoted(battery))\nexit 0")
        let ioreg = try stub("ioreg", "cat \(quoted(lid))")
        let script = KeepAwake.guardScript(.init(sudo: sudo, pmset: pmset, ioreg: ioreg, interval: 0.1, heartbeatLimit: 60))
        let stale = KeepAwake.guardScript(.init(sudo: sudo, pmset: pmset, ioreg: ioreg, interval: 0.1, heartbeatLimit: 2))
        for stubbed in [script, stale] {
            try expectFalse(stubbed.contains("/usr/bin/sudo") || stubbed.contains("/usr/bin/pmset"), "A stubbed guard can't reach real sudo or pmset")
        }
        // The real guard only parses here; it never runs.
        try expect(KeepAwake.guardScript().contains("'/usr/bin/sudo' -n '/usr/bin/pmset' -a disablesleep 0"))
        let syntax = try CommandRunner.run("/bin/sh", ["-n", "-c", KeepAwake.guardScript()])
        try expectEqual(syntax.status, 0, syntax.error)

        func write(_ text: String, _ file: String) throws { try text.write(toFile: file, atomically: true, encoding: .utf8) }
        func logged() -> String { (try? String(contentsOfFile: log, encoding: .utf8)) ?? "" }
        func hold(_ name: String, age: TimeInterval = 0) throws -> String {
            try expect(FileManager.default.createFile(atPath: path(name), contents: nil))
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: path(name))
            return path(name)
        }
        let release = "-n \(pmset) -a disablesleep 0\n", sleep = "-n \(pmset) sleepnow\n"
        let power = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t80%; charging; 1:00 remaining present: true\n"
        func onBattery(_ percent: Int) -> String { "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t\(percent)%; discharging; 0:40 remaining present: true\n" }
        let closed = "      \"AppleClamshellCausesSleep\" = Yes\n      \"AppleClamshellState\" = Yes\n"
        let open = "      \"AppleClamshellCausesSleep\" = Yes\n      \"AppleClamshellState\" = No\n"
        var watchers: [KeepAwakeGuard] = []
        defer { watchers.forEach { $0.stop() } }

        // AutoApprove exits: the guard releases the hold and sleeps the closed Mac.
        try write(power, battery); try write(closed, lid)
        let app = Process()
        app.executableURL = URL(fileURLWithPath: "/bin/sleep"); app.arguments = ["30"]
        try app.run()
        var marker = try hold("exit.hold")
        let exitWatcher = try KeepAwake.launchGuard(script: script, marker: marker, floor: 20, app: app.processIdentifier)
        watchers.append(exitWatcher)
        Thread.sleep(forTimeInterval: 0.4)
        try expectEqual(logged(), "", "Nothing changes while AutoApprove runs on power")
        app.terminate(); app.waitUntilExit()
        try expect(waitUntil { !exitWatcher.isRunning() }, "The guard ends after releasing")
        try expectEqual(logged(), release + sleep); try expectFalse(FileManager.default.fileExists(atPath: marker))

        // The battery floor ends the hold while AutoApprove still runs; an open lid is not slept.
        try FileManager.default.removeItem(atPath: log)
        try write(open, lid); try write(onBattery(21), battery)
        marker = try hold("battery.hold")
        let batteryWatcher = try KeepAwake.launchGuard(script: script, marker: marker, floor: 20)
        watchers.append(batteryWatcher)
        Thread.sleep(forTimeInterval: 0.4)
        try expectEqual(logged(), "", "21% is above the floor")
        try write(onBattery(20), battery)
        try expect(waitUntil { !batteryWatcher.isRunning() })
        try expectEqual(logged(), release); try expectFalse(FileManager.default.fileExists(atPath: marker))

        // AutoApprove released it itself: the guard leaves without touching anything.
        try FileManager.default.removeItem(atPath: log)
        try write(power, battery)
        marker = try hold("removed.hold")
        let quietWatcher = try KeepAwake.launchGuard(script: script, marker: marker, floor: 20)
        watchers.append(quietWatcher)
        try FileManager.default.removeItem(atPath: marker)
        try expect(waitUntil { !quietWatcher.isRunning() }); try expectEqual(logged(), "")

        // A heartbeat that stopped means a hung AutoApprove; a failed release is tried again.
        try write("", failure)
        marker = try hold("stale.hold", age: 30)
        let staleWatcher = try KeepAwake.launchGuard(script: stale, marker: marker, floor: 20)
        watchers.append(staleWatcher)
        try expect(waitUntil { logged().components(separatedBy: "disablesleep 0").count > 2 }, "A failed release is tried again")
        try expect(FileManager.default.fileExists(atPath: marker)); try expect(staleWatcher.isRunning())
        try FileManager.default.removeItem(atPath: failure)
        try expect(waitUntil { !staleWatcher.isRunning() }); try expectFalse(FileManager.default.fileExists(atPath: marker))
        try expect(logged().hasSuffix(release))
    }

    func testKeepAwakeRuleAndAdminScripts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-rule-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rule = try KeepAwake.rule(user: "lky")
        try expect(rule.hasSuffix("\nlky ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset sleepnow\n"))
        for name in ["", "a b", "a,b", "a=b", "a'b", "-x", "root\nALL"] { try expectThrows(try KeepAwake.rule(user: name)) }
        // visudo checks the syntax as this user; nothing is installed.
        let file = directory.appendingPathComponent("rule").path
        try rule.write(toFile: file, atomically: true, encoding: .utf8)
        let parsed = try CommandRunner.run("/usr/sbin/visudo", ["-c", "-f", file])
        try expectEqual(parsed.status, 0, parsed.error + parsed.output)

        let install = try KeepAwake.installScript(user: "lky")
        try expect(install.contains("tmp=$(/usr/bin/mktemp /private/etc/sudoers.d/.autoapprove.XXXXXX)"), "The rule is checked under a name sudo ignores")
        try expect(install.contains("/usr/sbin/visudo -cf \"$tmp\"") && install.hasSuffix("/bin/mv -f \"$tmp\" \(KeepAwake.rulePath)"))
        try expectEqual(try CommandRunner.run("/bin/sh", ["-n", "-c", install]).status, 0)
        let printf = try expectLine(install, prefix: "/usr/bin/printf").replacingOccurrences(of: " > \"$tmp\"", with: "")
        try expectEqual(try CommandRunner.run("/bin/sh", ["-c", printf]).output, rule, "The script writes exactly the rule")

        // AppleScript quoting returns the shell text unchanged; the admin script only compiles here.
        let echoed = try CommandRunner.run("/usr/bin/osascript", [], input: Data("return \(KeepAwake.appleScriptLiteral(install))".utf8))
        try expectEqual(echoed.output, install + "\n")
        let compiled = try CommandRunner.run("/usr/bin/osacompile", ["-o", directory.appendingPathComponent("admin.scpt").path,
            "-e", KeepAwake.administratorScript(install, prompt: "잠자기 \"권한\" \\ 설치")])
        try expectEqual(compiled.status, 0, compiled.error)
    }

    private func expectLine(_ text: String, prefix: String) throws -> String {
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }) else { throw AppError.message("No line starts with \(prefix)") }
        return String(line)
    }
}
