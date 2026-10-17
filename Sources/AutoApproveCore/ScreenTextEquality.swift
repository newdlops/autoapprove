import Foundation

/// Canonical equality for display-change notifications. Exact detector identity
/// continues to use the separate UTF-8 comparison in ScreenAnalysis.
enum ScreenTextEquality {
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
