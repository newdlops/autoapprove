import Foundation

struct DetectionLineSuffix {
    let rows: [String]
    /// UTF-8 row starts let safety checks inspect an earlier code fence without
    /// building normalized String values for the rest of the transcript.
    let byteStarts: [Int]?
    let normalizedLineOffset: Int
}

/// Shared preparation during one frame observation. Ordinary frames keep only
/// a bounded tail; the full row arrays are materialized only for a real prompt
/// or an idle capacity check that needs transcript identity.
final class DetectionLines {
    private let screen: String
    private var rawRows: [String]?
    private var trimmedRows: [String]?
    private var suffix300: DetectionLineSuffix?
    private var cachedSourceByteCount: Int?

    var sourceByteCount: Int {
        if let cachedSourceByteCount { return cachedSourceByteCount }
        let count: Int
        if screen.isContiguousUTF8 { count = screen.utf8.count }
        else {
            // Exact non-external UTF-8 length, without building normalized rows.
            // An unconvertible NSString keeps Swift's original repair behavior.
            let encoded = (screen as NSString).lengthOfBytes(using: String.Encoding.utf8.rawValue)
            count = encoded > 0 ? encoded : screen.utf8.count
        }
        cachedSourceByteCount = count
        return count
    }

    var raw: [String] {
        if let rawRows { return rawRows }
        if screen.isContiguousUTF8, let reused = completeNativeSuffixRows() {
            rawRows = reused
            cachedSourceByteCount = screen.utf8.count
            return reused
        }
        if let prepared = screen.utf8.withContiguousStorageIfAvailable({ bytes in
            (PromptDetector.normalizedLines(screen), bytes.count)
        }) {
            rawRows = prepared.0
            cachedSourceByteCount = prepared.1
            return prepared.0
        }
        let prepared = PromptDetector.normalizedLinesAndUTF8ByteCount(screen)
        rawRows = prepared.lines
        cachedSourceByteCount = prepared.byteCount
        return prepared.lines
    }

    // Keep optional suffix metadata and its ARC work out of the common
    // foreign getter. A complete native scan owns the exact full row array.
    @inline(never)
    private func completeNativeSuffixRows() -> [String]? {
        guard let suffix300, suffix300.rows.isEmpty || suffix300.byteStarts?.first == 0 else { return nil }
        return suffix300.rows
    }

    var trimmed: [String] {
        if let trimmedRows { return trimmedRows }
        let rows = raw.map { $0.trimmingCharacters(in: .whitespaces) }
        trimmedRows = rows
        return rows
    }

    func normalizedSuffix(_ count: Int) -> DetectionLineSuffix {
        guard count > 0 else { return DetectionLineSuffix(rows: [], byteStarts: [], normalizedLineOffset: 0) }
        if count == 300, let suffix300 { return suffix300 }
        let suffix: DetectionLineSuffix
        if let rawRows {
            let start = max(0, rawRows.count - count)
            suffix = DetectionLineSuffix(rows: Array(rawRows.suffix(count)), byteStarts: nil, normalizedLineOffset: start)
        } else if let fast = screen.utf8.withContiguousStorageIfAvailable({ bytes in
            Self.scanSuffix(bytes, count: count)
        }) {
            suffix = fast
        } else {
            let rows = raw
            let start = max(0, rows.count - count)
            suffix = DetectionLineSuffix(rows: Array(rows.suffix(count)), byteStarts: nil, normalizedLineOffset: start)
        }
        if count == 300 { suffix300 = suffix }
        return suffix
    }

