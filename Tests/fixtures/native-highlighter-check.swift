import AppKit

@MainActor final class HighlighterCheckDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var label: NSTextField!
    var running = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect:NSRect(x:80,y:100,width:1040,height:700),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = "터미널 위치 표시 · 합성 검증"
        label = NSTextField(wrappingLabelWithString:"실제 터미널을 열거나 읽지 않는 합성 창입니다.")
        label.font = .systemFont(ofSize:15)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.addArrangedSubview(label)
        for (title,action) in [("테두리 표시",#selector(show)),("반복 표시 검증",#selector(check)),("작은 창",#selector(compact)),("기본 창",#selector(regular))] {
            let button = NSButton(title:title,target:self,action:action); button.bezelStyle = .rounded; stack.addArrangedSubview(button)
        }
        window.contentView!.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:28),stack.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:28),stack.trailingAnchor.constraint(lessThanOrEqualTo:window.contentView!.trailingAnchor,constant:-28)])
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        let menu = NSMenu(), item = NSMenuItem(), sub = NSMenu()
        let quit = NSMenuItem(title:"검증 앱 종료",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q"); quit.target = NSApp
        sub.addItem(quit); item.submenu = sub; menu.addItem(item); NSApp.mainMenu = menu
        if Bundle.main.object(forInfoDictionaryKey:"AutoApproveRunChecks") as? Bool == true { check() }
    }
    @objc func compact() { window.setContentSize(.init(width:784,height:612)) }
    @objc func regular() { window.setContentSize(.init(width:1040,height:700)) }
    @objc func show() {
        TerminalHighlighter.shared.show(frame:window.frame,project:"긴 한글 프로젝트 e\u{301} 🧪 · 합성 검증",detail:"Codex · /dev/synthetic-only",ownerBundleID:Bundle.main.bundleIdentifier!)
    }
    @objc func check() {
        guard !running else { return }; running = true; label.stringValue = "반복 표시·취소·재사용 검증 중"
        Task { await verify() }
    }
    func verify() async {
        var report: [String:Any] = ["terminalReads":0,"terminalInputs":0,"originalWindowsOpened":0]
        do {
            func require(_ condition: Bool, _ message: String) throws { if !condition { throw NSError(domain:message,code:1) } }
            let screens = [CGRect(x:0,y:0,width:100,height:100)]
            try require(TerminalHighlighter.visibleFrame(CGRect(x:-50,y:-50,width:200,height:200),screens:screens) == screens[0],"clip to desktop")
            try require(TerminalHighlighter.visibleFrame(CGRect(x:200,y:200,width:50,height:50),screens:screens) == nil,"offscreen rejected")
            try require(TerminalHighlighter.visibleFrame(CGRect(x:0,y:0,width:1e300,height:1e300),screens:screens) == screens[0],"huge finite frame bounded")
            for frame in [CGRect.null,CGRect.infinite,CGRect.zero,CGRect(x:CGFloat.nan,y:0,width:100,height:100),CGRect(x:0,y:0,width:CGFloat.infinity,height:100)] {
                try require(TerminalHighlighter.visibleFrame(frame,screens:screens) == nil,"invalid geometry rejected")
            }
            let original = window.frame
            var panelID: ObjectIdentifier?, contentID: ObjectIdentifier?
            for _ in 0..<12 {
                show(); try await Task.sleep(for:.milliseconds(270))
                let panels = NSApp.windows.filter { String(describing:type(of:$0)).hasSuffix("HighlightPanel") }
                try require(panels.count == 1,"only one panel")
                guard let panel = panels.first, let content = panel.contentView else { throw NSError(domain:"missing panel",code:1) }
                if let panelID { try require(ObjectIdentifier(panel) == panelID,"panel reused") }
                if let contentID { try require(ObjectIdentifier(content) == contentID,"hosting tree reused") }
                panelID = ObjectIdentifier(panel); contentID = ObjectIdentifier(content)
                try require(!panel.canBecomeKey && !panel.canBecomeMain && panel.ignoresMouseEvents,"click through and focus retained")
                try require(window.frame == original,"source frame unchanged")
            }
            TerminalHighlighter.shared.dismiss(); show(); TerminalHighlighter.shared.dismiss()
            try await Task.sleep(for:.milliseconds(300))
            try require(!NSApp.windows.contains { String(describing:type(of:$0)).hasSuffix("HighlightPanel") && $0.isVisible },"cancelled show cannot reappear")
            report.merge(["passed":true,"repeatShows":12,"maximumPanels":1,"samePanelAndHostingTree":true,"invalidAndOffscreenGeometryRejected":true,"sourceFrameUnchanged":true,"cancelledShowStaysHidden":true,"clickThroughNonKey":true]) { _,v in v }
            label.stringValue = "검증 통과 · 12회 표시 · 패널/화면 트리 1개 · 원본 크기 유지"
            window.title = "터미널 위치 표시 · 검증 통과"
        } catch {
            report["passed"] = false; report["error"] = String(describing:error); label.stringValue = "검증 실패: \(error)"; window.title = "위치 표시 검증 실패"
        }
        try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("report.json"))
        running = false
    }
}
@main struct HighlighterCheckApp {
    @MainActor static func main() {
        let app = NSApplication.shared, delegate = HighlighterCheckDelegate()
        app.setActivationPolicy(.regular); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
