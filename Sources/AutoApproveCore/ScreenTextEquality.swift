import Foundation

/// Display notifications use canonical equality; detector reuse requires exact bytes.
enum ScreenTextEquality {
    static func identical(_ previous: String?, _ current: String) -> Bool {
        guard let previous else { return false }
        // Terminal output normally changes at the bottom. Reject those frames
        // before comparing a possibly very large retained scrollback.
        if !previous.utf8.suffix(128).elementsEqual(current.utf8.suffix(128)) { return false }
        // Cocoa screen strings can compare literal UTF-16 without walking their
        // bridged UTF-8 view. Otherwise preserve the detector's exact-byte contract.
        if !previous.isContiguousUTF8 || !current.isContiguousUTF8 {
            if (previous as NSString).isEqual(to: current) { return true }
            return identicalForeign(previous as NSString, current as NSString)
        }
        return previous.utf8.elementsEqual(current.utf8)
    }

    /// A changed body can leave the footer unchanged. Bulk UTF-16 reads avoid
    /// per-scalar Cocoa calls and full-screen copies, preserving UTF-8 repair.
    private static func identicalForeign(_ left: NSString, _ right: NSString) -> Bool {
        let length = left.length
        guard length == right.length else { return false }
        return withUnsafeTemporaryAllocation(of: UInt16.self, capacity: 514) { lhs in
            withUnsafeTemporaryAllocation(of: UInt16.self, capacity: 514) { rhs in
                var offset = 0
                while offset < length {
                    let count = min(512, length - offset), start = max(0, offset - 1)
                    let end = offset + count
                    let range = NSRange(location: start, length: end - start + (end < length ? 1 : 0))
                    left.getCharacters(lhs.baseAddress!, range: range)
                    right.getCharacters(rhs.baseAddress!, range: range)
                    // One neighboring unit on each side preserves surrogate
                    // pairs split across scratch-buffer boundaries.
                    for index in (offset - start)..<(end - start) {
                        let a = lhs[index], b = rhs[index]
                        if a == b && !(0xd800...0xdfff).contains(a) { continue }
                        if repairedUnit(lhs, at: index, count: range.length) != repairedUnit(rhs, at: index, count: range.length) {
                            return false
                        }
                    }
                    offset = end
                }
                return true
            }
        }
    }

    private static func repairedUnit(_ units: UnsafeMutableBufferPointer<UInt16>, at index: Int, count: Int) -> UInt16 {
        let unit = units[index]
        if (0xd800...0xdbff).contains(unit) {
            return index + 1 < count && (0xdc00...0xdfff).contains(units[index + 1]) ? unit : 0xfffd
        }
        if (0xdc00...0xdfff).contains(unit) {
            return index > 0 && (0xd800...0xdbff).contains(units[index - 1]) ? unit : 0xfffd
        }
        return unit
    }

    static func equal(_ previous: String?, _ current: String) -> Bool {
        guard let previous else { return false }
        if !previous.isContiguousUTF8 || !current.isContiguousUTF8 {
            // Distinct leading ASCII scalars cannot become canonically equal.
            // Keep Swift's cheap early rejection ahead of foreign-string scans.
            if let lhs = previous.utf8.first, let rhs = current.utf8.first,
               lhs < 0x80, rhs < 0x80, lhs != rhs { return false }
            if (previous as NSString).isEqual(to: current) { return true }
            // Equal strings have canonically equal grapheme-cluster suffixes.
            // Reject late output changes before normalizing the long common prefix.
            if previous.suffix(128) != current.suffix(128) { return false }
        }
        return previous == current
    }
}
