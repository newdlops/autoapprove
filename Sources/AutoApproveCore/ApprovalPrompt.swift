import Foundation
import CryptoKit

public struct ApprovalPrompt: Equatable, Sendable {
    public var summary: String
    public var answer: String
    public var fingerprint: String
    public var dialog: String
    public var identity: String { PromptDetector.fingerprint(dialog) }
    /// Request content before the choices, independent of terminal wrapping and shortcut labels.
    /// Used only to suppress duplicates; delivery still validates the complete original dialog.
    public var requestIdentity: String
    /// A known request boundary lets a consecutive dialog retire the preceding reservation.
    public var hasRequestBoundary: Bool = true
}

public enum PromptDetector {
    private static let hexDigits = Array("0123456789abcdef".utf8)
    public static func fingerprint(_ screen: String) -> String {
        var hex: [UInt8] = []; hex.reserveCapacity(64)
        for byte in SHA256.hash(data: Data(screen.utf8)) {
            hex.append(hexDigits[Int(byte >> 4)]); hex.append(hexDigits[Int(byte & 15)])
        }
        return String(decoding: hex, as: UTF8.self)
    }
    /// Matches complete, active CLI permission dialogs. Arbitrary yes/no text is never sufficient.
    public static func detect(_ screen: String, agent: AgentKind) -> ApprovalPrompt? {
        detect(screen, agent: agent, prepared: DetectionLines(screen))
    }

