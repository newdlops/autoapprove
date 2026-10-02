import Foundation
import IOKit
import IOKit.ps

/// Sleep, lid and power state that macOS reports to any process, read without privileges.
public struct PowerReading: Equatable, Sendable {
    /// `pmset disablesleep`. While it is on, macOS sleeps for nothing: not a closed lid, the Apple menu or a low battery.
    public var sleepDisabled: Bool
    public var lidClosed: Bool
    /// macOS sleeps when this lid closes. An external display on power keeps the Mac awake by itself.
    public var lidCausesSleep: Bool
    public var onBattery: Bool
    public var batteryPercent: Int?
    public var thermal: ProcessInfo.ThermalState
    public init(sleepDisabled: Bool = false, lidClosed: Bool = false, lidCausesSleep: Bool = true, onBattery: Bool = false,
                batteryPercent: Int? = nil, thermal: ProcessInfo.ThermalState = .nominal) {
        self.sleepDisabled = sleepDisabled; self.lidClosed = lidClosed; self.lidCausesSleep = lidCausesSleep
        self.onBattery = onBattery; self.batteryPercent = batteryPercent; self.thermal = thermal
    }
}

/// The watchdog process for one hold.
public struct KeepAwakeGuard: Sendable {
    public var isRunning: @Sendable () -> Bool
    public var stop: @Sendable () -> Void
    public init(isRunning: @escaping @Sendable () -> Bool, stop: @escaping @Sendable () -> Void) {
        self.isRunning = isRunning; self.stop = stop
    }
}

/// Everything that reads or changes macOS sleep. While the setting is off and nothing is held, only `ruleFile` runs.
public struct PowerControl: Sendable {
    public var read: @Sendable () -> PowerReading
    /// The installed rule lets this user run the commands without a password. It runs `sudo -n -l`, so call it rarely.
    public var ruleInstalled: @Sendable () -> Bool
    /// The rule file is in place: a plain file check for the settings window.
    public var ruleFile: @Sendable () -> Bool
    /// Each asks for an administrator password.
    public var installRule: @Sendable () throws -> Void
    public var removeRule: @Sendable () throws -> Void
    public var setSleepDisabled: @Sendable (Bool) throws -> Void
    public var sleepNow: @Sendable () throws -> Void
    /// Watches a hold from outside AutoApprove: `marker`, then the battery floor.
    public var startGuard: @Sendable (String, Int) throws -> KeepAwakeGuard
    public init(read: @escaping @Sendable () -> PowerReading, ruleInstalled: @escaping @Sendable () -> Bool, ruleFile: @escaping @Sendable () -> Bool,
                installRule: @escaping @Sendable () throws -> Void, removeRule: @escaping @Sendable () throws -> Void,
                setSleepDisabled: @escaping @Sendable (Bool) throws -> Void, sleepNow: @escaping @Sendable () throws -> Void,
                startGuard: @escaping @Sendable (String, Int) throws -> KeepAwakeGuard) {
        self.read = read; self.ruleInstalled = ruleInstalled; self.ruleFile = ruleFile; self.installRule = installRule
        self.removeRule = removeRule; self.setSleepDisabled = setSleepDisabled; self.sleepNow = sleepNow; self.startGuard = startGuard
    }

    public static let live = PowerControl(
        read: { KeepAwake.liveReading() },
        ruleInstalled: { KeepAwake.liveRuleInstalled() },
        ruleFile: { FileManager.default.fileExists(atPath: KeepAwake.rulePath) },
        installRule: { try KeepAwake.runAsAdministrator(KeepAwake.installScript(user: NSUserName()), prompt: KeepAwake.installPrompt) },
        removeRule: { try KeepAwake.runAsAdministrator(KeepAwake.removeScript, prompt: KeepAwake.removePrompt) },
        setSleepDisabled: { try KeepAwake.pmsetAsRoot(["-a", "disablesleep", $0 ? "1" : "0"]) },
        sleepNow: { try KeepAwake.pmsetAsRoot(["sleepnow"]) },
        startGuard: { try KeepAwake.launchGuard(script: KeepAwake.guardScript(), marker: $0, floor: $1) })
}

