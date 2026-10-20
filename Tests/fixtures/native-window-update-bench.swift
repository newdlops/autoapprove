// Actual production windows with an isolated, never-started engine. No original
// terminal, listener, notification permission or system setting is touched.
import AppKit
import Combine
import SwiftUI
import UserNotifications
import Darwin
import CSQLite
import AutoApproveCore

private func require(_ condition: Bool, line: UInt = #line) throws {
    guard condition else { throw AppError.message("Native window QA failed at fixture line \(line)") }
}

private struct OccludedMeasurement: Error {}

@MainActor final class QuestionNotifications: ObservableObject {
    @Published var authorization: UNAuthorizationStatus = .authorized
    @Published var busy = false
    @Published var error: String?
    var status: String { "합성 검증 알림" }
    func requestAuthorization() async {}
    func openSettings() {}
    func retryDelivery() async {}
}
@MainActor enum TerminalNavigator {
    static func open(_ session: AgentSession, engine: ApprovalEngine) async throws {}
}
@MainActor enum WindowBenchCounts {
    static var sessionBodies = 0, historyBodies = 0
    static var queueBodies = 0, editorBodies = 0
    static var lastTitles: [String] = [], lastPaused = false, initialComplete = false
    static var historyEventIDs: [String] = [], historyError: String?
    static var notificationError: String?
    static func session(_ snapshot: EngineSnapshot, initial: Bool, error: String?) {
        sessionBodies += 1; lastTitles = snapshot.sessions.map(\.displayedTerminalTitle)
        lastPaused = snapshot.paused; initialComplete = initial; notificationError = error
    }
    static func history(_ snapshot: EngineSnapshot) {
        historyBodies += 1; historyEventIDs = snapshot.events.map(\.id); historyError = snapshot.health.auditError
    }
}

