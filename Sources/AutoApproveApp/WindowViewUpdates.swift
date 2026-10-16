import AppKit
import Combine
import SwiftUI

/// Gates view invalidation only. Models, approvals, notifications and networking
/// keep running, and the view reads their live values on the next visible frame.
@MainActor final class WindowViewUpdates: ObservableObject {
    @Published private(set) var isVisible = false
    private weak var window: NSWindow?
    private var windowID: ObjectIdentifier?
    private var sources: [AnyCancellable] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var displayObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var refreshScheduled = false
    private var forceRefresh = false
    private var displaySleeping = false

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false)] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.displaySleeping = asleep; self?.scheduleRefresh(force: !asleep) }
            }
            displayObservers.append((center, token))
        }
    }

    func observe(_ publishers: [ObservableObjectPublisher]) {
        sources = publishers.map { publisher in
            publisher.sink { [weak self] in
                guard let self, self.isVisible else { return }
                // Window-server occlusion notifications can arrive after
                // orderOut/miniaturize. Do not forward during that short gap.
                guard self.visibleWindow() else { self.scheduleRefresh(); return }
                self.objectWillChange.send()
            }
        }
        scheduleRefresh(force: true)
    }
    func stop() { sources.removeAll(); scheduleRefresh() }

    func attach(_ window: NSWindow?) {
        let id = window.map(ObjectIdentifier.init)
        guard windowID != id || self.window !== window else { return }
        removeObservers(); self.window = window; windowID = id
        if let window {
            let center = NotificationCenter.default
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification,
                         NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification] {
                add(center, name, object: window)
            }
            add(center, NSApplication.didHideNotification, object: NSApp)
            add(center, NSApplication.didUnhideNotification, object: NSApp)
        }
        scheduleRefresh(force: true)
    }
    private func add(_ center: NotificationCenter, _ name: Notification.Name, object: AnyObject?) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        observers.append((center, token))
    }
    private func scheduleRefresh(force: Bool = false) {
        forceRefresh = forceRefresh || force
        guard !refreshScheduled else { return }; refreshScheduled = true
        // A probe can attach during SwiftUI layout. Publish after that update,
        // coalescing all visibility notifications in the same run-loop turn.
        DispatchQueue.main.async { [weak self] in self?.refreshVisibility() }
    }
    private func refreshVisibility() {
        refreshScheduled = false
        let visible = visibleWindow()
        let changed = visible != isVisible, forced = forceRefresh
        forceRefresh = false
        if changed { isVisible = visible }
        else if visible && forced { objectWillChange.send() }
    }
    private func visibleWindow() -> Bool {
        !displaySleeping && !NSApp.isHidden && window?.isVisible == true && window?.isMiniaturized == false
            && (window?.occlusionState.contains(.visible) == true || window?.attachedSheet?.isVisible == true)
    }
    private func removeObservers() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }
    deinit { for (center, token) in observers + displayObservers { center.removeObserver(token) } }
}

@MainActor private struct WindowUpdatesProbe: NSViewRepresentable {
    let updates: WindowViewUpdates
    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView(); view.moved = { [weak updates] in updates?.attach($0) }; return view
    }
    func updateNSView(_ view: ProbeView, context: Context) { updates.attach(view.window) }
    final class ProbeView: NSView {
        var moved: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); moved?(window) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    @MainActor func windowUpdates(_ updates: WindowViewUpdates, sources: [ObservableObjectPublisher]) -> some View {
        background(WindowUpdatesProbe(updates: updates).frame(width: 0, height: 0).accessibilityHidden(true))
            .onAppear { updates.observe(sources) }
            .onDisappear { updates.stop() }
    }
}