    static func detect(_ screen: String, agent: AgentKind, prepared: DetectionLines) -> ApprovalPrompt? {
        guard agent != .shell else { return nil }
        // A permission heading is only accepted within the final 300 rows.
        // Search that bounded suffix first so normal build output never creates
        // normalized String rows for its entire scrollback.
        guard permissionHeading(prepared, agent: agent) != nil else { return nil }
        let rawLines = prepared.raw, lines = prepared.trimmed
        guard let heading = permissionHeading(lines, agent: agent) else { return nil }
        let promptIndex = heading.index
        // A long command can push its title beyond the old 32-line window.
        guard lines.count - promptIndex <= 300 else { return nil }
        let dialog = Array(lines[promptIndex...]), indents = rawLines[promptIndex...].map { $0.prefix { $0 == " " }.count }
        guard let selectedYes = dialog.firstIndex(where: { $0.range(of: #"^[›❯»>]\s*1\.\s+"#, options: .regularExpression) != nil }) else { return nil }
        let rows = optionRows(dialog, indents: indents, from: selectedYes)
        let lastOption = rows.last ?? selectedYes
        guard let footerStart = dialogFooterStart(in: dialog, after: lastOption) else { return nil }
        guard rows.filter({ dialog[$0].range(of: #"^[›❯»>]"#, options: .regularExpression) != nil }).count == 1 else { return nil }
        var labels: [String] = [], labelColumn = 0
        for index in selectedYes..<footerStart {
            let line = dialog[index]
            if rows.contains(index) {
                let prefix = "^[›❯»>]?\\s*" + String(labels.count + 1) + #"\.\s+"#
                guard let range = line.range(of: prefix, options: .regularExpression) else { return nil }
                labels.append(String(line[range.upperBound...]))
                labelColumn = indents[index] + line.distance(from: line.startIndex, to: range.upperBound)
            } else if !line.isEmpty {
                // Narrow terminal windows can wrap a permission scope onto another line. Wrapped
                // text keeps the label's column and may start with `>`; a selection cursor may not.
                guard indents[index] >= labelColumn || line.range(of: #"^[›❯»>]"#, options: .regularExpression) == nil else { return nil }
                labels[labels.count - 1] += " " + line
            }
        }
        if agent == .codex, heading.marker == "Allow " || heading.marker == "Approve app tool call?" {
            guard YesNoConfirmation.isToolPermissionMenu(labels) else { return nil }
        }
        guard YesNoConfirmation.singleApprovalIndex(labels) == 0 else { return nil }
        let summary = dialog.prefix(selectedYes).filter { !$0.isEmpty }.joined(separator: "\n")
        guard !dialog.contains(where: { $0.contains("```") }), !summary.isEmpty,
              lines[..<promptIndex].filter({ $0.hasPrefix("```") }).count % 2 == 0 else { return nil }
        // Claude prints the command/edit before its confirmation heading. Keep that context in validation.
        let start = agent == .claude ? 0 : promptIndex
        let context = rawLines[start..<(promptIndex + selectedYes)].joined(separator: "\n")
        // A Claude panel puts its command/file before the confirmation heading. Bound its
        // identity at a known panel title so scrollback changes cannot replay that request.
        // Unknown panel layouts keep the conservative reservation until work is observed.
        let requestStart = agent == .claude ? claudePanelStart(lines, before: promptIndex, marker: heading.marker) : promptIndex
        let identityContext = rawLines[(requestStart ?? start)..<(promptIndex + selectedYes)].joined(separator: "\n")
        let compactIdentity = identityContext.filter {
            // Keep Character whitespace semantics for CRLF and combined scalars.
            if let ascii = $0.asciiValue { return ascii != 32 && (ascii < 9 || ascii > 13) }
            return !$0.isWhitespace
        }
        return ApprovalPrompt(summary: String(context.suffix(4000)), answer: "1", fingerprint: fingerprint(screen),
            dialog: rawLines[start...].joined(separator: "\n"), requestIdentity: fingerprint(compactIdentity),
            hasRequestBoundary: requestStart != nil)
    }

    public static func normalizedLines(_ screen: String) -> [String] {
        let scalars = screen.unicodeScalars
        var lines: [String] = []
        lines.reserveCapacity(64)
        var start = scalars.startIndex
        var index = start
        var lineIsASCII = true
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar.value == 10 || scalar.value == 13 {
                let line = String(scalars[start..<index])
                lines.append(lineIsASCII ? line : line.precomposedStringWithCanonicalMapping)
                lineIsASCII = true
                if scalar.value == 13 {
                    let next = scalars.index(after: index)
                    if next < scalars.endIndex, scalars[next].value == 10 { index = next }
                }
                index = scalars.index(after: index)
                start = index
            } else {
                lineIsASCII = lineIsASCII && scalar.isASCII
                index = scalars.index(after: index)
            }
        }
        let line = String(scalars[start..<scalars.endIndex])
        lines.append(lineIsASCII ? line : line.precomposedStringWithCanonicalMapping)
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        return lines
    }

    /// Bulk UTF-16 reads avoid per-scalar Objective-C calls for Cocoa frames.
    /// Scratch storage is bounded; byte counts precede NFC and trailing-row removal.
    static func normalizedLinesAndUTF8ByteCount(_ screen: String) -> (lines: [String], byteCount: Int) {
        let source = screen as NSString
        let length = source.length
        guard length > 0 else { return ([], 0) }
        return withUnsafeTemporaryAllocation(of: UInt16.self, capacity: min(4096, length)) { buffer in
            var lines: [String] = []; lines.reserveCapacity(64)
            var totalBytes = 0, rowBytes = 0, rowStart = 0, offset = 0
            var rowASCII = true, previousHigh = false, afterCR = false, invalid = false

            func appendRow(endingAt end: Int) {
                let range = NSRange(location: rowStart, length: end - rowStart)
                guard range.length > 0 else { lines.append(""); return }
                var encoded = false
                var line = ""
                if !invalid {
                    line = String(unsafeUninitializedCapacity: rowBytes) { output in
                        var used = 0, remaining = NSRange(location: 0, length: 0)
                        let success = source.getBytes(output.baseAddress, maxLength: output.count,
                            usedLength: &used, encoding: String.Encoding.utf8.rawValue, options: [],
                            range: range, remaining: &remaining)
                        encoded = success && used == rowBytes && remaining.length == 0
                        return encoded ? used : 0
                    }
                }
                if !encoded {
                    // Preserve the previous replacement-scalar behavior without
                    // copying an entire malformed row into a second UTF-16 array.
                    let scalars = screen.unicodeScalars
                    let start = String.Index(utf16Offset: range.location, in: screen)
                    let end = String.Index(utf16Offset: range.location + range.length, in: screen)
                    line = String(scalars[start..<end])
                }
                lines.append(rowASCII ? line : line.precomposedStringWithCanonicalMapping)
            }

            while offset < length {
                let count = min(buffer.count, length - offset)
                source.getCharacters(buffer.baseAddress!, range: NSRange(location: offset, length: count))
                for index in 0..<count {
                    let unit = buffer[index], position = offset + index
                    let high = unit >= 0xd800 && unit <= 0xdbff
                    let low = unit >= 0xdc00 && unit <= 0xdfff
                    if (previousHigh && !low) || (low && !previousHigh) { invalid = true }
                    // A high surrogate starts as a 3-byte replacement. A paired
                    // low adds one byte, including pairs split across buffers.
                    let width = unit < 0x80 ? 1 : unit < 0x800 ? 2 : low && previousHigh ? 1 : 3
                    totalBytes += width
                    previousHigh = high
                    if unit == 10 || unit == 13 {
                        if unit == 10 && afterCR { rowStart = position + 1; afterCR = false; continue }
                        appendRow(endingAt: position)
                        rowStart = position + 1; rowBytes = 0; rowASCII = true; invalid = false
                        afterCR = unit == 13
                    } else {
                        rowBytes += width; rowASCII = rowASCII && unit < 0x80; afterCR = false
                    }
                }
                offset += count
            }
            if previousHigh { invalid = true }
            appendRow(endingAt: length)
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            return (lines, totalBytes)
        }
    }
    static func permissionMarkers(_ agent: AgentKind) -> [String] {
        agent == .codex
            ? ["Would you like to run the following command?", "Would you like to make the following edits?", codexTerminalInputMarker, "Approve app tool call?", "Allow "]
            : ["Do you want to proceed?", "Do you want to make this edit", "Do you want to create", "Do you want to allow"]
    }
    private static let codexTerminalInputMarker = "Would you like to send input to terminal "
    private static let codexHeadings = permissionMarkers(.codex).map { (marker: $0, compact: $0.filter { !$0.isWhitespace }) }
    private static let claudeHeadings = permissionMarkers(.claude).map { (marker: $0, compact: $0.filter { !$0.isWhitespace }) }
    /// Join only a complete, contiguous heading prefix. This accepts word/character wrapping
    /// without completing an ellipsis, crossing blank rows or consuming menu choices.
    static func permissionHeading(_ lines: [String], agent: AgentKind) -> (index: Int, end: Int, marker: String)? {
        permissionHeading(count: lines.count, lineAt: { lines[$0] }, agent: agent)
    }

    static func permissionHeading(_ prepared: DetectionLines, agent: AgentKind) -> (index: Int, end: Int, marker: String)? {
        let suffix = prepared.normalizedSuffix(300)
        return permissionHeading(count: suffix.rows.count, lineAt: { suffix.rows[$0] }, agent: agent)
    }

    private static func permissionHeading(count: Int, lineAt: (Int) -> String,
                                          agent: AgentKind) -> (index: Int, end: Int, marker: String)? {
        let headings = agent == .codex ? codexHeadings : claudeHeadings
        for index in (0..<count).reversed() {
            let first = lineAt(index).trimmingCharacters(in: .whitespaces)
            // Ordinary output and menu rows cannot start one of the ASCII headings.
            // Reject them before regex checks or rebuilding every marker for every row.
            guard let initial = first.first, headings.contains(where: { $0.compact.first == initial }) else { continue }
            let compact = first.filter { !$0.isWhitespace }
            let candidates = headings.filter { $0.compact.hasPrefix(compact) || compact.hasPrefix($0.compact) }
            guard !candidates.isEmpty, !isOption(first), !first.contains("```") else { continue }
            for (marker, expected) in candidates {
                var candidate = compact
                for row in index..<min(count, index + 8) {
                    let line = lineAt(row).trimmingCharacters(in: .whitespaces)
                    if row != index {
                        guard !line.isEmpty, !isOption(line), !line.contains("```") else { break }
                        candidate += line.filter { !$0.isWhitespace }
                    }
                    if candidate.hasPrefix(expected) {
                        if marker == codexTerminalInputMarker {
                            // The terminal ID and closing question mark must be present. Either
                            // can wrap, but an incomplete title or unrelated question cannot match.
                            let terminal = String(candidate.dropFirst(expected.count))
                            if terminal.range(of: #"^[0-9]+\?$"#, options: .regularExpression) != nil {
                                return (index, row, marker)
                            }
                            guard terminal.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { break }
                            continue
                        }
                        // `Allow ` is a word prefix, not `Allowing` or another question.
                        if marker == "Allow ", !first.hasPrefix("Allow "), first != "Allow" { break }
                        return (index, row, marker)
                    }
                    if !expected.hasPrefix(candidate) { break }
                }
            }
        }
        return nil
    }

    private static func claudePanelStart(_ lines: [String], before heading: Int, marker: String) -> Int? {
        let titles = ["Do you want to proceed?": "Bash command", "Do you want to create": "Create file", "Do you want to make this edit": "Edit file"]
        guard let title = titles[marker], let start = lines[..<heading].lastIndex(of: title), heading - start <= 300 else { return nil }
        // A panel title from an earlier dialog is not a boundary for this request.
        if let previous = permissionHeading(Array(lines[..<heading]), agent: .claude), previous.index >= start { return nil }
        guard lines[..<start].filter({ $0.hasPrefix("```") }).count % 2 == 0 else { return nil }
        return start
    }
    static let optionPrefix = #"^[›❯»>]?\s*[1-9][0-9]?\.\s+"#
    static func isOption(_ line: String) -> Bool {
        // An ASCII option number or selection cursor must be the first nonspace
        // character. Ordinary output cannot match, so avoid its regex work entirely.
        guard let first = line.first, first.isWhitespace || "›❯»>123456789".contains(first) else { return false }
        return line.range(of: optionPrefix, options: .regularExpression) != nil
    }
    /// A new option starts left of the previous label. A long label wraps at that label's
    /// column, where its text can look like a selection cursor (`=>`, `> file`) or `2. …`.
    static func optionRows(_ lines: [String], indents: [Int], from start: Int) -> [Int] {
        var rows: [Int] = [], labelColumn = Int.max
        for index in start..<lines.count where indents[index] < labelColumn {
            guard let prefix = lines[index].range(of: optionPrefix, options: .regularExpression) else { continue }
            rows.append(index)
            labelColumn = indents[index] + lines[index].distance(from: lines[index].startIndex, to: prefix.upperBound)
        }
        return rows
    }
    static func isDialogFooter(_ line: String) -> Bool {
        line.range(of: #"(?i)^(?:(?:press )?enter to (?:confirm|select|submit)|esc to cancel|tab to amend|ctrl-g to edit|tab/arrow keys to navigate|o to open thread)"#, options: .regularExpression) != nil
            || line.allSatisfy { "─━╌- ".contains($0) }
    }

    /// The final option and the keyboard hint can both wrap in a narrow terminal.
    /// Require the entire remaining hint so later output cannot revive a stale dialog.
    static func dialogFooterStart(in lines: [String], after lastOption: Int) -> Int? {
        guard lastOption + 1 < lines.count else { return nil }
        // Claude Code 2.1.28x adds `· Tab to amend` while Yes or No is selected. Codex adds
        // `or o to open thread` when a sub-agent's request is shown in the parent session.
        let action = #"(?:(?:press\s+)?enter\s+to\s+(?:confirm|select|submit)|esc\s+to\s+cancel|tab\s+to\s+amend|ctrl-g\s+to\s+edit|tab/arrow\s+keys\s+to\s+navigate|o\s+to\s+open\s+thread)"#
        let pattern = "(?i)^" + action + #"(?:(?:\s*(?:[,·•|/]|or|and)\s*|\s+)"# + action + #")*[.!]?$"#
        guard let start = ((lastOption + 1)..<lines.count).first(where: {
            lines[$0].range(of: #"(?i)^(?:press|enter|esc|ctrl-g|tab/arrow)(?:\s|$)"#, options: .regularExpression) != nil
        }) else { return nil }
        let hint = lines[start...].filter { !$0.isEmpty && !$0.allSatisfy { "─━╌- ".contains($0) } }.joined(separator: " ")
        return hint.range(of: pattern, options: .regularExpression) != nil ? start : nil
    }
}
