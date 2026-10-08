import Foundation

/// Codex ends a turn with this error cell when the selected model is at capacity
/// (`CodexErr::ServerOverloaded`). It does not retry; the user continues by sending a message.
public struct CodexCapacityStop: Codable, Equatable {
    public static let message = "Selected model is at capacity. Please try a different model."
    /// The message the user sent by hand after each of these stops.
    public static let resumeText = "이어서 진행하자."
    /// The error cell through the empty composer below it. The final check compares exactly this region.
    public var region: String
    /// Everything visible above the composer. A repeated failure draws a longer transcript.
    public var identity: String
    public var kind: SessionInterruption.Kind = .capacity
    public var agent: AgentKind = .codex
    public var error: String = CodexCapacityStop.message

    /// Only the newest cell above a ready, empty composer counts. Codex wraps the cell without
    /// indentation in a narrow window.
    public static func detect(_ screen: String, agent: AgentKind) -> CodexCapacityStop? {
        guard agent != .shell, ActivityDetector.detect(screen, agent: agent).phase == .idle else { return nil }
        let raw = PromptDetector.normalizedLines(screen)
        let lines = raw.map { $0.trimmingCharacters(in: .whitespaces) }
        guard !CodexResumeCheck.blocked(lines), let composer = lines.lastIndex(where: CodexResumeCheck.isComposer),
              let end = lines[..<composer].lastIndex(where: { !$0.isEmpty }) else { return nil }
        var start = end
        while start > 0, !lines[start - 1].isEmpty { start -= 1 }
        let cell = lines[start...end].joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let kind: SessionInterruption.Kind
        let lower = cell.lowercased()
        if agent == .codex, cell == "■ " + message { kind = .capacity }
        else {
            let isError = agent == .codex ? cell.hasPrefix("■ ") : cell.hasPrefix("API Error:") || cell.hasPrefix("⎿ API Error:")
            guard isError, !cell.contains("```"), !cell.contains("❯"), !cell.contains("›") else { return nil }
            if lower.contains("stream disconnected before completion") || lower.contains("connection error") ||
                lower.contains("transport error") || lower.contains("request timed out") || lower.contains("network error") {
                kind = .transport
            } else if lower.range(of:#"\b(?:401|403)\b|authentication|unauthorized|invalid api key"#,options:.regularExpression) != nil {
                kind = .authentication
            } else if lower.range(of:#"\b(?:408|429|500|502|503|504|529)\b|overloaded|rate.?limit|server error|max.?output.?tokens"#,options:.regularExpression) != nil {
                kind = .api
            } else { return nil }
        }
        var result = CodexCapacityStop(region: raw[start...composer].joined(separator: "\n"),
            identity: PromptDetector.fingerprint(raw[..<composer].joined(separator: "\n")))
        result.kind = kind; result.agent = agent; result.error = cell
        return result
    }
}

public enum ResumeDelivery: String, Codable { case sent, typed, screenChanged, missingTarget, agentMissing }

/// The same rules as `CodexResumeScript.functions`, for hosts that are read and written from Swift.
public enum CodexResumeCheck {
    public static func agent(in region: String) -> AgentKind {
        rows(region).first?.trimmingCharacters(in:.whitespaces).hasPrefix("■ ") == true ? .codex : .claude
    }
    static func isComposer(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).first.map { "›»❯".contains($0) } == true }
    /// Vim normal or replace mode would run typed text as commands; a running turn owns the composer.
    static func blocked(_ lines: [String]) -> Bool {
        lines.suffix(8).joined(separator: "\n").range(of: #"Vim: (?:Normal|Replace)|(?i:esc to interrupt)"#, options: .regularExpression) != nil
    }
    static func rows(_ text: String) -> [String] { PromptDetector.normalizedLines(text) }
    private static func composerText(_ row: String) -> String {
        String(row.trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)
    }
    /// The last error cell on screen through the composer below it.
    public static func activeRegion(_ screen: String, heading: String) -> String? {
        let rows = rows(screen)
        guard let start = rows.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == heading }),
              let end = rows[(start + 1)...].firstIndex(where: isComposer) else { return nil }
        return rows[start...end].joined(separator: "\n")
    }
    public static func ready(_ screen: String, region: String) -> Bool {
        let heading = rows(region).first?.trimmingCharacters(in: .whitespaces) ?? ""
        return !heading.isEmpty && !blocked(rows(screen).map { $0.trimmingCharacters(in: .whitespaces) })
            && activeRegion(screen, heading: heading) == rows(region).joined(separator: "\n")
    }
    private static func messages(_ rows: [String], text: String) -> Int {
        let last = rows.lastIndex(where: isComposer)
        return rows.indices.filter { $0 != last && isComposer(rows[$0]) && composerText(rows[$0]) == text }.count
    }
    /// The composer now holds something other than the stop's placeholder: the user is typing.
    public static func composerChanged(_ screen: String, region: String) -> Bool {
        let current = rows(screen)
        guard let last = current.lastIndex(where: isComposer), let stopped = rows(region).last else { return false }
        let text = composerText(current[last])
        return !text.isEmpty && text != composerText(stopped)
    }
    /// The composer still holds the text: a send that did not start a turn.
    public static func draftVisible(_ screen: String, text: String) -> Bool {
        let current = rows(screen)
        return current.lastIndex(where: isComposer).map { composerText(current[$0]) == text } ?? false
    }
    /// `draft`: only the composer of the same stop holds the text. `submitted`: the screen above the
    /// composer changed and shows the text as a message. A screen that looks unchanged proves nothing,
    /// so it stays `typed`, which is never typed again.
    public enum TypedState: String { case draft, submitted, typed }
    public static func state(before: String, after: String, region: String, text: String) -> TypedState {
        let expected = rows(region), current = rows(after)
        let heading = expected.first?.trimmingCharacters(in: .whitespaces) ?? ""
        if let last = current.lastIndex(where: isComposer), composerText(current[last]) == text {
            // A draft makes the composer taller, so only the filled rows above it must match.
            let filled: ([String]) -> [String] = { $0.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            guard let active = activeRegion(after, heading: heading).map(rows),
                  filled(Array(active.dropLast())) == filled(Array(expected.dropLast())) else { return .typed }
            return .draft
        }
        return messages(current, text: text) > 0 && transcript(current) != transcript(rows(before)) ? .submitted : .typed
    }
    private static func transcript(_ rows: [String]) -> [String] {
        Array(rows[..<(rows.lastIndex(where: isComposer) ?? rows.endIndex)])
    }
}

