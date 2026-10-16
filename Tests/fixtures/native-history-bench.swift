import AppKit
import Combine
import SwiftUI
import Darwin
import AutoApproveCore

@MainActor private final class HistoryModel: ObservableObject {
    @Published var generation = 0
    @Published var dark = false
    var renderedGeneration = -1
    var renders = 0
    let events: [AuditEvent] = (0..<40).map { index in
        var event = AuditEvent(sessionID: "synthetic", summary: "합성 기록 \(index) · 긴 요청은 펼쳐서 확인합니다.",
            outcome: "승인 입력 전달", source: "합성 시험", tool: "fixture",
            request: "SYNTHETIC FULL REQUEST \(index)\n" + String(repeating: "길이가 긴 합성 요청 · 실제로 실행하지 않습니다.\n", count: 1_000), answer: "이번 요청 허용")
        event.id = "fixture-\(index)"; return event
    }
}
@MainActor private struct HistoryView: View {
#if NATIVE_HISTORY_GATE
    let model: HistoryModel
    @StateObject private var viewUpdates = WindowViewUpdates()
#else
    @ObservedObject var model: HistoryModel
#endif
    var body: some View {
#if NATIVE_HISTORY_GATE
        content.windowUpdates(viewUpdates, sources: [model.objectWillChange])
#else
        content
#endif
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("최근 승인 내역 · 합성 화면").font(.headline)
                Spacer()
                Button(model.dark ? "밝게 보기" : "어둡게 보기") { model.dark.toggle() }
            }
            Text("40개 합성 기록 · 갱신 \(model.generation)").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.events) { original in
                        let event = updated(original)
                        ApprovalEventDisclosure(event: event)
                        Divider()
                    }
                }
            }
        }.padding(24).frame(minWidth: 420, minHeight: 360)
            .preferredColorScheme(model.dark ? .dark : .light)
            .onChange(of: model.generation, initial: true) { _, value in
                model.renderedGeneration = value; model.renders += 1
            }
    }
    private func updated(_ original: AuditEvent) -> AuditEvent {
        var event = original; event.outcome += model.generation.isMultiple(of: 2) ? "" : " · 확인됨"; return event
    }
}
@MainActor private final class HistoryDelegate: NSObject, NSApplicationDelegate {
    let model = HistoryModel()
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 200, y: 180, width: 720, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "AutoApprove 합성 승인 내역"
        window.contentView = NSHostingView(rootView: HistoryView(model: model))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--measure") { Task { await measure() } }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !CommandLine.arguments.contains("--measure")
    }
    private func cpu() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    private func measure() async {
        try? await Task.sleep(for: .milliseconds(400))
        var phases: [[String: Any]] = []
        for visible in [true, false] {
            if visible { window.orderFront(nil) } else { window.orderOut(nil) }
            try? await Task.sleep(for: .milliseconds(150))
            let before = cpu(), start = ProcessInfo.processInfo.systemUptime, renders = model.renders
            for generation in 0..<120 {
                model.generation = generation + (visible ? 0 : 1000)
                try? await Task.sleep(for: .milliseconds(12))
            }
            phases.append(["visible": visible, "updates": 120, "cpuSeconds": cpu() - before,
                "wallSeconds": ProcessInfo.processInfo.systemUptime - start, "renders": model.renders - renders])
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .milliseconds(200))
        let latestOnReveal = model.renderedGeneration == model.generation
        model.generation = 2000
        try? await Task.sleep(for: .milliseconds(150))
        let continuesAfterReveal = model.renderedGeneration == model.generation
        window.miniaturize(nil)
        try? await Task.sleep(for: .milliseconds(300))
        model.generation = 2001
        try? await Task.sleep(for: .milliseconds(150))
        window.deminiaturize(nil); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .milliseconds(300))
        let latestAfterMinimize = model.renderedGeneration == model.generation
        NSApp.hide(nil)
        try? await Task.sleep(for: .milliseconds(200))
        model.generation = 2002
        try? await Task.sleep(for: .milliseconds(150))
        NSApp.unhide(nil); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .milliseconds(300))
        let latestAfterAppHide = model.renderedGeneration == model.generation
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let report: [String: Any] = ["phases": phases, "peakResidentBytes": usage.ru_maxrss, "events": model.events.count,
            "latestOnReveal": latestOnReveal, "continuesAfterReveal": continuesAfterReveal,
            "latestAfterMinimize": latestAfterMinimize, "latestAfterAppHide": latestAfterAppHide]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        if let path = CommandLine.arguments.first(where: { $0.hasPrefix("--report=") })?.dropFirst(9) {
            try! data.write(to: URL(fileURLWithPath: String(path)), options: .atomic)
        }
        print(String(decoding: data, as: UTF8.self)); fflush(stdout)
        NSApp.terminate(nil)
    }
}
@main struct NativeHistoryBench {
    @MainActor static func main() {
        let app = NSApplication.shared, delegate = HistoryDelegate()
        app.setActivationPolicy(.regular); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