public struct KeepAwakeStatus: Codable, Equatable {
    public enum Phase: String, Codable { case off, checking, setup, ready, holding, lowBattery, hot, external, failed }
    public var phase: Phase
    public var detail: String
    public var enabled: Bool
    /// The rule file is in place, so the settings window can offer to remove it.
    public var ruleFile: Bool
    public var working = 0
    /// After the last work ends, the hold lasts until this time.
    public var releaseAt: Date?
    public init(phase: Phase, detail: String, enabled: Bool, ruleFile: Bool, working: Int = 0, releaseAt: Date? = nil) {
        self.phase = phase; self.detail = detail; self.enabled = enabled; self.ruleFile = ruleFile
        self.working = working; self.releaseAt = releaseAt
    }
}

public enum KeepAwake {
    public static let rulePath = "/private/etc/sudoers.d/autoapprove-keepawake"
    public static let sudo = "/usr/bin/sudo"
    public static let pmset = "/usr/bin/pmset"
    /// The only commands the rule runs without a password.
    public static let commands = ["\(pmset) -a disablesleep 0", "\(pmset) -a disablesleep 1", "\(pmset) sleepnow"]
    static let installPrompt = "AutoApprove가 덮개를 닫아도 작업을 계속할 수 있도록, 잠자기 금지 설정(pmset disablesleep)과 잠자기만 실행할 수 있는 권한 규칙을 설치합니다."
    static let removePrompt = "AutoApprove가 설치한 잠자기 금지 권한 규칙을 제거합니다."

    /// Sessions that keep the Mac awake: auto-approved while not paused, and visibly working, waiting for an approval
    /// AutoApprove will answer, or about to continue after a capacity stop. Unknown screens and questions for the user don't count.
    public static func working(_ sessions: [AgentSession], paused: Bool) -> [AgentSession] {
        guard !paused else { return [] }
        return sessions.filter { session in
            guard session.automatic, session.agent != .shell, session.phase != .ended else { return false }
            if let resume = session.capacityResume?.phase, [.scheduled, .sending, .awaiting].contains(resume) { return true }
            let members = [session] + session.backgroundChildren.filter { $0.phase != .ended }
            if members.contains(where: { $0.phase == .working }) { return true }
            return members.contains { $0.phase == .approval } && !AttentionRequest.needsAttention(session, paused: paused)
        }
    }

    public static func rule(user: String) throws -> String {
        guard user.range(of: #"^[A-Za-z_][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil else {
            throw AppError.message("사용자 이름 ‘\(user)’로는 권한 규칙을 만들 수 없습니다.")
        }
        return "# Installed by AutoApprove: lets \(user) keep the Mac awake with the lid closed.\n"
            + "\(user) ALL=(root) NOPASSWD: \(commands.joined(separator: ", "))\n"
    }

    /// Runs as root after the password prompt. sudo ignores file names containing a dot, so the rule is
    /// checked under a temporary dotted name and only then moved into place.
    public static func installScript(user: String) throws -> String {
        let lines = try rule(user: user).split(separator: "\n").map { "'\($0)'" }.joined(separator: " ")
        return """
        set -eu
        tmp=$(/usr/bin/mktemp /private/etc/sudoers.d/.autoapprove.XXXXXX)
        trap '/bin/rm -f "$tmp"' EXIT
        /usr/bin/printf '%s\\n' \(lines) > "$tmp"
        /usr/sbin/chown root:wheel "$tmp"
        /bin/chmod 0440 "$tmp"
        /usr/sbin/visudo -cf "$tmp" >/dev/null
        /bin/mv -f "$tmp" \(rulePath)
        """
    }
    public static let removeScript = "/bin/rm -f \(rulePath)"

