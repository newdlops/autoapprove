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
        if (!previous.isContiguousUTF8 || !current.isContiguousUTF8),
           (previous as NSString).isEqual(to: current) { return true }
        return previous.utf8.elementsEqual(current.utf8)
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
