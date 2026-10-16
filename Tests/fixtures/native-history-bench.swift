import AppKit
import Combine
import SwiftUI
import Darwin
import AutoApproveCore

@MainActor private final class HistoryModel: ObservableObject {
    @Published var generation = 0
    @Published var dark = false
    let events: [AuditEvent] = (0..<40).map { index in
        var event = AuditEvent(sessionID: "synthetic", summary: "합성 기록 \(index) · 긴 요청은 펼쳐서 확인합니다.",
            outcome: "승인 입력 전달", source: "합성 시험", tool: "fixture",
            request: "SYNTHETIC FULL REQUEST \(index)\n" + String(repeating: "길이가 긴 합성 요청 · 실제로 실행하지 않습니다.\n", count: 1_000), answer: "이번 요청 허용")
        event.id = "fixture-\(index)"; return event
    }
}
@MainActor private struct HistoryView: View {
    @ObservedObject var model: HistoryModel
    var body: some View {
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
            let before = cpu(), start = ProcessInfo.processInfo.systemUptime
            for generation in 0..<120 {
                model.generation = generation
                try? await Task.sleep(for: .milliseconds(12))
            }
            phases.append(["visible": visible, "updates": 120, "cpuSeconds": cpu() - before,
                "wallSeconds": ProcessInfo.processInfo.systemUptime - start])
        }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let report: [String: Any] = ["phases": phases, "peakResidentBytes": usage.ru_maxrss, "events": model.events.count]
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
