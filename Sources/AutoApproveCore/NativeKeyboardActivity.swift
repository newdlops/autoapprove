import AppKit
import CoreGraphics
import Foundation

package final class KeyboardActivitySampler: @unchecked Sendable {
    package struct Sample: Sendable {
        let idle: TimeInterval
        let flags: CGEventFlags
        let bundle: String?
        package init(idle:TimeInterval,flags:CGEventFlags,bundle:String?) { self.idle=idle; self.flags=flags; self.bundle=bundle }
    }
    private let lock = NSLock()
    private let clock: @Sendable () -> TimeInterval
    private let query: @Sendable () -> Sample
    private var latest: (Sample,TimeInterval)?
    private var active = false
    private var lastDemand: TimeInterval = 0
    package init(clock:@escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, query:@escaping @Sendable () -> Sample) {
        self.clock = clock; self.query = query
    }
    package func sample() -> Sample? {
        lock.lock()
        let now = clock()
        lastDemand = now
        let result = latest.flatMap { (0..<0.1).contains(now-$0.1) ? $0.0 : nil }
        let start = !active
        active = true
        lock.unlock()
        if start {
            Thread.detachNewThread { [self] in
                Thread.current.name = "AutoApprove keyboard activity"
                while true {
                    let began = clock()
                    let value = autoreleasepool(invoking:query)
                    let keep = lock.withLock {
                        if clock()-lastDemand > 2 { active = false; latest = nil; return false }
                        latest = value.idle.isFinite && value.idle >= 0 && value.bundle != nil ? (value,began) : nil
                        return true
                    }
                    if !keep { return }
                    Thread.sleep(forTimeInterval:0.035)
                }
            }
        }
        return result
    }
}

public struct NativeKeyboardActivity:Sendable {
    private var sampler: KeyboardActivitySampler?
    public var idleSeconds:@Sendable()->TimeInterval
    public var modifierFlags:@Sendable()->CGEventFlags
    public var frontmostBundle:@Sendable()->String?
    public var inputTargetTTY:@Sendable(TerminalKind)->String?
    public init(idleSeconds:@escaping @Sendable()->TimeInterval,frontmostBundle:@escaping @Sendable()->String?,modifierFlags:@escaping @Sendable()->CGEventFlags = {[]},inputTargetTTY:@escaping @Sendable(TerminalKind)->String? = {_ in nil}) {
        self.modifierFlags = modifierFlags;self.idleSeconds = idleSeconds;self.frontmostBundle = frontmostBundle
        self.inputTargetTTY=inputTargetTTY
    }
    public static let inactive = Self(idleSeconds:{.infinity},frontmostBundle:{nil})
    public static let live: Self = {
        let sampler = KeyboardActivitySampler {
            let down = CGEventSource.secondsSinceLastEventType(.hidSystemState,eventType:.keyDown)
            let up = CGEventSource.secondsSinceLastEventType(.hidSystemState,eventType:.keyUp)
            return .init(idle:min(down,up),flags:CGEventSource.flagsState(.hidSystemState),bundle:NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        }
        var value = Self(idleSeconds:{sampler.sample()?.idle ?? 0},frontmostBundle:{sampler.sample()?.bundle},modifierFlags:{sampler.sample()?.flags ?? []},inputTargetTTY:{ kind in
            guard kind == .terminal else {return nil}
            return try? TerminalAppleEvents.keyboardTargetTTY()
        })
        value.sampler = sampler
        return value
    }()
    func prepare(_ terminal:TerminalKind) {
        guard ![.pty,.claudeBackground,.unknown].contains(terminal) else { return }
        _ = sampler?.sample()
    }

    func waitForSample(_ terminal:TerminalKind) async {
        guard let sampler, ![.pty,.claudeBackground,.unknown].contains(terminal) else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.1
        while sampler.sample() == nil && ProcessInfo.processInfo.systemUptime < deadline && !Task.isCancelled {
            try? await Task.sleep(for:.milliseconds(8))
        }
    }
    public func hasPriority(terminal:TerminalKind,tty:String) -> Bool {
        if sampler != nil && AutomationIPC.shared.blocksWrites(terminal.title) { return true }
        if let sampler, sampler.sample() == nil { return ![.pty,.claudeBackground,.unknown].contains(terminal) }
        guard hasPriority(terminal:terminal) else {return false}
        guard let active=inputTargetTTY(terminal),active.hasPrefix("/dev/") else {return true}
        if let sampler, sampler.sample() == nil { return true }
        return active == tty
    }
    public func hasPriority(terminal:TerminalKind) -> Bool {
        guard ![.pty,.claudeBackground,.unknown].contains(terminal) else {return false}
        if sampler != nil && AutomationIPC.shared.blocksWrites(terminal.title) { return true }
        let sample = sampler?.sample()
        if sampler != nil && sample == nil { return true }
        let idle = sample?.idle ?? idleSeconds()
        let held = !(sample?.flags ?? modifierFlags()).intersection([.maskShift,.maskControl,.maskAlternate,.maskCommand]).isEmpty
        guard held || (idle.isFinite && idle >= 0 && idle < 1.5),let bundle = sample?.bundle ?? frontmostBundle() else {return false}
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
