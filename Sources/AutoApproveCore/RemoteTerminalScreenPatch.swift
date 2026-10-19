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
        let before = previous.utf16, after = current.utf16
        let beforeCount = before.count, afterCount = after.count
        let sharedCount = min(beforeCount, afterCount)
        var prefix = 0, suffix = 0
        var beforePrefix = before.startIndex, afterPrefix = after.startIndex
        while prefix < sharedCount, before[beforePrefix] == after[afterPrefix] {
            before.formIndex(after: &beforePrefix); after.formIndex(after: &afterPrefix); prefix += 1
        }
        func low(_ value: UInt16) -> Bool { (0xDC00...0xDFFF).contains(value) }
        if prefix > 0, prefix < sharedCount, low(before[beforePrefix]) || low(after[afterPrefix]) {
            before.formIndex(before: &beforePrefix); after.formIndex(before: &afterPrefix); prefix -= 1
        }
        var beforeSuffix = before.endIndex, afterSuffix = after.endIndex
        while suffix < sharedCount-prefix {
            let previousUnit = before.index(beforeSuffix, offsetBy: -1)
            let currentUnit = after.index(afterSuffix, offsetBy: -1)
            guard before[previousUnit] == after[currentUnit] else { break }
            beforeSuffix = previousUnit; afterSuffix = currentUnit; suffix += 1
        }
        if suffix > 0, low(before[beforeSuffix]) {
            before.formIndex(after: &beforeSuffix); after.formIndex(after: &afterSuffix); suffix -= 1
        }
        // Avoid paying patch metadata for short or wholly replaced screens.
        guard prefix+suffix > baseRevision.utf8.count+256 else { return nil }
        let text = String(decoding:after[afterPrefix..<afterSuffix],as:UTF16.self)
        return Self(baseRevision:baseRevision,baseLength:beforeCount,prefix:prefix,suffix:suffix,text:text,length:afterCount)
    }
}
