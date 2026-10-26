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
        if let prepared = previous.utf8.withContiguousStorageIfAvailable({ before in
            current.utf8.withContiguousStorageIfAvailable { after in
                NativePatch(value: Self.native(before, after, baseRevision: baseRevision))
            }
        }) ?? nil { return prepared.value }
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

    private struct NativePatch { let value: RemoteTerminalScreenPatch? }

    /// Count UTF16 units in a complete-scalar UTF8 span without transcoding.
    /// Continuations contribute zero; four-byte leads contribute two.
    private static func nativeUnits(_ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> Int {
        var index = range.lowerBound, count = 0
        while range.upperBound - index >= 8 {
            let word = UnsafeRawPointer(bytes.baseAddress!).loadUnaligned(fromByteOffset: index, as: UInt64.self)
            let continuation = (word & ~(word << 1)) & 0x8080808080808080
            let four = (word & (word << 1) & (word << 2) & (word << 3)) & 0x8080808080808080
            count += 8 - continuation.nonzeroBitCount + four.nonzeroBitCount
            index += 8
        }
        while index < range.upperBound {
            let byte = bytes[index]
            if byte < 0x80 || byte >= 0xc0 { count += byte >= 0xf0 ? 2 : 1 }
            index += 1
        }
        return count
    }

    private static func native(_ before: UnsafeBufferPointer<UInt8>, _ after: UnsafeBufferPointer<UInt8>, baseRevision: String) -> Self? {
        let shared = min(before.count, after.count), threshold = baseRevision.utf8.count + 256
        guard shared > threshold else { return nil } // UTF16 length never exceeds UTF8 length.
        var prefix = 0, suffix = 0
        while shared - prefix >= 8 {
            let a = UnsafeRawPointer(before.baseAddress!).loadUnaligned(fromByteOffset: prefix, as: UInt64.self)
            let b = UnsafeRawPointer(after.baseAddress!).loadUnaligned(fromByteOffset: prefix, as: UInt64.self)
            guard a == b else { break }; prefix += 8
        }
        while prefix < shared, before[prefix] == after[prefix] { prefix += 1 }
        func continuation(_ byte: UInt8) -> Bool { byte & 0xc0 == 0x80 }
        while prefix > 0 && ((prefix < before.count && continuation(before[prefix])) || (prefix < after.count && continuation(after[prefix]))) { prefix -= 1 }
        while shared - prefix - suffix >= 8 {
            let a = UnsafeRawPointer(before.baseAddress!).loadUnaligned(fromByteOffset: before.count - suffix - 8, as: UInt64.self)
            let b = UnsafeRawPointer(after.baseAddress!).loadUnaligned(fromByteOffset: after.count - suffix - 8, as: UInt64.self)
            guard a == b else { break }; suffix += 8
        }
        while suffix < shared - prefix, before[before.count - suffix - 1] == after[after.count - suffix - 1] { suffix += 1 }
        while suffix > 0 && (continuation(before[before.count - suffix]) || continuation(after[after.count - suffix])) { suffix -= 1 }
        let prefixUnits = nativeUnits(before, 0..<prefix)
        let suffixUnits = nativeUnits(before, (before.count - suffix)..<before.count)
        guard prefixUnits + suffixUnits > threshold else { return nil }
        let beforeMiddle = prefix..<(before.count - suffix), afterMiddle = prefix..<(after.count - suffix)
        return Self(baseRevision: baseRevision, baseLength: prefixUnits + nativeUnits(before, beforeMiddle) + suffixUnits,
                    prefix: prefixUnits, suffix: suffixUnits, text: String(decoding: after[afterMiddle], as: UTF8.self),
                    length: prefixUnits + nativeUnits(after, afterMiddle) + suffixUnits)
    }
}
