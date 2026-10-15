import Foundation

/// One replacement between a common prefix and suffix. Offsets are UTF-16
/// code units, like browser String.slice and existing appearance/cursor offsets.
/// Surrogate pairs are never split; no normalization or text trimming occurs.
public struct RemoteTerminalScreenPatch: Codable, Sendable {
    public let baseRevision: String
    public let baseLength: Int
    public let prefix: Int
    public let suffix: Int
    public let text: String
    public let length: Int

    public static func make(previous: String, current: String, baseRevision: String) -> Self? {
        let before = Array(previous.utf16), after = Array(current.utf16)
        var prefix = 0, suffix = 0
        while prefix < min(before.count,after.count), before[prefix] == after[prefix] { prefix += 1 }
        func low(_ value: UInt16) -> Bool { (0xDC00...0xDFFF).contains(value) }
        if prefix > 0, prefix < min(before.count,after.count), low(before[prefix]) || low(after[prefix]) { prefix -= 1 }
        while suffix < min(before.count,after.count)-prefix,
              before[before.count-1-suffix] == after[after.count-1-suffix] { suffix += 1 }
        if suffix > 0, low(before[before.count-suffix]) { suffix -= 1 }
        // Avoid paying patch metadata for short or wholly replaced screens.
        guard prefix+suffix > baseRevision.utf8.count+256 else { return nil }
        let text = String(decoding:after[prefix..<(after.count-suffix)],as:UTF16.self)
        return Self(baseRevision:baseRevision,baseLength:before.count,prefix:prefix,suffix:suffix,text:text,length:after.count)
    }
}