/// Existing tmux/PTY streams share the original foreground job and exact stopped composer.
public enum VerifiedResumeInput {
    public static func deliver(region: String, text: String, read: () throws -> String,
                              write: (String, RemoteTerminalInput) throws -> TerminalDelivery) throws -> ResumeDelivery {
        let before = try read()
        guard CodexResumeCheck.ready(before,region:region) else { return .screenChanged }
        let typed = try write(before,RemoteTerminalInput(kind:.characters,text:text))
        guard typed == .sent else {
            switch typed { case .screenChanged: return .screenChanged; case .agentMissing: return .agentMissing; default: return .missingTarget }
        }
        var state = CodexResumeCheck.TypedState.typed, after = before, reads = 0
        let until = Date().addingTimeInterval(8)
        repeat {
            Thread.sleep(forTimeInterval:0.25); after = try read(); reads += 1
            state = CodexResumeCheck.state(before:before,after:after,region:region,text:text)
        } while state == .typed && (Date() < until || reads < 3)
        if state == .submitted { return .sent }
        guard state == .draft else { return .typed }
        guard try write(after,RemoteTerminalInput(kind:.enter)) == .sent else { return .typed }
        let sentUntil = Date().addingTimeInterval(4)
        repeat {
            Thread.sleep(forTimeInterval:0.25)
            if !CodexResumeCheck.draftVisible(try read(),text:text) { return .sent }
        } while Date() < sentUntil
        return .typed
    }
}

/// Shared by the Terminal and iTerm2 scripts; `CodexResumeCheck` applies the same rules from Swift.
enum CodexResumeScript {
    static let functions = """
    function resumeRows(text) {
      const rows = String(text).normalize('NFC').replace(/\\r\\n?/g, '\\n').split('\\n');
      while (rows.length && !rows[rows.length - 1].trim()) rows.pop();
      return rows;
    }
    function isComposer(row) { return /^[›»❯]/.test(row.trim()); }
    function resumeAgent(region) { return resumeRows(region)[0].trim().startsWith('■ ') ? 'codex' : 'claude'; }
    function composerText(row) { return row.trim().slice(1).trim(); }
    function resumeBlocked(rows) { return /Vim: (?:Normal|Replace)|esc to interrupt/i.test(rows.slice(-8).map(row => row.trim()).join('\\n')); }
    function activeRegion(rows, heading) {
      let start = -1;
      for (let index = 0; index < rows.length; index++) if (rows[index].trim() === heading) start = index;
      if (start < 0) return null;
      for (let index = start + 1; index < rows.length; index++) if (isComposer(rows[index])) return rows.slice(start, index + 1);
      return null;
    }
    function lastComposer(rows) { for (let index = rows.length - 1; index >= 0; index--) if (isComposer(rows[index])) return index; return -1; }
    function resumeReady(rows, region) {
      const expected = resumeRows(region), active = activeRegion(rows, expected[0].trim());
      return !resumeBlocked(rows) && active !== null && active.join('\\n') === expected.join('\\n');
    }
    function messageCount(rows, text) {
      const last = lastComposer(rows);
      return rows.filter((row, index) => index !== last && isComposer(row) && composerText(row) === text).length;
    }
    function filledRows(rows) { return rows.map(row => row.trim()).filter(row => row).join('\\n'); }
    function transcript(rows) { const last = lastComposer(rows); return rows.slice(0, last < 0 ? rows.length : last).join('\\n'); }
    function draftShown(rows, text) { const last = lastComposer(rows); return last >= 0 && composerText(rows[last]) === text; }
    function typedState(before, after, region, text) {
      const expected = resumeRows(region);
      if (draftShown(after, text)) {
        // A draft makes the composer taller, so only the filled rows above it must match.
        const active = activeRegion(after, expected[0].trim());
        return active !== null && filledRows(active.slice(0, -1)) === filledRows(expected.slice(0, -1)) ? 'draft' : 'typed';
      }
      // Submitted at once: the screen above the composer changed and shows the text as a message.
      return messageCount(after, text) > 0 && transcript(after) !== transcript(before) ? 'submitted' : 'typed';
    }
    // Codex draws typed text after its paste timeout. A busy Terminal can take seconds per read,
    // so both waits also require a few reads, not only elapsed time.
    function awaitTypedState(read, before, region, text) {
      const until = Date.now() + 8000; let state = 'typed', reads = 0;
      do { delay(0.25); state = typedState(before, resumeRows(read()), region, text); reads++; }
      while (state === 'typed' && (Date.now() < until || reads < 3));
      return state;
    }
    function awaitDraftGone(read, text) {
      const until = Date.now() + 4000; let reads = 0;
      do { delay(0.25); reads++; if (!draftShown(resumeRows(read()), text)) return true; } while (Date.now() < until || reads < 2);
      return false;
    }
    """
}