    public static func appleScriptLiteral(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    public static func administratorScript(_ shell: String, prompt: String) -> String {
        "do shell script \(appleScriptLiteral(shell)) with prompt \(appleScriptLiteral(prompt)) with administrator privileges"
    }
    /// osascript reads the script from standard input, so the Korean prompt stays composed.
    static func runAsAdministrator(_ shell: String, prompt: String) throws {
        let result = try CommandRunner.run("/usr/bin/osascript", [], timeout: 600, input: Data(administratorScript(shell, prompt: prompt).utf8))
        guard result.status == 0 else {
            if result.error.contains("-128") { throw AppError.message("관리자 암호 입력을 취소했습니다.") }
            throw AppError.message("관리자 권한으로 실행하지 못했습니다. \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
    /// `sudo -n -l` lists the rule without a password under the usual defaults. Where it still asks, turning off a
    /// disablesleep that is already off proves the rule and changes nothing.
    static func liveRuleInstalled() -> Bool {
        if (try? CommandRunner.run(sudo, ["-n", "-l", pmset, "-a", "disablesleep", "1"], timeout: 5).status) == 0 { return true }
        guard FileManager.default.fileExists(atPath: rulePath), !liveReading().sleepDisabled else { return false }
        return (try? CommandRunner.run(sudo, ["-n", pmset, "-a", "disablesleep", "0"], timeout: 5).status) == 0
    }
    static func pmsetAsRoot(_ arguments: [String]) throws {
        let result = try CommandRunner.run(sudo, ["-n", pmset] + arguments, timeout: 15)
        guard result.status == 0 else {
            let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppError.message(message.contains("password") ? "관리자 권한 규칙이 없거나 바뀌었습니다. 설정에서 끄고 다시 켜서 설치해주세요."
                : "pmset \(arguments.joined(separator: " ")) 실패: \(message)")
        }
    }

    public struct GuardTools: Sendable {
        public var sudo: String
        public var pmset: String
        public var ioreg: String
        public var interval: Double
        /// A hung AutoApprove stops touching the marker; this long without a touch also ends the hold.
        public var heartbeatLimit: Int
        public init(sudo: String = KeepAwake.sudo, pmset: String = KeepAwake.pmset, ioreg: String = "/usr/sbin/ioreg",
                    interval: Double = 10, heartbeatLimit: Int = 300) {
            self.sudo = sudo; self.pmset = pmset; self.ioreg = ioreg; self.interval = interval; self.heartbeatLimit = heartbeatLimit
        }
    }

    /// Ends the hold when AutoApprove exits, stops its heartbeat or the battery reaches the floor, then sleeps a Mac
    /// whose closed lid would have slept it. Arguments: the marker, AutoApprove's PID, the battery floor.
    /// A failed release keeps the marker and tries again on the next round.
    public static func guardScript(_ tools: GuardTools = GuardTools()) -> String {
        let sudo = shellQuoted(tools.sudo), pmset = shellQuoted(tools.pmset), ioreg = shellQuoted(tools.ioreg)
        return """
        marker=$1 app=$2 floor=$3
        release() {
          [ -f "$marker" ] || exit 0
          \(sudo) -n \(pmset) -a disablesleep 0 >/dev/null 2>&1 || return 1
          /bin/rm -f "$marker"
          lid=$(\(ioreg) -r -k AppleClamshellState -d 1 2>/dev/null)
          case $lid in *'"AppleClamshellState" = Yes'*)
            case $lid in *'"AppleClamshellCausesSleep" = Yes'*) \(sudo) -n \(pmset) sleepnow >/dev/null 2>&1;; esac;;
          esac
          exit 0
        }
        while [ -f "$marker" ]; do
          kill -0 "$app" 2>/dev/null || release
          modified=$(/usr/bin/stat -f %m "$marker" 2>/dev/null) || modified=$(/bin/date +%s)
          [ $(( $(/bin/date +%s) - modified )) -gt \(tools.heartbeatLimit) ] && release
          battery=$(\(pmset) -g batt 2>/dev/null)
          case $battery in *"'Battery Power'"*)
            percent=$(printf '%s\\n' "$battery" | /usr/bin/sed -n 's/.*[^0-9]\\([0-9][0-9]*\\)%;.*/\\1/p' | /usr/bin/head -n 1)
            [ -n "$percent" ] && [ "$percent" -le "$floor" ] && release;;
          esac
          /bin/sleep \(tools.interval)
        done
        """
    }
    static func shellQuoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
    }
    public static func launchGuard(script: String, marker: String, floor: Int, app: Int32 = getpid()) throws -> KeepAwakeGuard {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "autoapprove-keep-awake", marker, String(app), String(floor)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let box = ProcessBox(process)
        return KeepAwakeGuard(isRunning: { box.process.isRunning }, stop: { if box.process.isRunning { box.process.terminate() } })
    }

    static func liveReading() -> PowerReading {
        var reading = PowerReading(thermal: ProcessInfo.processInfo.thermalState)
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        if root != IO_OBJECT_NULL {
            defer { IOObjectRelease(root) }
            func flag(_ key: String) -> Bool? {
                IORegistryEntryCreateCFProperty(root, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
            }
            reading.sleepDisabled = flag("SleepDisabled") ?? false
            reading.lidClosed = flag("AppleClamshellState") ?? false
            reading.lidCausesSleep = flag("AppleClamshellCausesSleep") ?? true
        }
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            reading.onBattery = (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) == kIOPSBatteryPowerValue
            for source in (IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]) ?? [] {
                guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                      let current = description[kIOPSCurrentCapacityKey] as? Int,
                      let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
                reading.batteryPercent = current * 100 / maximum
            }
        }
        return reading
    }
}

/// Serializes every change to macOS sleep. The marker file records that AutoApprove, not the user, turned it on,
/// and its modification time is the heartbeat the guard watches.
final class KeepAwakeSwitch: @unchecked Sendable {
    let control: PowerControl
    let marker: String
    private let queue = DispatchQueue(label: "local.autoapprove.keep-awake")
    /// Touched only on `queue`.
    private var watchdog: KeepAwakeGuard?

    init(control: PowerControl, marker: String) { self.control = control; self.marker = marker }

    var owned: Bool { FileManager.default.fileExists(atPath: marker) }

    /// The marker first, then the change. A failed change keeps the marker only if sleep did end up disabled.
    func hold(floor: Int) async throws {
        try await perform {
            if !self.owned, !FileManager.default.createFile(atPath: self.marker, contents: nil, attributes: [.posixPermissions: 0o600]) {
                throw AppError.message("잠자기 금지 기록 파일을 만들지 못했습니다.")
            }
            do { try self.control.setSleepDisabled(true) } catch {
                if !self.control.read().sleepDisabled { try? FileManager.default.removeItem(atPath: self.marker) }
                throw error
            }
            try self.watch(floor)
        }
    }

    /// A hold from an earlier run, or a guard that exited: keep one watching.
    func keepWatching(floor: Int) async throws { try await perform { try self.watch(floor) } }

    /// The change first, then the marker, so a failed release is retried. Returns why a requested sleep failed.
    func release(sleep: Bool) async throws -> String? {
        try await perform {
            try self.control.setSleepDisabled(false)
            try? FileManager.default.removeItem(atPath: self.marker)
            self.watchdog?.stop(); self.watchdog = nil
            guard sleep else { return nil }
            do { try self.control.sleepNow(); return nil } catch { return error.localizedDescription }
        }
    }

    /// Sleep was enabled again elsewhere, by the guard or by the user: the marker no longer means anything.
    func forget() async {
        try? await perform {
            if !self.control.read().sleepDisabled { try? FileManager.default.removeItem(atPath: self.marker) }
            self.watchdog?.stop(); self.watchdog = nil
        }
    }

    /// App termination: waits for a change in flight, then releases without sleeping. After a failed release the
    /// guard keeps running; it sees AutoApprove gone and tries again.
    func releaseNow() {
        queue.sync {
            if owned {
                guard (try? control.setSleepDisabled(false)) != nil else { return }
                try? FileManager.default.removeItem(atPath: marker)
            }
            watchdog?.stop(); watchdog = nil
        }
    }

    func heartbeat() { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: marker) }

    private func watch(_ floor: Int) throws {
        if watchdog?.isRunning() == true { return }
        watchdog = try control.startGuard(marker, floor)
    }

    private func perform<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
}
