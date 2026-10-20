// Production session window, isolated engine and synthetic questions only.
import AppKit
import SwiftUI
import Combine
import UserNotifications
import QuartzCore
import Darwin
import AutoApproveCore

@MainActor final class QuestionNotifications: ObservableObject {
    @Published var authorization: UNAuthorizationStatus = .authorized
    @Published var error: String?
}
@MainActor enum TerminalNavigator {
    static func open(_ session: AgentSession, engine: ApprovalEngine) async throws {}
}
@MainActor final class SessionSelectionState: ObservableObject {
    static let shared = SessionSelectionState()
    @Published var selection: Set<String> = ["fixture-0"]
}
@MainActor enum SelectionBenchCounts {
    static var detailSession = "", editors = 0, details = 0
#if NATIVE_QUESTION_DRAFTS
    static var drafts: QuestionReplyDrafts?
#endif
}

@MainActor final class SelectionBenchDelegate: NSObject, NSApplicationDelegate {
    let paths: AppPaths, engine: ApprovalEngine
    let notifications = QuestionNotifications()
    var window: NSWindow!
    var sessions: [AgentSession] = []
    var phases: [[String: Any]] = []
    var timer: Timer?, beats: [Double] = [], lastBeat = 0.0
    var output: String { CommandLine.arguments.first(where: { $0.hasPrefix("--output=") }).map { String($0.dropFirst(9)) } ?? "/private/tmp/native-session-selection.json" }
    init(fixture: Bool) throws {
        paths = AppPaths(directory: FileManager.default.temporaryDirectory.appendingPathComponent("aa-selection-" + UUID().uuidString))
        try paths.prepare()
        sessions = (0..<4).map { index in
            var s = AgentSession(id:"fixture-\(index)", agent:.codex, pid:Int32(900_000+index), started:"synthetic", tty:"/dev/fixture-\(index)", cwd:"/synthetic/프로젝트 \(index)", terminal:.vscode)
            s.channel = .vscodeScreen; s.bridgeID = "synthetic"; s.terminalID = s.id
            s.terminalTitle = "합성 세션 \(index) · 긴 제목과 한글 e\u{301}"
            return s
        }
        let store = try AuditStore(path:paths.database)
        for s in sessions { for i in 0..<40 {
            try store.append(AuditEvent(sessionID:s.id, summary:"합성 승인 내역 \(i)", outcome:"승인 전달", source:"검증용", context:AuditContext(session:s), request:String(repeating:"실행하지 않는 합성 요청\n",count:20)))
        } }
        engine = try ApprovalEngine(paths:paths, terminalReader:{ _ in TerminalSnapshot() }, questionTransport:CodexReplyTransport(
            prepare:{ _,question in CodexReplyTarget(executable:"/unused-synthetic",home:"/unused-synthetic",threadID:question.threadID) },
            send:{ _,_ in throw AppError.message("합성 전송 오류") }),
            claudeRegistryReader:{ _ in [] }, processReader:{ [] }, webLoopbackOnly:true)
        super.init()
        engine.updateDiscovery(sessions,records:[],claudeRegistrations:[])
        for (index,count) in [4,49,17,0].enumerated() {
            let thread = "synthetic-thread-\(index)"
            let questions = (0..<count).map { i in QueuedQuestion(id:"q-\(index)-\(i)",threadID:thread,
                title:"질문 \(index)-\(i): " + String(repeating:"긴 한글 질문과 설명 e\u{301} 🧪. ",count:5), options:["첫 번째 선택","두 번째 선택","세 번째 선택"]) }
            engine.updateCodexQuestions([.init(sessionID:sessions[index].id,questions:questions,threadID:thread)])
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect:NSRect(x:70,y:100,width:1040,height:700),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "AutoApprove 세션 반응 검증"; window.identifier = .init("main")
        if CommandLine.arguments.contains("--measure") { window.level = .floating }
        window.contentView = NSHostingView(rootView:SessionWindow(engine:engine,notifications:notifications,openTerminal:{ _,_ in }))
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        let menu = NSMenu(), item = NSMenuItem(), submenu = NSMenu()
        let quit = NSMenuItem(title:"검증 앱 종료",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q"); quit.target = NSApp
        submenu.addItem(quit); item.submenu = submenu; menu.addItem(item); NSApp.mainMenu = menu
        if CommandLine.arguments.contains("--compact") { window.setContentSize(.init(width:784,height:612)) }
        if CommandLine.arguments.contains("--measure") { Task { await measure() } }
        if CommandLine.arguments.contains("--verify") { Task { await verify() } }
    }
    func cpu() -> Double {
        var v = rusage(); getrusage(RUSAGE_SELF,&v)
        return Double(v.ru_utime.tv_sec+v.ru_stime.tv_sec)+Double(v.ru_utime.tv_usec+v.ru_stime.tv_usec)/1e6
    }
    func pause(_ ms: Int) async { try? await Task.sleep(for:.milliseconds(ms)) }
    func layout() { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush() }
    func selected(_ id: String) async throws {
        SessionSelectionState.shared.selection = [id]
        let deadline = ProcessInfo.processInfo.systemUptime+15
        repeat {
            await pause(1); layout()
            if SelectionBenchCounts.detailSession == id { return }
        } while ProcessInfo.processInfo.systemUptime<deadline
        throw AppError.message("Selection did not reach the production detail view")
    }
    func phase(_ name: String, rounds: Int, selection: Bool) async throws {
        await pause(200); layout()
        guard window.occlusionState.contains(.visible), !NSApp.isHidden else { throw AppError.message("Measurement window is occluded") }
        var turns: [Double] = []; beats = []; lastBeat = ProcessInfo.processInfo.systemUptime
        timer = Timer.scheduledTimer(withTimeInterval:1.0/120,repeats:true) { [weak self] _ in MainActor.assumeIsolated {
            guard let self else { return }; let now = ProcessInfo.processInfo.systemUptime
            self.beats.append((now-self.lastBeat)*1000); self.lastBeat = now
        } }
        let start = cpu(), began = ProcessInfo.processInfo.systemUptime, editors = SelectionBenchCounts.editors
        for i in 0..<rounds {
            let turn = ProcessInfo.processInfo.systemUptime
            if selection { try await selected("fixture-\(i%2 == 0 ? 1 : 0)") }
            else {
                try engine.setCustomization("fixture-1",value:.init(title:"合成 갱신 \(i)",note:"",color:nil))
                await pause(20); layout()
            }
            turns.append((ProcessInfo.processInfo.systemUptime-turn)*1000)
            guard window.occlusionState.contains(.visible) else { throw AppError.message("Window became occluded") }
        }
        let used = cpu()-start, wall = ProcessInfo.processInfo.systemUptime-began
        timer?.invalidate(); timer = nil
        func percentile(_ values: [Double], _ p: Double) -> Double { let a = values.sorted(); return a.isEmpty ? 0 : a[min(a.count-1,Int(Double(a.count-1)*p))] }
        phases.append(["name":name,"rounds":rounds,"cpuSeconds":used,"wallSeconds":wall,"editorBodies":SelectionBenchCounts.editors-editors,
            "updateMedianMS":percentile(turns,0.5),"updateP95MS":percentile(turns,0.95),"maxMainLoopGapMS":beats.max() ?? 0,"turnsMS":turns])
    }
    func measure() async {
        do {
            await pause(400); try await selected("fixture-1"); try await selected("fixture-0")
            try await phase("dense-selection",rounds:16,selection:true)
            try await selected("fixture-1")
            try await phase("dense-background-updates",rounds:48,selection:false)
            try await selected("fixture-3")
            try await phase("empty-background-control",rounds:48,selection:false)
            var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
            let report: [String:Any] = ["phases":phases,"peakResidentBytes":usage.ru_maxrss,"syntheticSessions":4,"questionsPerSession":[4,49,17,0],"engineStarted":false,"terminalInputs":0,
                "scope":"Production native window, selection binding through completed native layout; synthetic engine/files, no original terminal reads or inputs. Timer gaps include layout. Not system click dispatch latency."]
            try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:URL(fileURLWithPath:output))
            print("SELECTION BENCH PASS " + output); NSApp.terminate(nil)
        } catch { fputs("SELECTION BENCH FAILED: \(error)\n",stderr); exit(1) }
    }
    func verify() async {
        do {
            let directory = URL(fileURLWithPath:output).deletingLastPathComponent()
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            func capture(_ name: String) throws {
                layout(); guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw AppError.message("Cannot capture native view") }
                view.cacheDisplay(in:view.bounds,to:rep)
                let image = NSImage(size:view.bounds.size); image.lockFocus()
                window.backgroundColor.setFill(); NSBezierPath(rect:NSRect(origin:.zero,size:view.bounds.size)).fill()
                rep.draw(in:NSRect(origin:.zero,size:view.bounds.size)); image.unlockFocus()
                guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data:tiff),
                      let png = bitmap.representation(using:.png,properties:[:]) else { throw AppError.message("Cannot encode native view") }
                try png.write(to:directory.appendingPathComponent(name+".png"))
            }
            func inputs(_ view: NSView) -> [(value: String, enabled: Bool)] {
                if let text = view as? NSTextField { return [(text.stringValue,text.isEnabled)] }
                if let text = view as? NSTextView { return [(text.string,text.isEditable)] }
                return view.subviews.flatMap(inputs)
            }
            func scrollViews(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews) }
            func revealDraft(_ value: String) async throws {
                guard let root = window.contentView,
                      let scroll = scrollViews(root).first(where: { $0.convert($0.bounds,to:root).midX>root.bounds.width/2 }) else { throw AppError.message("Native detail scroll view not found") }
                for step in 0..<50 {
                    if inputs(root).contains(where:{$0.value == value}) { return }
                    scroll.contentView.scroll(to:NSPoint(x:0,y:CGFloat(step)*100)); scroll.reflectScrolledClipView(scroll.contentView)
                    await pause(30); layout()
                }
                throw AppError.message("Draft did not reach a native text input after scrolling")
            }
            await pause(300); try await selected("fixture-1"); await pause(100)
            try capture("dense-regular")
#if NATIVE_QUESTION_DRAFTS
            guard let drafts = SelectionBenchCounts.drafts else { throw AppError.message("Window draft owner not observed") }
            let draft = drafts.draft(sessionID:"fixture-1",questionID:"q-1-0")
            draft.customAnswer = "보존 검증 초안 e\u{301} 🧪"; draft.selected = [1]
            await pause(100); layout(); try await revealDraft(draft.customAnswer)
            try await selected("fixture-2"); try await selected("fixture-1"); await pause(100); layout()
            try await revealDraft(draft.customAnswer)
            guard drafts.draft(sessionID:"fixture-1",questionID:"q-1-0") === draft,
                  draft.selected == [1], inputs(window.contentView!).contains(where: { $0.value == draft.customAnswer }) else { throw AppError.message("Selection destroyed the native draft") }
            draft.submitting = true; await pause(50); layout()
            let submittingFields = inputs(window.contentView!).filter {$0.value == draft.customAnswer}
            guard !submittingFields.isEmpty, submittingFields.allSatisfy({!$0.enabled}) else { throw AppError.message("Submitting field remains editable") }
            draft.submitting = false; draft.error = "합成 전송 실패 · 초안 유지"; await pause(50)
            try capture("draft-retained-error")
            // Removing and rebuilding the actual hierarchy exercises state ownership
            // independently of SwiftUI's current offscreen retention strategy.
            window.contentView = nil; await pause(50)
            window.contentView = NSHostingView(rootView:QuestionReplyEditor(question:QueuedQuestion(id:"q-1-0",threadID:"synthetic-thread-1",title:"재구성한 합성 질문",options:["첫 번째","두 번째"]),
                connectionError:nil,canReveal:false,openingTerminal:false,send:{ _ in },dismiss:{},reveal:{},beginReply:{},cancelAutomaticReply:{},draft:draft))
            await pause(100); layout()
            guard inputs(window.contentView!).contains(where:{$0.value == draft.customAnswer}) && draft.selected == [1] else { throw AppError.message("Recreated editor lost its draft") }
            window.contentView = NSHostingView(rootView:SessionWindow(engine:engine,notifications:notifications,openTerminal:{ _,_ in }))
            await pause(150)
#endif
            window.setContentSize(.init(width:784,height:612)); await pause(100); try capture("dense-compact")
            engine.updateCodexQuestions([.init(sessionID:"fixture-1",questions:nil,error:"합성 질문 연결 오류")]); await pause(100); try capture("connection-error")
            let questions = engine.snapshot.sessions.first(where:{$0.id == "fixture-1"})?.questions ?? []
            engine.updateCodexQuestions([.init(sessionID:"fixture-1",questions:questions,threadID:"synthetic-thread-1")]); await pause(100)
            window.appearance = NSAppearance(named:.darkAqua); await pause(100); try capture("dense-dark")
            try await selected("fixture-3"); await pause(100); try capture("empty-compact")
            var draftChecks = false
#if NATIVE_QUESTION_DRAFTS
            draftChecks = true
#endif
            let report: [String:Any] = ["nativeHierarchyRecreated":draftChecks,"selectionDraftRetained":draftChecks,"nativeTextFieldMatchesDraft":draftChecks,"submittingDisablesField":draftChecks,"connectionErrorAndRecovery":true,"windowSizes":[[1040,700],[784,612]],"terminalInputs":0]
            try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:URL(fileURLWithPath:output))
            print("SELECTION QA PASS " + output); NSApp.terminate(nil)
        } catch { fputs("SELECTION QA FAILED: \(error)\n",stderr); exit(1) }
    }
}
@main struct NativeSessionSelectionBench {
    @MainActor static func main() throws {
        let app = NSApplication.shared, delegate = try SelectionBenchDelegate(fixture: true)
        app.setActivationPolicy(.regular); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
