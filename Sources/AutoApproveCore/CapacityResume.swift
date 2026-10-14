import Foundation

/// Codex ends a turn with this error cell when the selected model is at capacity
/// (`CodexErr::ServerOverloaded`). It does not retry; the user continues by sending a message.
public struct CodexCapacityStop: Codable, Equatable, Sendable {
    public static let message = "Selected model is at capacity. Please try a different model."
    /// The message the user sent by hand after each of these stops.
    public static let resumeText = "이어서 진행하자."
    public static let goalResumeText = "/goal resume"
    /// The error cell through the empty composer below it. The final check compares exactly this region.
    public var region: String
    /// Everything visible above the composer. A repeated failure draws a longer transcript.
    public var identity: String
    /// A redraw that only changes spacing or wrapping is the same failure. The raw
    /// identity and region remain available for exact input validation and legacy receipts.
    public var continuationIdentity: String?
    var legacyContinuationKey: String { continuationIdentity ?? identity }
    var continuationKey: String { continuationText == Self.goalResumeText ? "goal:" + legacyContinuationKey : legacyContinuationKey }
    public var kind: SessionInterruption.Kind = .capacity
    public var agent: AgentKind = .codex
    public var error: String = CodexCapacityStop.message
    /// Older persisted stops have no override. A stalled Goal needs its lifecycle command.
    public var inputText: String?
    /// Footer captured before typing; everything above it in the composer must
    /// contain only this request, including wrapping and empty trailing lines.
    public var composerFooter: String?
    public var continuationText: String { inputText ?? Self.resumeText }

    /// Only the newest cell above a ready, empty composer counts. Codex wraps the cell without
    /// indentation in a narrow window.
    public static func detect(_ screen: String, agent: AgentKind) -> CodexCapacityStop? {
        guard agent != .shell else { return nil }
        return detect(screen, agent: agent, activity: ActivityDetector.detect(screen, agent: agent), prepared: DetectionLines(screen))
    }

