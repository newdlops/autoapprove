import Foundation

/// Agent-independent rules for operating Mac apps without taking the user's
/// keyboard focus or mouse. Claude and Codex adapters share these rules; only
/// the tool-name mapping differs per agent.
public enum BackgroundDesktopPolicy {
    /// Typing into these apps could run shell commands, change approvals or
    /// expose credentials outside the agent's own permission prompts.
    public static let blockedBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp", "com.mitchellh.ghostty",
        "org.alacritty", "net.kovidgoyal.kitty", "com.github.wez.wezterm", "co.zeit.hyper", "org.tabby",
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
        "dev.zed.Zed", "com.apple.dt.Xcode",
        "local.autoapprove.mac", "com.anthropic.claudefordesktop", "com.anthropic.claude", "com.openai.chat", "com.openai.codex",
        "com.apple.systempreferences", "com.apple.Settings", "com.apple.keychainaccess", "com.apple.Passwords",
        "com.apple.SecurityAgent", "com.apple.loginwindow", "com.apple.coreautha", "com.1password.1password", "com.bitwarden.desktop"
    ]

    public static func blockReason(bundleID: String?, name: String) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return "\(name)의 번들 ID를 확인하지 못해 조작하지 않습니다." }
        let lower = bundleID.lowercased()
        if blockedBundleIDs.contains(bundleID) || lower.contains("computer-use") || lower.contains("computeruse") || lower.hasPrefix("com.jetbrains.") {
            return "\(name)은(는) 터미널, 개발 도구, 보안이나 에이전트 앱이라 백그라운드 조작을 허용하지 않습니다."
        }
        return nil
    }

    /// Accessibility actions that act on one element without activating its app.
    /// AXRaise is excluded: it reorders windows on the user's screen.
    public static let elementActions: Set<String> = ["AXPress", "AXConfirm", "AXCancel", "AXIncrement", "AXDecrement"]

    public static let secureRoles: Set<String> = ["AXSecureTextField"]

    /// Roles that only group other elements. A snapshot omits them when they
    /// carry no label, value or action, so the tree stays readable.
    public static let containerRoles: Set<String> = ["AXGroup", "AXSplitGroup", "AXScrollArea", "AXLayoutArea", "AXLayoutItem", "AXUnknown", "AXGenericElement"]
}

/// Keys delivered to one process. Shortcuts with ⌘ or ⌃ go through the menu
/// system, which ignores a background app, so the tool reports that limit.
public enum BackgroundDesktopKeys {
    public static let virtualKeys: [String: UInt16] = [
        "return": 36, "enter": 76, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46
    ]
    public static let modifiers: Set<String> = ["shift", "option", "control", "command"]

    public static func virtualKey(_ name: String) -> UInt16? {
        virtualKeys[name.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "")]
    }

    /// Text is sent one character per event. Line breaks and tabs become their
    /// keys because many text views ignore a control character as Unicode text.
    public enum Stroke: Equatable { case text(String), key(UInt16) }
    public static func strokes(_ text: String) -> [Stroke] {
        text.replacingOccurrences(of: "\r\n", with: "\n").map { character in
            switch character {
            case "\n", "\r": return .key(36)
            case "\t": return .key(48)
            default: return .text(String(character))
            }
        }
    }
}

/// Agent-independent classification of a computer-use action name.
/// Observation never moves the pointer or changes the active app.
public enum ComputerUseAction {
    private static let observing: Set<String> = ["screenshot", "zoom", "cursor_position", "wait", "list_granted_applications"]
    public static func isObservation(_ action: String) -> Bool {
        observing.contains(action.lowercased())
    }
}
