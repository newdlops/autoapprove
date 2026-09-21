import AppKit
import SwiftUI

/// A short-lived, click-through marker. Keyboard focus stays in the revealed terminal.
@MainActor final class TerminalHighlighter {
    static let shared = TerminalHighlighter()
    private var panel: HighlightPanel?
    private var lifetime: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?

    func show(frame: CGRect, project: String, detail: String, ownerBundleID: String) {
        dismiss()
        guard frame.width > 0, frame.height > 0,
              NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) else { return }
        lifetime = Task { [weak self] in
            // Allow activation and a minimized-window restoration to finish before marking its location.
            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            guard let self, !Task.isCancelled else { return }
            let panel = HighlightPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "선택한 터미널 · \(project)"
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false; panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.contentView = NSHostingView(rootView: TerminalHighlight(project: project, detail: detail))
            self.panel = panel
            panel.orderFrontRegardless()
            self.activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if app?.bundleIdentifier != ownerBundleID { Task { @MainActor in self?.dismiss() } }
            }
            NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [
                .announcement: "\(project), \(detail) 터미널을 열었습니다.", .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ])
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                await NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    panel.animator().alphaValue = 0
                }
            }
            guard !Task.isCancelled, self.panel === panel else { return }
            self.dismiss()
        }
    }

    func dismiss() {
        lifetime?.cancel(); lifetime = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        panel?.orderOut(nil); panel?.close(); panel = nil
    }
}

private final class HighlightPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct TerminalHighlight: View {
    let project: String
    let detail: String
    var body: some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(nsColor: .systemBlue), lineWidth: 5)
                .overlay(alignment: .top) {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.up.forward.app.fill").font(.system(size: 18, weight: .semibold))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("열린 터미널 · \(project)").font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                            Text(detail).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 10)
                    .frame(maxWidth: min(460, max(0, geometry.size.width - 32)), alignment: .leading)
                    .background(Color(nsColor: NSColor.systemBlue.blended(withFraction: 0.2, of: .black) ?? .systemBlue), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 8)
                }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}
