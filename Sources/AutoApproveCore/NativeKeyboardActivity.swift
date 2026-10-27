import AppKit
import CoreGraphics
import Foundation

/// Content-free physical-input activity. No event tap, key codes, text,
/// keyboard recording or additional input-monitoring permission is needed.
public struct NativeKeyboardActivity:Sendable {
    public var idleSeconds:@Sendable()->TimeInterval
    public var frontmostBundle:@Sendable()->String?
    public init(idleSeconds:@escaping @Sendable()->TimeInterval,frontmostBundle:@escaping @Sendable()->String?) {
        self.idleSeconds = idleSeconds;self.frontmostBundle = frontmostBundle
    }
    public static let inactive = Self(idleSeconds:{.infinity},frontmostBundle:{nil})
    public static let live = Self(idleSeconds:{
        min(CGEventSource.secondsSinceLastEventType(.hidSystemState,eventType:.keyDown),
            CGEventSource.secondsSinceLastEventType(.hidSystemState,eventType:.keyUp))
    },frontmostBundle:{NSWorkspace.shared.frontmostApplication?.bundleIdentifier})
    public func hasPriority(terminal:TerminalKind) -> Bool {
        guard ![.pty,.claudeBackground,.unknown].contains(terminal) else {return false}
        let idle = idleSeconds()
        guard idle.isFinite,idle >= 0,idle < 1.2,let bundle = frontmostBundle() else {return false}
        switch terminal {
        case .terminal:return bundle == ScreenHost.terminal.bundleID
        case .iterm:return bundle == ScreenHost.iterm.bundleID
        case .orca:return bundle == ScreenHost.orca.bundleID
        case .vscode:return VSCodeWindowAdapter.supportsBundle(bundle)
        case .tmux:return [ScreenHost.terminal.bundleID,ScreenHost.iterm.bundleID,ScreenHost.orca.bundleID].contains(bundle) || VSCodeWindowAdapter.supportsBundle(bundle)
        default:return false
        }
    }
}