    /// A frame's activity and permission analysis are shared by the engine's detectors.
    static func detect(_ screen: String, agent: AgentKind, activity: ActivityObservation,
                       prepared: @autoclosure () -> DetectionLines) -> CodexCapacityStop? {
        guard agent != .shell, activity.phase == .idle else { return nil }
        let frame = prepared(), raw = frame.raw, lines = frame.trimmed
        guard !CodexResumeCheck.blocked(lines), let composer = lines.lastIndex(where: CodexResumeCheck.isComposer) else { return nil }
        guard agent != .codex || !CodexResumeCheck.goalHeld(lines) else { return nil }
        let end = lines[..<composer].lastIndex(where: { !$0.isEmpty })
        var start = end ?? composer
        while start > 0, end != nil, !lines[start - 1].isEmpty { start -= 1 }
        let cell = end.map { lines[start...$0].joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") } ?? ""
        let kind: SessionInterruption.Kind
        if let errorKind = errorKind(cell, agent: agent) { kind = errorKind }
        else if agent == .codex, CodexResumeCheck.goalStalled(lines) { kind = .goalBlocked }
        else { return nil }
        let transcript = raw[..<composer].joined(separator: "\n")
        // Blocked is a lifecycle footer, not an API error cell. Keep its exact
        // composer and footer together for the final validation before typing.
        let region = kind == .goalBlocked ? raw[composer...].joined(separator: "\n") : raw[start...composer].joined(separator: "\n")
        var result = CodexCapacityStop(region: region,
            identity: PromptDetector.fingerprint(transcript))
        result.continuationIdentity = PromptDetector.fingerprint(transcript.components(separatedBy: .whitespacesAndNewlines).joined())
        result.kind = kind; result.agent = agent; result.error = kind == .goalBlocked ? "Goal blocked · /goal resume로 현재 목표의 상태를 다시 확인합니다." : cell
        result.composerFooter = raw.dropFirst(composer + 1).joined(separator: "\n")
        if agent == .codex, kind.retryable, CodexResumeCheck.goalStalled(lines) { result.inputText = goalResumeText }
        return result
    }

    private static func errorKind(_ cell: String, agent: AgentKind) -> SessionInterruption.Kind? {
        let compact = cell.lowercased().filter { !$0.isWhitespace }
        if agent == .codex, ["■selectedmodelisatcapacity", "■selectedmodelisatcapacity.",
                            ("■ " + message).lowercased().filter({ !$0.isWhitespace })].contains(compact) { return .capacity }
        let isError = agent == .codex ? cell.hasPrefix("■ ") :
            ["API Error:", "⎿ API Error:", "Error:", "⎿ Error:"].contains(where: cell.hasPrefix)
        guard isError, !cell.contains("```"), !cell.contains("❯"), !cell.contains("›") else { return nil }
        // Explicit account failures win even when wrapped in a transport error.
        if cell.range(of: #"(?i)\b(?:401|403)\b"#, options: .regularExpression) != nil ||
            ["authentication", "unauthorized", "invalidapikey", "invalid_api_key", "oauth_org_not_allowed"].contains(where: compact.contains) { return .authentication }
        if cell.range(of: #"\b(?:400|402|404|422)\b"#, options: .regularExpression) != nil ||
            ["billing_error", "billingerror", "insufficient_quota", "insufficientquota", "account_on_hold", "model_not_found", "modelnotfound", "invalid_request", "context_length_exceeded", "contextlengthexceeded"].contains(where: compact.contains) { return .configuration }
        if ["streamdisconnectedbeforecompletion", "connectionerror", "transporterror", "requesttimedout", "networkerror",
            "connectionreset", "connectionrefused", "connectionclosed", "error-decodingresponsebody", "errordecodingresponsebody",
            "failedtosendrequest", "error-sendingrequest", "errorsendingrequest", "reconnectfailed", "streamclosed", "socketclosed",
            "requesttimeout", "deadlineexceeded", "connectionaborted", "brokenpipe"].contains(where: compact.contains) { return .transport }
        if cell.range(of: #"\b(?:408|429|500|502|503|504|529)\b"#, options: .regularExpression) != nil ||
            ["overloaded", "ratelimit", "rate_limit", "servererror", "server_error", "max_output_tokens", "maxoutputtokens",
             "internalservererror", "temporarilyunavailable", "anerroroccurredwhileprocessingyourrequest"].contains(where: compact.contains) { return .api }
        // An actual CLI error cell can introduce a new provider wording. Keep its
        // classification generic instead of silently leaving that turn stopped.
        return .api
    }
}

public enum ResumeDelivery: String, Codable { case sent, draft, typed, screenChanged, missingTarget, agentMissing }

/// The same rules as `CodexResumeScript.functions`, for hosts that are read and written from Swift.
public enum CodexResumeCheck {
    public static func agent(in region: String) -> AgentKind {
        let current = rows(region)
        return current.first?.trimmingCharacters(in:.whitespaces).hasPrefix("■ ") == true || goalStalled(current) ? .codex : .claude
    }
    static func isComposer(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).first.map { "›»❯".contains($0) } == true }
    /// Vim normal or replace mode would run typed text as commands; a running turn owns the composer.
    static func blocked(_ lines: [String]) -> Bool {
        lines.suffix(8).joined(separator: "\n").range(of: #"Vim: (?:Normal|Replace)|(?i:esc to interrupt)"#, options: .regularExpression) != nil
    }
    static func rows(_ text: String) -> [String] { PromptDetector.normalizedLines(text) }
    private static func footer(_ rows: [String]) -> String {
        guard let last = rows.lastIndex(where: isComposer) else { return "" }
        return rows.dropFirst(last + 1).joined(separator: "\n")
    }
    static func goalStalled(_ rows: [String]) -> Bool {
        let compact = footer(rows).filter { !$0.isWhitespace }
        return compact.contains("Goalstalled(/goalresume)") || compact.contains("Goalblocked(/goalresume)")
    }
    static func goalHeld(_ rows: [String]) -> Bool {
        footer(rows).filter { !$0.isWhitespace }.range(of: #"Goal(?:paused|hitusagelimits|hitbudget|budget|achieved|abandoned)"#, options: .regularExpression) != nil
    }
    private static func running(_ rows: [String]) -> Bool {
        rows.suffix(8).joined(separator: "\n").range(of: #"(?i)(?:esc|ctrl\+c) to (?:interrupt|stop)|tab to queue"#, options: .regularExpression) != nil
    }
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
    public static func ready(_ screen: String, region: String, text: String? = nil) -> Bool {
        let expected = rows(region), current = rows(screen)
        let heading = expected.first?.trimmingCharacters(in: .whitespaces) ?? ""
        if let text, CodexCapacityStop.detect(screen, agent: agent(in: region))?.continuationText != text { return false }
        if goalStalled(expected) {
            guard !goalHeld(current), !blocked(current), let composer = current.lastIndex(where: isComposer),
                  ActivityDetector.detect(screen, agent: .codex).phase == .idle else { return false }
            return Array(current[composer...]) == expected
        }
        return !heading.isEmpty && !blocked(current.map { $0.trimmingCharacters(in: .whitespaces) })
            && activeRegion(screen, heading: heading) == rows(region).joined(separator: "\n")
    }
    private static func messages(_ rows: [String], text: String) -> Int {
        let last = running(rows) ? nil : rows.lastIndex(where: isComposer)
        return rows.indices.filter { $0 != last && isComposer(rows[$0]) && composerText(rows[$0]) == text }.count
    }
    /// The composer now holds something other than the stop's placeholder: the user is typing.
    public static func composerChanged(_ screen: String, region: String) -> Bool {
        let current = rows(screen)
        let expected = rows(region)
        guard let last = current.lastIndex(where: isComposer), let stopped = expected.last(where: isComposer) else { return false }
        let text = composerText(current[last])
        return !text.isEmpty && text != composerText(stopped)
    }
    /// The composer still holds the text: a send that did not start a turn.
    public static func draftVisible(_ screen: String, text: String) -> Bool {
        let current = rows(screen)
        guard !running(current) else { return false }
        return current.lastIndex(where: isComposer).map { composerText(current[$0]) == text } ?? false
    }
    /// A submission retry must never resend text or submit extra user notes. The
    /// original error/lifecycle region and the complete composer body are checked.
    public static func draftReady(_ screen: String, stop: CodexCapacityStop) -> Bool {
        let current = rows(screen), expected = rows(stop.region)
        guard !blocked(current), !running(current), let composer = current.lastIndex(where: isComposer),
              stop.agent != .codex || !goalHeld(current), let footer = stop.composerFooter else { return false }
        if !stop.identity.isEmpty {
            let transcript = current[..<composer].joined(separator: "\n")
            let compact = PromptDetector.fingerprint(transcript.components(separatedBy: .whitespacesAndNewlines).joined())
            guard PromptDetector.fingerprint(transcript) == stop.identity || compact == stop.continuationIdentity else { return false }
        }
        let tail = current.indices.filter { $0 > composer && !current[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        let text = stop.continuationText.precomposedStringWithCanonicalMapping
        let ownedBody = footerVariants(footer, agent: stop.agent).contains { expectedFooter in
            guard tail.count >= expectedFooter.count,
                  tail.suffix(expectedFooter.count).map({ current[$0].trimmingCharacters(in: .whitespaces) }) == expectedFooter else { return false }
            let end = expectedFooter.isEmpty ? current.endIndex : tail[tail.count - expectedFooter.count]
            let body = ([composerText(current[composer])] + current[(composer + 1)..<end].map { $0.trimmingCharacters(in: .whitespaces) }).filter { !$0.isEmpty }
            return body.joined() == text || body.joined(separator: " ") == text
        }
        guard ownedBody else { return false }
        if goalStalled(expected) { return goalStalled(current) }
        let heading = expected.first?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let active = activeRegion(screen, heading: heading).map(rows), active.last == current[composer] else { return false }
        let filled: ([String]) -> [String] = { $0.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        return filled(Array(active.dropLast())) == filled(Array(expected.dropLast()))
    }
    private static func footerVariants(_ footer: String, agent: AgentKind) -> [[String]] {
        let original = rows(footer).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard agent == .codex else { return [original] }
        // Codex hides empty-composer shortcuts while a draft is present. Keep
        // model/path/warnings and lifecycle text exact; only these hints may vanish.
        let hidden = original.map {
            $0.replacingOccurrences(of: #"← for agents\s*·\s*\? for shortcuts|\? for shortcuts"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        return original == hidden ? [original] : [original, hidden]
    }
    /// `draft`: only the composer of the same stop holds the text. `submitted`: the screen above the
    /// composer changed and shows the text as a message. A screen that looks unchanged proves nothing,
    /// so it stays `typed`, which is never typed again.
    public enum TypedState: String { case draft, submitted, typed }
    public static func state(before: String, after: String, region: String, text: String) -> TypedState {
        let current = rows(after)
        var stop = CodexCapacityStop.detect(before, agent: CodexResumeCheck.agent(in: region)) ?? CodexCapacityStop(region: region, identity: "")
        stop.agent = agent(in: region); stop.inputText = text; stop.composerFooter = footer(rows(before))
        if draftReady(after, stop: stop) { return .draft }
        if draftVisible(after, text: text) { return .typed }
        if text == CodexCapacityStop.goalResumeText {
            // Slash commands do not create a user-message cell. The lifecycle footer acknowledges them.
            return goalStalled(rows(before)) && footer(current).filter({ !$0.isWhitespace }).contains("Pursuinggoal") ? .submitted : .typed
        }
        return messages(current, text: text) > 0 && transcript(current) != transcript(rows(before)) ? .submitted : .typed
    }
    private static func transcript(_ rows: [String]) -> [String] {
        if running(rows) { return rows }
        return Array(rows[..<(rows.lastIndex(where: isComposer) ?? rows.endIndex)])
    }
}

/// Existing tmux/PTY streams share the original foreground job and exact stopped composer.
public enum VerifiedResumeInput {
    public static func deliver(region: String, text: String, read: () throws -> String,
                              write: (String, RemoteTerminalInput) throws -> TerminalDelivery) throws -> ResumeDelivery {
        let before = try read()
        guard CodexResumeCheck.ready(before,region:region,text:text) else { return .screenChanged }
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
        var stop = CodexCapacityStop.detect(before, agent: CodexResumeCheck.agent(in: region)) ?? CodexCapacityStop(region: region, identity: "")
        stop.agent = CodexResumeCheck.agent(in: region); stop.inputText = text
        let rows = PromptDetector.normalizedLines(before)
        if let composer = rows.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).first.map { "›»❯".contains($0) } == true }) {
            stop.composerFooter = rows.dropFirst(composer + 1).joined(separator: "\n")
        }
        return try complete(stop: stop, read: read, write: write)
    }

    /// Revalidate a stable owned draft, then send Return alone. If it only adds
    /// an empty line, the engine can try Return later without ever retyping text.
    public static func complete(stop: CodexCapacityStop, read: () throws -> String,
                                write: (String, RemoteTerminalInput) throws -> TerminalDelivery) throws -> ResumeDelivery {
        guard CodexResumeCheck.draftReady(try read(), stop: stop) else { return .typed }
        Thread.sleep(forTimeInterval: 0.75)
        let before = try read()
        guard CodexResumeCheck.draftReady(before, stop: stop) else { return .typed }
        let delivered = try write(before, RemoteTerminalInput(kind: .enter, relay: true))
        guard delivered == .sent else {
            switch delivered { case .screenChanged: return .screenChanged; case .agentMissing: return .agentMissing; default: return .missingTarget }
        }
        let sentUntil = Date().addingTimeInterval(4)
        var after = before
        repeat {
            Thread.sleep(forTimeInterval:0.25)
            after = try read()
            if CodexResumeCheck.state(before: before, after: after, region: stop.region, text: stop.continuationText) == .submitted { return .sent }
        } while Date() < sentUntil
        return CodexResumeCheck.draftReady(after, stop: stop) ? .draft : .typed
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
    function resumeAgent(region) { const rows = resumeRows(region); return rows[0].trim().startsWith('■ ') || goalStalled(rows) ? 'codex' : 'claude'; }
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
    function resumeFooter(rows) { const last = lastComposer(rows); return last < 0 ? '' : rows.slice(last + 1).join('\\n'); }
    function goalStalled(rows) { return /Goal(?:stalled|blocked)\\(\\/goalresume\\)/.test(resumeFooter(rows).replace(/\\s/g, '')); }
    function goalHeld(rows) { return /Goal(?:paused|hitusagelimits|hitbudget|budget|achieved|abandoned)/.test(resumeFooter(rows).replace(/\\s/g, '')); }
    function resumeRunning(rows) { return /(?:esc|ctrl\\+c) to (?:interrupt|stop)|tab to queue/i.test(rows.slice(-8).join('\\n')); }
    function resumeReady(rows, region, text) {
      const expected = resumeRows(region), active = activeRegion(rows, expected[0].trim());
      const codex = resumeAgent(region) === 'codex';
      if (goalStalled(expected)) {
        const composer = lastComposer(rows);
        return !resumeBlocked(rows) && !resumeRunning(rows) && !goalHeld(rows) && goalStalled(rows)
          && text === '/goal resume' && composer >= 0 && rows.slice(composer).join('\\n') === expected.join('\\n');
      }
      return !resumeBlocked(rows) && !(codex && goalHeld(rows))
        && (!codex || (text === '/goal resume') === goalStalled(rows))
        && active !== null && active.join('\\n') === expected.join('\\n');
    }
    function messageCount(rows, text) {
      const last = resumeRunning(rows) ? -1 : lastComposer(rows);
      return rows.filter((row, index) => index !== last && isComposer(row) && composerText(row) === text).length;
    }
    function filledRows(rows) { return rows.map(row => row.trim()).filter(row => row).join('\\n'); }
    function resumeFooters(footer, agent) {
      const original = resumeRows(footer).map(row => row.trim()).filter(Boolean);
      if (agent !== 'codex') return [original];
      const hidden = original.map(row => row.replace(/← for agents\\s*·\\s*\\? for shortcuts|\\? for shortcuts/g, '').trim()).filter(Boolean);
      return original.join('\\n') === hidden.join('\\n') ? [original] : [original, hidden];
    }
    function draftReady(rows, region, text, footer) {
      const expected = resumeRows(region), last = lastComposer(rows);
      if (last < 0 || resumeBlocked(rows) || resumeRunning(rows) || (resumeAgent(region) === 'codex' && goalHeld(rows)) || footer == null) return false;
      const tail = []; for (let i = last + 1; i < rows.length; i++) if (rows[i].trim()) tail.push(i);
      const owned = resumeFooters(footer, resumeAgent(region)).some(expectedFooter => {
        if (tail.length < expectedFooter.length) return false;
        const actual = expectedFooter.length ? tail.slice(-expectedFooter.length).map(i => rows[i].trim()) : [];
        if (actual.join('\\n') !== expectedFooter.join('\\n')) return false;
        const end = expectedFooter.length ? tail[tail.length - expectedFooter.length] : rows.length;
        const body = [composerText(rows[last]), ...rows.slice(last + 1, end).map(row => row.trim())].filter(Boolean);
        return body.join('') === text || body.join(' ') === text;
      });
      if (!owned) return false;
      if (goalStalled(expected)) return goalStalled(rows);
      const active = activeRegion(rows, expected[0].trim());
      return active !== null && active[active.length - 1] === rows[last]
        && filledRows(active.slice(0, -1)) === filledRows(expected.slice(0, -1));
    }
    function transcript(rows) { const last = resumeRunning(rows) ? -1 : lastComposer(rows); return rows.slice(0, last < 0 ? rows.length : last).join('\\n'); }
    function draftShown(rows, text) { const last = lastComposer(rows); return !resumeRunning(rows) && last >= 0 && composerText(rows[last]) === text; }
    function typedState(before, after, region, text) {
      const expected = resumeRows(region);
      if (draftReady(after, region, text, resumeFooter(before))) return 'draft';
      if (draftShown(after, text)) return 'typed';
      if (text === '/goal resume') return goalStalled(before) && resumeFooter(after).replace(/\\s/g, '').includes('Pursuinggoal') ? 'submitted' : 'typed';
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
    function awaitSubmitted(read, before, region, text) {
      const until = Date.now() + 4000; let reads = 0;
      do { delay(0.25); reads++; if (typedState(before, resumeRows(read()), region, text) === 'submitted') return true; } while (Date.now() < until || reads < 2);
      return false;
    }
    function submitDraft(read, enter, before, region, text, footer) {
      if (!draftReady(resumeRows(read()), region, text, footer)) return 'typed';
      delay(0.75);
      const stable = resumeRows(read());
      if (!draftReady(stable, region, text, footer)) return typedState(before, stable, region, text) === 'submitted' ? 'sent' : 'typed';
      if (transcript(stable).replace(/\\s/g, '') !== transcript(before).replace(/\\s/g, '')) return 'typed';
      if (!enter()) return 'agentMissing';
      if (awaitSubmitted(read, stable, region, text)) return 'sent';
      return draftReady(resumeRows(read()), region, text, footer) ? 'draft' : 'typed';
    }
    """
}
