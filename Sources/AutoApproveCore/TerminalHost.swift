import Foundation
import Darwin

/// The app that owns an agent's PTY. Identifying a host never grants control;
/// only a connected screen host can read the screen or answer a request.
public struct TerminalHost: Equatable {
    public var kind: TerminalKind
    public var name: String?
    public var bundleID: String?
    public var orcaHandle: String?
    public init(kind: TerminalKind, name: String? = nil, bundleID: String? = nil, orcaHandle: String? = nil) {
        self.kind = kind; self.name = name; self.bundleID = bundleID; self.orcaHandle = orcaHandle
    }

    static let names: [String: String] = [
        "com.apple.Terminal": "Terminal", "com.googlecode.iterm2": "iTerm2", "com.stablyai.orca": "Orca",
        "com.microsoft.VSCode": "VS Code", "com.microsoft.VSCodeInsiders": "VS Code Insiders",
        "com.todesktop.230313mzl4w4u92": "Cursor", "com.exafunction.windsurf": "Windsurf", "com.vscodium": "VSCodium",
        "dev.warp.Warp-Stable": "Warp", "com.mitchellh.ghostty": "Ghostty", "com.github.wez.wezterm": "WezTerm",
        "net.kovidgoyal.kitty": "kitty", "org.alacritty": "Alacritty", "io.alacritty": "Alacritty", "co.zeit.hyper": "Hyper",
        "org.tabby": "Tabby", "dev.zed.Zed": "Zed", "com.raphaelamorim.rio": "Rio"
    ]
    static let programs: [String: String] = [
        "WarpTerminal": "Warp", "ghostty": "Ghostty", "WezTerm": "WezTerm", "Hyper": "Hyper", "Tabby": "Tabby",
        "rio": "Rio", "zed": "Zed", "Apple_Terminal": "Terminal", "iTerm.app": "iTerm2", "Orca": "Orca"
    ]

    /// Ancestry is conclusive and keeps Terminal and VS Code exactly as before: their sessions never
    /// read launch variables. Variables only add iTerm2, Orca and display names for other hosts.
    /// `TERM_PROGRAM` names the innermost emulator; `__CFBundleIdentifier` can be inherited from a launcher.
    static func classify(record: ProcessRecord, parents: [ProcessRecord], environment: () -> [String: String]) -> TerminalHost {
        let terminalParents = parents.prefix { $0.tty == "??" || $0.tty == record.tty }
        if terminalParents.contains(where: { $0.executable.contains("Visual Studio Code.app/") }) { return TerminalHost(kind: .vscode, bundleID: "com.microsoft.VSCode") }
        if terminalParents.contains(where: { $0.executable.hasSuffix("Terminal.app/Contents/MacOS/Terminal") }) { return TerminalHost(kind: .terminal, bundleID: "com.apple.Terminal") }
        // A PTY opened inside another terminal session (script, expect, a nested emulator) is not a host tab.
        if let owner = parents.first(where: { $0.tty != record.tty }), owner.tty != "??" { return TerminalHost(kind: .unknown) }
        let env = environment()
        // A multiplexer pane is not a host tab either. Host input could reach another pane.
        if env["TMUX"] != nil || env["TERM_PROGRAM"] == "tmux" { return TerminalHost(kind: .unknown, name: "tmux") }
        if env["STY"] != nil { return TerminalHost(kind: .unknown, name: "screen") }
        if env["ZELLIJ"] != nil { return TerminalHost(kind: .unknown, name: "Zellij") }
        let bundle = env["__CFBundleIdentifier"].flatMap { $0.isEmpty ? nil : $0 }
        let handle = env["ORCA_TERMINAL_HANDLE"].flatMap { $0.isEmpty ? nil : $0 }
        switch env["TERM_PROGRAM"] {
        case "iTerm.app"?: return TerminalHost(kind: .iterm, name: "iTerm2", bundleID: "com.googlecode.iterm2")
        // Without the app in its ancestry, the tab is unproven. Name it, never connect it.
        case "Apple_Terminal"?: return TerminalHost(kind: .unknown)
        case "Orca"?: return orca(handle)
        case "vscode"?: return TerminalHost(kind: .unknown, name: bundle.flatMap { names[$0] } ?? "VS Code", bundleID: bundle)
        case let program? where !program.isEmpty:
            return TerminalHost(kind: .unknown, name: programs[program] ?? bundle.flatMap { names[$0] } ?? program, bundleID: bundle)
        default: break
        }
        // Orca drops TERM_PROGRAM for some agent environments but always exports its pane handle.
        if handle != nil || bundle == "com.stablyai.orca" { return orca(handle) }
        if env["ITERM_SESSION_ID"] != nil || parents.contains(where: { $0.executable.contains("/iTerm2/iTermServer") }) {
            return TerminalHost(kind: .iterm, name: "iTerm2", bundleID: "com.googlecode.iterm2")
        }
        if let bundle { return TerminalHost(kind: .unknown, name: names[bundle] ?? bundle, bundleID: bundle) }
        return TerminalHost(kind: .unknown)
    }
    private static func orca(_ handle: String?) -> TerminalHost {
        // Without its pane handle an Orca terminal can be named but never addressed.
        TerminalHost(kind: handle == nil ? .unknown : .orca, name: "Orca", bundleID: "com.stablyai.orca", orcaHandle: handle)
    }
}