    func trimmedSuffix(_ count: Int) -> [String] {
        if let trimmedRows { return Array(trimmedRows.suffix(count)) }
        return normalizedSuffix(count).rows.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    func nativeCodexDialog() -> PromptDetector.NativeCodexDialog? {
        guard screen.isContiguousUTF8 else { return nil }
        return screen.utf8.withContiguousStorageIfAvailable { PromptDetector.nativeCodexDialog($0) }
    }

    func nativeCodexQuestion() -> QuestionDetector.NativeCodexQuestion? {
        // Reuse rows another detector has already materialized.
        guard rawRows == nil, suffix300 == nil, screen.isContiguousUTF8 else { return nil }
        return screen.utf8.withContiguousStorageIfAvailable { QuestionDetector.detectNativeCodex($0) }
    }

    /// Retained raw row boundaries for synchronous native menu detection.
    /// No pointer or normalized row survives the caller's borrowed-byte scope.
    static func nativeSuffixRanges(_ bytes: UnsafeBufferPointer<UInt8>) -> [Range<Int>] {
        var end = bytes.count, spans: [Range<Int>] = []
        spans.reserveCapacity(300)
        var skippingTrailingBlanks = true
        while spans.count < 300 {
            var start = end
            while start > 0, bytes[start - 1] != 10, bytes[start - 1] != 13 { start -= 1 }
            if skippingTrailingBlanks {
                let value = String(decoding: bytes[start..<end], as: UTF8.self)
                skippingTrailingBlanks = value.trimmingCharacters(in: .whitespaces).isEmpty
            }
            if !skippingTrailingBlanks { spans.append(start..<end) }
            guard start > 0 else { break }
            let delimiter = start - 1
            end = bytes[delimiter] == 10 && delimiter > 0 && bytes[delimiter - 1] == 13
                ? delimiter - 1 : delimiter
        }
        spans.reverse()
        return spans
    }

    /// Whether an unmatched code fence occurs before a row of a bounded suffix.
    /// This is called only after a possible menu/overlay was detected.
    func hasOpenCodeFence(beforeSuffixRow row: Int, in suffix: DetectionLineSuffix) -> Bool {
        let index = min(max(0, row), suffix.rows.count)
        if let byteStarts = suffix.byteStarts, byteStarts.indices.contains(index) {
            let byteOffset = byteStarts[index]
            if let parity = screen.utf8.withContiguousStorageIfAvailable({ bytes in
                Self.codeFenceParity(bytes, before: byteOffset)
            }) { return parity }
        }
        let all = raw
        let end = min(all.count, suffix.normalizedLineOffset + index)
        return all[..<end].filter { $0.hasPrefix("```") }.count % 2 == 1
    }

#if DEBUG
    var debugHasMaterializedRawRows: Bool { rawRows != nil }
    var debugHasMaterializedTrimmedRows: Bool { trimmedRows != nil }
#endif

    init(_ screen: String) { self.screen = screen }

    /// All accepted permission/choice menus contain a selected numbered row.
    /// Codex notes overlays instead require a Question header. Reject only when
    /// neither necessary row occurs in the same bounded window as the detectors.
    func mayContainInteractiveRows(agent: AgentKind) -> Bool {
        guard agent != .shell else { return false }
        guard screen.isContiguousUTF8 else { return mayContainCocoaInteractiveRows(agent: agent) }
        return screen.utf8.withContiguousStorageIfAvailable { bytes in
            var end = bytes.count, count = 0, skippingTrailingBlanks = true
            while count < 300 {
                var start = end
                while start > 0, bytes[start - 1] != 10, bytes[start - 1] != 13 { start -= 1 }
                let row = Self.interactiveRow(bytes, start: start, end: end, codex: agent == .codex)
                if row == .possible { return true }
                if row != .blank { skippingTrailingBlanks = false }
                if !skippingTrailingBlanks { count += 1 }
                guard start > 0 else { break }
                let delimiter = start - 1
                end = bytes[delimiter] == 10 && delimiter > 0 && bytes[delimiter - 1] == 13
                    ? delimiter - 1 : delimiter
            }
            return false
        } ?? true
    }

    private enum InteractiveRow: Equatable { case blank, ordinary, possible }

    /// Foreign strings keep their original UTF-16 storage. One aligned buffer
    /// supports backward row scans and forward prefix checks without per-unit
    /// Objective-C messages or a full UTF-8 copy.
    private func mayContainCocoaInteractiveRows(agent: AgentKind) -> Bool {
        let source = screen as NSString, length = source.length
        guard length > 0 else { return false }
        let codex = agent == .codex
        return withUnsafeTemporaryAllocation(of: UInt16.self, capacity: min(4096, length)) { buffer in
            var loadedStart = -1, loadedEnd = -1
            func unit(_ position: Int) -> UInt16 {
                if position < loadedStart || position >= loadedEnd {
                    loadedStart = position / buffer.count * buffer.count
                    loadedEnd = min(length, loadedStart + buffer.count)
                    source.getCharacters(buffer.baseAddress!, range: NSRange(location: loadedStart, length: loadedEnd - loadedStart))
                }
                return buffer[position - loadedStart]
            }
            func row(_ start: Int, _ end: Int) -> InteractiveRow {
                var index = start
                while index < end, unit(index) == 32 || unit(index) == 9 { index += 1 }
                guard index < end else { return .blank }
                let first = unit(index)
                if first >= 33, first < 127 {
                    if codex, first == 81 { return .possible }
                    if first != 62 { return .ordinary }
                    index += 1
                    while index < end, unit(index) == 32 || unit(index) == 9 { index += 1 }
                    guard index < end else { return .ordinary }
                    let next = unit(index)
                    if next >= 49, next <= 57 { return .possible }
                    if next >= 33, next < 127 { return .ordinary }
                }
                // Scalar slicing preserves the normalizer's repaired UTF-16
                // behavior; row boundaries never split a valid surrogate pair.
                let scalars = screen.unicodeScalars
                let from = String.Index(utf16Offset: start, in: screen)
                let to = String.Index(utf16Offset: end, in: screen)
                let value = String(scalars[from..<to])
                if value.trimmingCharacters(in: .whitespaces).isEmpty { return .blank }
                let line = value.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespaces)
                if codex, line.hasPrefix("Question") { return .possible }
                return line.range(of: #"^[›❯»>]\s*[1-9][0-9]?\.\s+"#, options: .regularExpression) == nil ? .ordinary : .possible
            }
            var end = length, count = 0, skippingTrailingBlanks = true
            while count < 300 {
                var start = end
                while start > 0, unit(start - 1) != 10, unit(start - 1) != 13 { start -= 1 }
                let value = row(start, end)
                if value == .possible { return true }
                if value != .blank { skippingTrailingBlanks = false }
                if !skippingTrailingBlanks { count += 1 }
                guard start > 0 else { break }
                let delimiter = start - 1
                end = unit(delimiter) == 10 && delimiter > 0 && unit(delimiter - 1) == 13
                    ? delimiter - 1 : delimiter
            }
            return false
        }
    }

    private static func interactiveRow(_ bytes: UnsafeBufferPointer<UInt8>, start: Int, end: Int, codex: Bool) -> InteractiveRow {
        var index = start
        while index < end, bytes[index] == 32 || bytes[index] == 9 { index += 1 }
        guard index < end else { return .blank }
        let first = bytes[index]
        if first >= 33, first < 127 {
            if codex, first == 81 { return .possible } // Question header
            if first != 62 { return .ordinary }
            index += 1
            while index < end, bytes[index] == 32 || bytes[index] == 9 { index += 1 }
            guard index < end else { return .ordinary }
            let next = bytes[index]
            if next >= 49, next <= 57 { return .possible }
            if next >= 33, next < 127 { return .ordinary }
        }
        // Unicode starts, other controls and Unicode spacing use exactly the
        // existing per-row normalization and selected-option regex semantics.
        let value = String(decoding: bytes[start..<end], as: UTF8.self)
        if value.trimmingCharacters(in: .whitespaces).isEmpty { return .blank }
        let line = value.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespaces)
        if codex, line.hasPrefix("Question") { return .possible }
        return line.range(of: #"^[›❯»>]\s*[1-9][0-9]?\.\s+"#, options: .regularExpression) == nil ? .ordinary : .possible
    }

    private static func scanSuffix(_ bytes: UnsafeBufferPointer<UInt8>, count: Int) -> DetectionLineSuffix {
        var cursorEnd = bytes.count
        var reversedRows: [String] = [], reversedStarts: [Int] = []
        reversedRows.reserveCapacity(min(count, 300)); reversedStarts.reserveCapacity(min(count, 300))
        var skippingTrailingBlankRows = true
        while reversedRows.count < count {
            var start = cursorEnd
            while start > 0, bytes[start - 1] != 10, bytes[start - 1] != 13 { start -= 1 }
            let lineBytes = bytes[start..<cursorEnd]
            let value = String(decoding: lineBytes, as: UTF8.self)
            let isBlank = value.trimmingCharacters(in: .whitespaces).isEmpty
            if !isBlank { skippingTrailingBlankRows = false }
            if !skippingTrailingBlankRows || !isBlank {
                reversedRows.append(lineBytes.allSatisfy { $0 < 0x80 } ? value : value.precomposedStringWithCanonicalMapping)
                reversedStarts.append(start)
            }
            guard start > 0 else { break }
            let delimiter = start - 1
            cursorEnd = bytes[delimiter] == 10 && delimiter > 0 && bytes[delimiter - 1] == 13
                ? delimiter - 1 : delimiter
        }
        return DetectionLineSuffix(rows: Array(reversedRows.reversed()), byteStarts: Array(reversedStarts.reversed()), normalizedLineOffset: 0)
    }

    static func codeFenceParity(_ bytes: UnsafeBufferPointer<UInt8>, before end: Int) -> Bool {
        var index = 0, lineStart = 0, count = 0
        let limit = min(end, bytes.count)
        while index < limit {
            let byte = bytes[index]
            guard byte == 10 || byte == 13 else { index += 1; continue }
            if index - lineStart >= 3, bytes[lineStart] == 96, bytes[lineStart + 1] == 96, bytes[lineStart + 2] == 96 {
                count += 1
            }
            if byte == 13, index + 1 < limit, bytes[index + 1] == 10 { index += 1 }
            index += 1; lineStart = index
        }
        return count % 2 == 1
    }
}
