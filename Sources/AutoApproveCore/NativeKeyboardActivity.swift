import AppKit
import CoreGraphics
import Foundation

/// Content-free physical-input activity. No event tap, key codes, text,
/// keyboard recording or additional input-monitoring permission is needed.
public struct NativeKeyboardActivity:Sendable {
    public var idleSeconds:@Sendable()->TimeInterval
    public var modifierFlags:@Sendable()->CGEventFlags
    public var frontmostBundle:@Sendable()->String?
    public var inputTargetTTY:@Sendable(TerminalKind)->String?
    public init(idleSeconds:@escaping @Sendable()->TimeInterval,frontmostBundle:@escaping @Sendable()->String?,modifierFlags:@escaping @Sendable()->CGEventFlags = {[]},inputTargetTTY:@escaping @Sendable(TerminalKind)->String? = {_ in nil}) {
        self.modifierFlags = modifierFlags;self.idleSeconds = idleSeconds;self.frontmostBundle = frontmostBundle
        self.inputTargetTTY=inputTargetTTY
    }
    public static let inactive = Self(idleSeconds:{.infinity},frontmostBundle:{nil})
    public static let live = Self(idleSeconds:{
        min(CGEventSource.secondsSinceLastEventType(.hidSystemState,eventType:.keyDown),
            CGEventSource.secondsSinceLastEventType(.hidSystemState,eventType:.keyUp))
    },frontmostBundle:{NSWorkspace.shared.frontmostApplication?.bundleIdentifier},modifierFlags:{CGEventSource.flagsState(.hidSystemState)},inputTargetTTY:{ kind in
        guard kind == .terminal else {return nil}
        return try? TerminalAppleEvents.keyboardTargetTTY()
    })
    /// Background Apple-event commands protect the actual keyboard target.
    /// Unknown focus retains the conservative application-wide guard.
    public func hasPriority(terminal:TerminalKind,tty:String) -> Bool {
        guard hasPriority(terminal:terminal) else {return false}
        guard let active=inputTargetTTY(terminal),active.hasPrefix("/dev/") else {return true}
        return active == tty
    }
    public func hasPriority(terminal:TerminalKind) -> Bool {
        guard ![.pty,.claudeBackground,.unknown].contains(terminal) else {return false}
        let idle = idleSeconds()
        let held = !modifierFlags().intersection([.maskShift,.maskControl,.maskAlternate,.maskCommand]).isEmpty
        guard held || (idle.isFinite && idle >= 0 && idle < 1.5),let bundle = frontmostBundle() else {return false}
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