@MainActor final class WindowBenchDelegate: NSObject, NSApplicationDelegate {
    let target: String
    let engine: ApprovalEngine
    let notifications = QuestionNotifications()
    let paths: AppPaths
    var window: NSWindow!
    var sessions: [AgentSession]
    var phases: [[String: Any]] = []
    var checks: [String] = []
    var hiddenTransitionBodies = 0
    var expectedBodies: Int { target == "sessions" ? WindowBenchCounts.sessionBodies : WindowBenchCounts.historyBodies }
    init(windowKind: String) throws {
        target = windowKind
        paths = AppPaths(directory: FileManager.default.temporaryDirectory.appendingPathComponent("aa-window-bench-" + UUID().uuidString))
        try paths.prepare()
        sessions = (0..<24).map { index in
            var value = AgentSession(id: "fixture-\(index)", agent: .codex, pid: Int32(900_000 + index), started: "synthetic",
                tty: "/dev/ttys\(100 + index)", cwd: "/fixture/한글 프로젝트 \(index)", terminal: .vscode)
            value.channel = .vscodeScreen; value.bridgeID = "synthetic"; value.terminalID = value.id
            value.terminalTitle = "합성 원본 \(index) · 긴 제목과 세션 상태 확인"
            value.gitBranch = .init(kind: .branch, name: "feature/한글-e\u{301}-\(index)")
            return value
        }
        let store = try AuditStore(path: paths.database)
        for index in 0..<120 {
            try store.append(AuditEvent(sessionID: sessions[0].id, summary: "합성 기록 \(index)", outcome: "승인 전달",
                source: "검증용", context: AuditContext(session: sessions[0]), request: "실행하지 않는 합성 요청 \(index)"))
        }
        engine = try ApprovalEngine(paths: paths, terminalReader:{ _ in TerminalSnapshot() }, questionTransport:CodexReplyTransport(
            prepare:{ _,question in CodexReplyTarget(executable:"/unused-synthetic",home:"/unused-synthetic",threadID:question.threadID) },
            send:{ _,_ in UUID().uuidString }), claudeRegistryReader: { _ in [] }, processReader: { [] }, webLoopbackOnly: true)
        super.init()
        if !CommandLine.arguments.contains("--empty-start") {
            engine.updateDiscovery(sessions, records: [], claudeRegistrations: [])
            _ = engine.handleHook(["hook_event_name":"SessionStart","session_id":"window-audit","requestID":"begin","cwd":"/fixture/audit"])
            try engine.setAutomatic("claude:window-audit", enabled: true)
            if CommandLine.arguments.contains("--questions") { appendQuestion(count: CommandLine.arguments.contains("--dense-questions") ? 44 : 1) }
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 80, y: 110, width: 1040, height: 700),
            styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.title = "AutoApprove 창 갱신 검증 · " + target
        window.identifier = NSUserInterfaceItemIdentifier(target == "sessions" ? "main" : "history")
        // Keep only this synthetic measurement window above normal windows.
        // Otherwise switching back to the coding app correctly parks product
        // invalidations and makes a visible-window CPU sample meaningless.
        if CommandLine.arguments.contains("--measure") { window.level = .floating }
        if target == "sessions" {
            window.contentView = NSHostingView(rootView: SessionWindow(engine:engine,notifications:notifications,openTerminal:{ _,_ in }))
        } else { window.contentView = NSHostingView(rootView: AuditHistoryWindow(engine:engine)) }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        installMenu()
        if CommandLine.arguments.contains("--measure") { Task { await measure() } }
    }
    func installMenu() {
        let menu = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu(title:"검증")
        let quit = NSMenuItem(title:"검증 앱 종료",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q"); quit.target = NSApp
        appMenu.addItem(quit);appItem.submenu = appMenu;menu.addItem(appItem)
        let item = NSMenuItem(), controls = NSMenu(title:"합성 검증")
        for (title,key,action) in [("관련 없는 상태 갱신","u",#selector(unrelated(_:))),("새 질문 추가","n",#selector(addQuestion(_:))),
            ("세션 제목 갱신","g",#selector(changeTitle(_:))),("질문 연결 오류","e",#selector(questionError(_:))),
            ("질문 연결 복구","r",#selector(questionRecovery(_:))),("기본 창 크기","1",#selector(regularSize(_:))),
            ("작은 창 크기","2",#selector(compactSize(_:)))] {
            let command = NSMenuItem(title:title,action:action,keyEquivalent:key);command.target = self
            command.keyEquivalentModifierMask = [.command,.shift];controls.addItem(command)
        }
        item.submenu = controls;menu.addItem(item);NSApp.mainMenu = menu
    }
    @objc func unrelated(_ sender: Any?) {
        try? engine.setLANUpdateEnabled(!engine.lanUpdate.enabled)
        fputs("WINDOW QA unrelated action\n",stderr)
    }
    @objc func addQuestion(_ sender: Any?) { appendQuestion() }
    @objc func changeTitle(_ sender: Any?) {
        try? engine.setCustomization(sessions[0].id,value:.init(title:"갱신된 합성 세션 제목 \(Date().timeIntervalSince1970)",note:"합성 메모",color:.blue))
    }
    @objc func questionError(_ sender: Any?) {
        engine.updateCodexQuestions([.init(sessionID:sessions[0].id,questions:nil,error:"합성 질문 연결 오류")])
    }
    @objc func questionRecovery(_ sender: Any?) {
        let questions = engine.snapshot.sessions.first(where:{$0.id == sessions[0].id})?.questions ?? []
        engine.updateCodexQuestions([.init(sessionID:sessions[0].id,questions:questions,threadID:"synthetic-window-thread")])
    }
    @objc func regularSize(_ sender: Any?) { window.setContentSize(NSSize(width:1040,height:700)) }
    @objc func compactSize(_ sender: Any?) { window.setContentSize(NSSize(width:784,height:612)) }
    func appendQuestion(count: Int = 1) {
        let thread = "synthetic-window-thread"
        var questions = engine.snapshot.sessions.first(where:{$0.id == sessions[0].id})?.questions ?? []
        for _ in 0..<count {
            questions.append(QueuedQuestion(id:"synthetic-question-\(questions.count)",threadID:thread,
                title:"검증용: 어느 환경을 먼저 확인할까요? \(questions.count+1)",options:["개발 환경","시험 환경"]))
        }
        engine.updateCodexQuestions([CodexQuestionUpdate(sessionID:sessions[0].id,questions:questions,threadID:thread)])
        fputs("WINDOW QA synthetic questions \(engine.snapshot.sessions.first(where:{$0.id == sessions[0].id})?.questions.count ?? -1)\n",stderr)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !CommandLine.arguments.contains("--measure")
    }
    func pause(_ ms: Int = 100) async { try? await Task.sleep(for: .milliseconds(ms)) }
    func cpu() -> Double {
        var value = rusage(); getrusage(RUSAGE_SELF,&value)
        return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec)/1e6
    }
    func phase(_ name: String, rounds: Int, _ action: (Int) throws -> Void) async throws {
        await pause(150)
        guard window.occlusionState.contains(.visible), !NSApp.isHidden else { throw OccludedMeasurement() }
        fputs("WINDOW PHASE \(target) \(name) · visible \(window.occlusionState.contains(.visible))\n",stderr)
        let began = ProcessInfo.processInfo.systemUptime, before = cpu(), bodies = expectedBodies
        let queues = WindowBenchCounts.queueBodies, editors = WindowBenchCounts.editorBodies
        var updateTurns: [Double] = []
        var occluded = false
        for index in 0..<rounds {
            let updateStart = ProcessInfo.processInfo.systemUptime
            try action(index); await pause(20)
            updateTurns.append((ProcessInfo.processInfo.systemUptime-updateStart)*1_000)
            occluded = occluded || !window.occlusionState.contains(.visible) || NSApp.isHidden
        }
        await pause(150)
        if target == "sessions" && name == "session-metadata" {
            for _ in 0..<10 where !WindowBenchCounts.lastTitles.contains("현재 합성 제목 · 갱신 59") { await pause(50) }
        }
        occluded = occluded || !window.occlusionState.contains(.visible) || NSApp.isHidden
        updateTurns.sort()
        phases.append(["name":name,"rounds":rounds,"bodies":expectedBodies-bodies,"visibleThroughout": !occluded,
            "queueBodies":WindowBenchCounts.queueBodies-queues,"editorBodies":WindowBenchCounts.editorBodies-editors,
            "updateTurnMedianMs":updateTurns[updateTurns.count/2],"updateTurnP95Ms":updateTurns[min(updateTurns.count-1,Int(Double(updateTurns.count)*0.95))],
            "updateTurnMaxMs":updateTurns.last ?? 0,
            "cpuSeconds":cpu()-before,"wallSeconds":ProcessInfo.processInfo.systemUptime-began])
        fputs("WINDOW PHASE DONE \(target) \(name) · bodies \(expectedBodies-bodies) · visible \(window.occlusionState.contains(.visible)) · active \(NSApp.isActive) · hidden \(NSApp.isHidden)\n",stderr)
        guard !occluded else { throw OccludedMeasurement() }
    }
    func audit(_ index: Int) throws {
        let response = engine.handleHook(["session_id":"window-audit","hook_event_name":"PermissionRequest",
            "requestID":UUID().uuidString,"tool_name":"Bash","tool_input":["command":"echo synthetic-\(index)"]])
        try require(response["hookSpecificOutput"] != nil)
    }
    func sql(_ text: String) throws {
        var db: OpaquePointer?
        try require(sqlite3_open(paths.database,&db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try require(sqlite3_exec(db,text,nil,nil,nil) == SQLITE_OK)
    }
    func capture(_ name: String) throws {
        guard let output = CommandLine.arguments.first(where: { $0.hasPrefix("--captures=") }).map({ String($0.dropFirst(11)) }),
              let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return }
        view.cacheDisplay(in:view.bounds,to:rep)
        let image = NSImage(size:view.bounds.size);image.lockFocus()
        window.backgroundColor.setFill();NSBezierPath(rect:NSRect(origin:.zero,size:view.bounds.size)).fill()
        rep.draw(in:NSRect(origin:.zero,size:view.bounds.size));image.unlockFocus()
        if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data:tiff),
           let data = bitmap.representation(using:.png,properties:[:]) {
            try data.write(to:URL(fileURLWithPath:output).appendingPathComponent(name+".png"))
        }
    }
    func finish() throws {
        var usage = rusage();getrusage(RUSAGE_SELF,&usage)
        let report:[String:Any] = ["target":target,"phases":phases,"checks":checks,"peakResidentBytes":usage.ru_maxrss,
            "sessions":sessions.count,"webServiceStarted":engine.webService != nil,"terminalInputs":0,"hiddenTransitionBodies":hiddenTransitionBodies,
            "measurementWindowLevel":window.level.rawValue,
            "scope":"Actual production native windows and normal engine APIs, synthetic local data. No engine start, live terminal, notification permission or system settings."]
        try require(engine.webService == nil)
        let data = try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys])
        if let output = CommandLine.arguments.first(where:{$0.hasPrefix("--report=")}).map({String($0.dropFirst(9))}) {
            try data.write(to:URL(fileURLWithPath:output))
        }
        print(String(decoding:data,as:UTF8.self));fflush(stdout)
        window.contentView = nil;engine.stop();NSApp.terminate(nil)
    }
    func measure() async {
        do {
            await pause(600)
            try require(expectedBodies > 0)
            try capture(target+"-initial")
            if CommandLine.arguments.contains("--empty-start") {
                try require(target == "sessions" && !WindowBenchCounts.initialComplete)
                await engine.refresh();await pause(250)
                try require(WindowBenchCounts.initialComplete && engine.snapshot.sessions.isEmpty)
                checks.append("empty initial discovery completes and redraws without sessions")
                try capture("sessions-empty-complete");try finish();return
            }
            try await phase("unrelated-lan-status",rounds:60) { try engine.setLANUpdateEnabled($0.isMultiple(of:2)) }
            try await phase("session-metadata",rounds:60) { generation in
                try engine.setCustomization(sessions[0].id,value:.init(title:"현재 합성 제목 · 갱신 \(generation)",note:"합성 메모",color:.blue))
            }
            if target == "sessions" {
                fputs("WINDOW LATEST TITLE · visible \(window.occlusionState.contains(.visible)) · active \(NSApp.isActive) · applied \(WindowBenchCounts.lastTitles.contains("현재 합성 제목 · 갱신 59"))\n",stderr)
                try require(WindowBenchCounts.lastTitles.contains("현재 합성 제목 · 갱신 59"));checks.append("latest session metadata rendered")
            }
            try await phase("new-audit-events",rounds:20) { try audit($0) }
            if target == "history" { try require(WindowBenchCounts.historyEventIDs == engine.snapshot.events.map(\.id)); checks.append("new audit events rendered") }
            try engine.setPaused(true); await pause()
            if target == "sessions" { try require(WindowBenchCounts.lastPaused); checks.append("pause control remains live") }
            notifications.error = "검증용 알림 오류"; await pause()
            if target == "sessions" { try require(WindowBenchCounts.notificationError == notifications.error); checks.append("notification errors remain live") }
            notifications.error = nil
            try engine.setPaused(false)
            try sql("CREATE TRIGGER window_bench_failure BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT,'synthetic audit failure'); END;")
            _ = engine.handleHook(["session_id":"window-audit","hook_event_name":"PermissionRequest","requestID":UUID().uuidString,
                "tool_name":"Bash","tool_input":["command":"echo synthetic-error"]])
            await pause(150)
            try require(engine.snapshot.health.auditError != nil)
            if target == "history" { try require(WindowBenchCounts.historyError != nil); checks.append("audit error without a new row rendered") }
            try capture(target+"-error")
            try sql("DROP TRIGGER window_bench_failure")
            try audit(999); await pause(150)
            if target == "history" { try require(WindowBenchCounts.historyError == nil); checks.append("audit error recovery rendered") }
            window.orderOut(nil); await pause(150)
            let hiddenBodies = expectedBodies
            for generation in 0..<30 {
                try engine.setCustomization(sessions[0].id,value:.init(title:"숨김 이후 최신 제목 \(generation)",note:"합성 메모",color:.blue))
                try engine.setLANUpdateEnabled(generation.isMultiple(of:2)); await pause(10)
            }
            await pause(100)
            hiddenTransitionBodies = expectedBodies-hiddenBodies
            fputs("WINDOW HIDDEN \(target) · visibility transition bodies \(hiddenTransitionBodies) · window visible \(window.isVisible)\n",stderr)
            // A late occlusion signal can publish isVisible=false once. Model
            // updates must remain parked after that single visibility frame.
            try require(!window.isVisible && hiddenTransitionBodies <= 1)
            checks.append("hidden model updates stay parked after one visibility transition")
            window.makeKeyAndOrderFront(nil); await pause(300)
            if target == "sessions" { try require(WindowBenchCounts.lastTitles.contains("숨김 이후 최신 제목 29")) }
            else { try require(WindowBenchCounts.historyEventIDs == engine.snapshot.events.map(\.id)) }
            checks.append("reveal reads the latest state")
            try capture(target+"-restored")
            window.setContentSize(NSSize(width:784,height:612)); await pause(250)
            try capture(target+"-compact")
            try finish()
        } catch is OccludedMeasurement {
            fputs("WINDOW BENCH INVALID: measurement window was occluded; do not use this CPU sample\n",stderr); exit(2)
        } catch { fputs("WINDOW BENCH FAILED: \(error)\n",stderr); exit(1) }
    }
}
@main struct NativeWindowUpdateBench {
    @MainActor static func main() throws {
        let target = CommandLine.arguments.first(where: { $0.hasPrefix("--window=") }).map { String($0.dropFirst(9)) } ?? "sessions"
        let app = NSApplication.shared, delegate = try WindowBenchDelegate(windowKind:target)
        app.setActivationPolicy(.regular); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
