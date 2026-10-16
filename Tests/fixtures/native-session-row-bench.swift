import AppKit
import Combine
import SwiftUI
import Darwin
import AutoApproveCore

// Test-only counters are inserted into copies of the actual production views
// by the packaging script. No counters or synthetic state ship in the app.
@MainActor enum RowBenchCounts {
    final class Reference {
        weak var value: AnyObject?
        init(_ value: AnyObject) { self.value = value }
    }
    static var rows = 0
    static var labels = 0
    static var references: [Reference] = []
    static func track(_ value: AnyObject) { references.append(Reference(value)) }
    static var liveActions: Int { references.filter { $0.value != nil }.count }
}

@MainActor private final class RowBenchModel: ObservableObject {
    @Published var generation = 0
    @Published var mode = "publisher"
    @Published var status = "혼합"
    @Published var dark = false
    @Published var selection: Set<String> = ["fixture-0"]
    @Published var automatic = [Bool](repeating: true, count: 24)
    @Published var lastAction = "실제 터미널에 입력하지 않는 합성 화면입니다."
    var renderedGeneration = -1

    func sessions() -> [AgentSession] {
        (0..<24).map { index in
            var session = AgentSession(id: "fixture-\(index)", agent: .codex, pid: Int32(900_000 + index),
                started: "synthetic", tty: String(format: "/dev/ttys%03d", 70 + index),
                cwd: "/private/tmp/합성 프로젝트 \(index)", terminal: .terminal)
            session.phase = index.isMultiple(of: 4) ? .working : .idle
            session.channel = .terminalScreen; session.automatic = automatic[index]
            session.terminalTitle = "합성 원본 제목 \(index) · 긴 내용을 그대로 표시합니다"
            session.gitBranch = .init(kind: .branch, name: "feature/합성-목록-확인-\(index)")
            session.lastActivity = Date(timeIntervalSince1970: 1_000)
            if index == 0 {
                session.customization = SessionCustomization(title: "", note: "긴 합성 메모 · 원본 식별과 동작은 바꾸지 않습니다.", color: .blue)
                session.notices = [try! JSONDecoder().decode(SessionNotice.self, from: Data(#"{"id":"fixture-notice","sourceKey":"fixture","kind":"question","summary":"합성 알림","date":0,"isRead":false}"#.utf8))]
                switch status {
                case "질문":
                    session.phase = .input
                    session.queuedQuestions = [.init(id: "question", threadID: "fixture", title: "합성 질문", options: ["개발", "시험"])]
                case "전송":
                    var question = QueuedQuestion(id: "question", threadID: "fixture", title: "합성 질문")
                    question.reply = .init(phase: .sending, answer: "개발", message: "합성 전송")
                    session.queuedQuestions = [question]
                case "연결 끊김": session.channel = .none; session.phase = .unknown
                case "종료": session.phase = .ended
                default: break
                }
            }
            if mode == "observation" {
                session.lastActivity = Date(timeIntervalSince1970: Double(1_000 + generation))
                session.codexQuestionsObservedAt = Date(timeIntervalSince1970: Double(2_000 + generation))
            }
            if mode == "all-titles" || mode == "one-title" && index == 0 {
                session.terminalTitle = "합성 제목 \(index) · 갱신 \(generation)"
            }
            return session
        }
    }
    func setAutomatic(_ value: Bool, index: Int, capturedGeneration: Int) {
        automatic[index] = value
        lastAction = "합성 행 \(index) · 콜백 갱신 \(capturedGeneration) · \(value ? "켜짐" : "꺼짐")"
    }
}

@MainActor private struct RowBenchView: View {
    @ObservedObject var model: RowBenchModel
    var body: some View {
        let generation = model.generation
        VStack(alignment: .leading, spacing: 10) {
            Text("AutoApprove 합성 세션 목록").font(.headline)
            HStack {
                Button("표시 없는 갱신") { model.generation += 1 }
                Button("제목 변경") { model.mode = "one-title"; model.generation += 1 }
                Toggle("어두운 화면", isOn: $model.dark)
            }.controlSize(.small)
            Picker("합성 상태", selection: $model.status) {
                ForEach(["혼합", "질문", "전송", "연결 끊김", "종료"], id: \.self) { Text($0) }
            }
            Text("갱신 \(generation) · 24개 합성 세션").font(.caption).monospacedDigit()
            Text(model.lastAction).font(.caption).foregroundStyle(.secondary)
            List(selection: $model.selection) {
                ForEach(model.sessions()) { session in
                    let index = Int(session.pid) - 900_000
                    SessionRow(session: session, paused: false, selected: model.selection.contains(session.id),
                        setAutomatic: { model.setAutomatic($0, index: index, capturedGeneration: generation) },
                        reveal: { model.lastAction = "합성 행 \(index) · 열기 콜백 갱신 \(generation)" })
                        .tag(session.id).padding(.vertical, 6)
                }
            }.listStyle(.inset)
        }.padding(14).frame(minWidth: 360, minHeight: 500)
            .preferredColorScheme(model.dark ? .dark : .light)
            .onChange(of: generation, initial: true) { _, value in model.renderedGeneration = value }
    }
}

@MainActor private final class RowBenchDelegate: NSObject, NSApplicationDelegate {
    let model = RowBenchModel()
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 180, y: 120, width: 500, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "AutoApprove 합성 세션 목록"
        window.contentView = NSHostingView(rootView: RowBenchView(model: model))
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--measure") { Task { await measure() } }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !CommandLine.arguments.contains("--measure")
    }
    func cpu() -> Double {
        var value = rusage(); precondition(getrusage(RUSAGE_SELF, &value) == 0)
        return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1e6
    }
    func measure() async {
        fputs("ROW MEASURE START\n", stderr)
        try? await Task.sleep(for: .milliseconds(400))
        var phases: [[String: Any]] = []
        for mode in ["publisher", "observation", "one-title", "all-titles"] {
            fputs("ROW PHASE \(mode)\n", stderr)
            model.mode = mode; model.generation = 0
            try? await Task.sleep(for: .milliseconds(150))
            let began = ProcessInfo.processInfo.systemUptime, before = cpu()
            let rows = RowBenchCounts.rows, labels = RowBenchCounts.labels
            for generation in 1...120 {
                model.generation = generation
                try? await Task.sleep(for: .milliseconds(16))
            }
            try? await Task.sleep(for: .milliseconds(100))
            precondition(model.renderedGeneration == 120)
            phases.append(["mode": mode, "updates": 120, "cpuSeconds": cpu() - before,
                "wallSeconds": ProcessInfo.processInfo.systemUptime - began,
                "rowBodies": RowBenchCounts.rows - rows, "presentationBodies": RowBenchCounts.labels - labels,
                "latestGenerationApplied": true])
        }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        fputs("ROW TEARDOWN\n", stderr)
        window.contentView = nil; window.orderOut(nil)
        for _ in 0..<40 where RowBenchCounts.liveActions > 0 { try? await Task.sleep(for: .milliseconds(50)) }
        let report: [String: Any] = ["phases": phases, "peakResidentBytes": usage.ru_maxrss, "sessions": 24, "inputPosts": 0,
            "actionsCreated": RowBenchCounts.references.count, "actionsAliveAfterRemoval": RowBenchCounts.liveActions,
            "scope": "Actual production native row/labels, native List and fake sessions only. Four controlled 120-update workloads; no engine, listener, original terminal, OS setting or permission changes."]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        if let name = CommandLine.arguments.first(where: { $0.hasPrefix("--report=") })?.dropFirst(9) {
            try! data.write(to: URL(fileURLWithPath: String(name)), options: .atomic)
        }
        print(String(decoding: data, as: UTF8.self)); fflush(stdout)
        fputs("ROW REPORT WRITTEN\n", stderr); NSApp.terminate(nil)
    }
}

@main struct NativeSessionRowBench {
    @MainActor static func main() {
        let app = NSApplication.shared, delegate = RowBenchDelegate()
        app.setActivationPolicy(.regular); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