/// Reads only allowlisted launch variables of an agent process. Terminals export secrets such as
/// `ORCA_AGENT_HOOK_TOKEN` beside these names; no other value is retained or logged.
public enum ProcessEnvironment {
    public static let names: Set<String> = ["TERM_PROGRAM", "__CFBundleIdentifier", "ITERM_SESSION_ID", "ORCA_TERMINAL_HANDLE", "TMUX", "STY", "ZELLIJ"]

    /// KERN_PROCARGS2 layout: argc, executable path, NUL padding, argv, then environment until an empty string.
    public static func parse(_ bytes: [UInt8]) -> [String: String] {
        guard bytes.count > MemoryLayout<Int32>.size else { return [:] }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var skipped: Int32 = 0
        while index < bytes.count, skipped < argc {
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            index += 1; skipped += 1
        }
        var result: [String: String] = [:]
        while index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            guard index > start else { break }
            if let equals = bytes[start..<index].firstIndex(of: UInt8(ascii: "=")) {
                let name = String(decoding: bytes[start..<equals], as: UTF8.self)
                if names.contains(name) { result[name] = String(decoding: bytes[(equals + 1)..<index], as: UTF8.self) }
            }
            index += 1
        }
        return result
    }

    /// Returns nil unless the PID still belongs to the scanned process. Test records and reused
    /// PIDs therefore never borrow another process's terminal identity.
    public static func read(_ record: ProcessRecord) -> [String: String]? {
        guard record.pid > 0, let started = startDate(record.started) else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(record.pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              abs(Double(info.pbi_start_tvsec) - started.timeIntervalSince1970) < 2 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX], limit: Int32 = 0, length = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &limit, &length, nil, 0) == 0, limit > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(limit)), count = Int(limit)
        mib = [CTL_KERN, KERN_PROCARGS2, record.pid]
        guard sysctl(&mib, 3, &bytes, &count, nil, 0) == 0 else { return nil }
        return parse(Array(bytes.prefix(count)))
    }
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter
    }()
    private static let formatterLock = NSLock()
    static func startDate(_ started: String) -> Date? {
        formatterLock.lock(); defer { formatterLock.unlock() }
        return formatter.date(from: started)
    }
}

/// An exec'd environment does not change, so each process identity is read once.
final class ProcessEnvironmentCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [String: String]] = [:]
    func environment(_ record: ProcessRecord, reader: (ProcessRecord) -> [String: String]?) -> [String: String] {
        lock.lock()
        if let cached = values[record.key] { lock.unlock(); return cached }
        lock.unlock()
        let value = reader(record) ?? [:]
        lock.lock(); values[record.key] = value; lock.unlock()
        return value
    }
    func retain(_ keys: Set<String>) {
        lock.lock(); values = values.filter { keys.contains($0.key) }; lock.unlock()
    }
}
