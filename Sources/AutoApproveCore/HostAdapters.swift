import Foundation

/// iTerm2's scripting dictionary mirrors Terminal's tab model one level deeper: windows → tabs → sessions.
public enum ITermAdapter {
    public static func restart(target: ScreenTarget, expected: String, command: String) throws -> TerminalDelivery {
        let literal = try AutomationScript.literal(["tty":target.tty,"screen":expected,"command":command,"pid":Int(target.sourcePID ?? 0)] as JSONObject)
        let script = """
        (() => {
          const app = \(app), target = \(literal);
          \(visibleFunction)
          const normalize = text => String(text).normalize('NFC').replace(/\\r\\n?/g,'\\n');
          if (!app.running()) return 'missingTarget';
          for (const window of app.windows()) for (const tab of window.tabs()) for (const session of tab.sessions()) {
            if (session.tty() !== target.tty) continue;
            if (normalize(visible(session)) !== normalize(target.screen)) return 'screenChanged';
            if (Number(session.variable({named:'jobPid'})) !== target.pid) return 'agentMissing';
            session.write({text:String(target.command).normalize('NFC')}); return 'sent';
          }
          return 'missingTarget';
        })();
        """
        let output = try AutomationScript.run(script,app:"iTerm2",denied:.automationDenied("iTerm2"))
        guard let result = TerminalDelivery(rawValue:output) else { throw AppError.message("같은 대화 복구 명령의 전달 결과를 확인하지 못했습니다.") }
        return result
    }
    static let app = "Application('com.googlecode.iterm2')"
    private static func javascript(_ body: String) throws -> String {
        try AutomationScript.run(body, app: "iTerm2", denied: .automationDenied("iTerm2"))
    }
    /// `contents` includes scrollback above the visible rows and pads each row with a space.
    /// Both reading and the final check use this same visible frame.
    static let visibleFunction = """
    function visible(session) {
      const lines = String(session.contents()).split('\\n');
      if (lines.length && lines[lines.length - 1] === '') lines.pop();
      let rows = 0;
      try { rows = Number(session.rows()) || 0; } catch (_) {}
      return (rows > 0 ? lines.slice(-rows) : lines).map(line => line.replace(/ +$/, '')).join('\\n');
    }
    """
    public static func screens(ttys: [String]) throws -> TerminalSnapshot {
        let output = try javascript(screenScript(ttys: ttys))
        return try JSONDecoder().decode(TerminalSnapshot.self, from: Data(output.utf8))
    }
    /// Exposed for contract tests against iTerm2's scripting dictionary, without sending Apple events.
    public static func screenScript(ttys: [String]) throws -> String {
        let allowed = try AutomationScript.literal(ttys)
        return """
        const app = \(app);
        const allowed = \(allowed); const screens = []; const failures = [];
        \(visibleFunction)
        function recordFailure(tty, error) {
          if (Number(error.errorNumber || error.number) === -1743 || String(error).includes('-1743')) throw error;
          failures.push({tty:tty, message:String(error)});
        }
        if (!app.running()) throw Error('iTerm2 앱을 먼저 실행해주세요.');
        for (const window of app.windows()) {
          let tabs;
          try { tabs = window.tabs(); } catch (error) { recordFailure(null, error); continue; }
          for (const tab of tabs) {
            let sessions;
            try { sessions = tab.sessions(); } catch (error) { recordFailure(null, error); continue; }
            for (const session of sessions) {
              let tty = null;
              try {
                tty = session.tty();
                if (!allowed.includes(tty)) continue;
                let title = null;
                try { title = String(session.name() || '').trim() || null; } catch (_) {}
                screens.push({tty:tty, contents:visible(session), title:title});
              } catch (error) { recordFailure(tty, error); }
            }
          }
        }
        JSON.stringify({screens:screens, failures:failures});
        """
    }
    public static func reveal(tty: String) throws -> TerminalWindowBounds {
        let output = try javascript(revealScript(tty: tty))
        return try JSONDecoder().decode(TerminalWindowBounds.self, from: Data(output.utf8))
    }
    public static func revealScript(tty: String) throws -> String {
        let value = try AutomationScript.literal(tty)
        return """
        (() => {
        const app = \(app);
        function ignoreClosed(error) {
          if (Number(error.errorNumber || error.number) === -1743 || String(error).includes('-1743')) throw error;
        }
        if (app.running()) for (const window of app.windows()) {
          let tabs;
          try { tabs = window.tabs(); } catch (error) { ignoreClosed(error); continue; }
          for (const tab of tabs) {
            let sessions;
            try { sessions = tab.sessions(); } catch (error) { ignoreClosed(error); continue; }
            for (const session of sessions) {
              let tty;
              try { tty = session.tty(); } catch (error) { ignoreClosed(error); continue; }
              if (tty !== \(value)) continue;
              try { window.miniaturized = false; } catch (_) {}
              tab.select(); session.select(); window.select();
              app.activate();
              return JSON.stringify(window.bounds());
            }
          }
        }
        throw Error('대상 터미널이 닫혔습니다. 목록을 새로고침해주세요.');
        })();
        """
    }
    @discardableResult public static func approve(target: ScreenTarget, expectedScreen: String, agent: AgentKind) throws -> TerminalDelivery {
        let result = try javascript(approvalScript(target: target, expectedScreen: expectedScreen, agent: agent))
        guard let delivery = TerminalDelivery(rawValue: result) else { throw AppError.message("승인 입력의 전달 결과를 확인하지 못했습니다.") }
        return delivery
    }
    public static func approvalScript(target: ScreenTarget, expectedScreen: String, agent: AgentKind) throws -> String {
        var data = try AutomationScript.dialogData(tty: target.tty, expectedScreen: expectedScreen, agent: agent)
        data["jobPIDs"] = target.jobPIDs.map(Int.init)
        let literal = try AutomationScript.literal(data)
        return """
        (() => {
        const app = \(app); const target = \(literal);
        \(visibleFunction)
        function normalize(text) { return String(text).normalize('NFC').replace(/\\r\\n?/g, '\\n'); }
        function activeDialog(text) {
          const lines = normalize(text).split('\\n');
          while (lines.length && !lines[lines.length - 1].trim()) lines.pop();
          if (target.agent === 'claude') return lines.join('\\n');
          const heading = normalize(target.dialog).split('\\n')[0].trim();
          let start = -1;
          for (let index = 0; index < lines.length; index++) if (lines[index].trim() === heading) start = index;
          return start < 0 ? null : lines.slice(start).join('\\n');
        }
        function skipClosed(read) {
          try { return read(); } catch (error) {
            if (Number(error.errorNumber || error.number) === -1743 || String(error).includes('-1743')) throw error;
            return null;
          }
        }
        if (app.running()) for (const window of app.windows()) for (const tab of skipClosed(() => window.tabs()) || [])
        for (const session of skipClosed(() => tab.sessions()) || []) {
          if (skipClosed(() => session.tty()) !== target.tty) continue;
          if (activeDialog(visible(session)) !== normalize(target.dialog)) return 'screenChanged';
          // iTerm2 names the tab's foreground job. A shell or another command there is not the agent.
          let job = 0;
          try { job = Number(session.variable({named: 'jobPid'})) || 0; } catch (_) {}
          if (job > 0 && !target.jobPIDs.includes(job)) return 'agentMissing';
          session.write({text: '1'});
          return 'sent';
        }
        return 'missingTarget';
        })();
        """
    }
    public static func resume(target: ScreenTarget, region: String, text: String) throws -> ResumeDelivery {
        let result = try AutomationScript.run(resumeScript(target: target, region: region, text: text), app: "iTerm2", denied: .automationDenied("iTerm2"), timeout: 40)
        guard let delivery = ResumeDelivery(rawValue: result) else { throw AppError.message("이어서 진행 요청의 전달 결과를 확인하지 못했습니다.") }
        return delivery
    }
    public static func resumeScript(target: ScreenTarget, region: String, text: String) throws -> String {
        let literal = try AutomationScript.literal(["tty": target.tty, "region": region, "text": text, "jobPIDs": target.jobPIDs.map(Int.init)] as JSONObject)
        return """
        (() => {
        const app = \(app); const target = \(literal);
        \(visibleFunction)
        \(CodexResumeScript.functions)
        function skipClosed(read) {
          try { return read(); } catch (error) {
            if (Number(error.errorNumber || error.number) === -1743 || String(error).includes('-1743')) throw error;
            return null;
          }
        }
        // osascript receives this script as a decomposed (NFD) argument; type and compare composed text.
        const text = String(target.text).normalize('NFC');
        if (app.running()) for (const window of app.windows()) for (const tab of skipClosed(() => window.tabs()) || [])
        for (const session of skipClosed(() => tab.sessions()) || []) {
          if (skipClosed(() => session.tty()) !== target.tty) continue;
          const before = resumeRows(visible(session));
          if (!resumeReady(before, target.region, text)) return 'screenChanged';
          let job = 0;
          try { job = Number(session.variable({named: 'jobPid'})) || 0; } catch (_) {}
          if (job > 0 && !target.jobPIDs.includes(job)) return 'agentMissing';
          // Text and Return arriving together stay a paste in Codex; Return follows separately.
          session.write({text, newline: false});
          const state = awaitTypedState(() => visible(session), before, target.region, text);
          if (state === 'draft') { session.write({text: ''}); return awaitSubmitted(() => visible(session), before, target.region, text) ? 'sent' : 'typed'; }
          return state === 'submitted' ? 'sent' : 'typed';
        }
        return 'missingTarget';
        })();
        """
    }
}

public enum OrcaAdapterError: LocalizedError, Equatable {
    case notRunning
    case cli(code: String, message: String)
    public var errorDescription: String? {
        switch self {
        case .notRunning: return "Orca 앱을 먼저 실행해주세요."
        case .cli(let code, let message): return "Orca 연결 실패 (\(code)): \(message)"
        }
    }
    var isStaleHandle: Bool {
        if case .cli(let code, _) = self { return code == "terminal_handle_stale" || code == "terminal_not_found" }
        return false
    }
}

/// Orca exposes each pane through its bundled CLI. The pane handle comes from the agent's own
/// launch environment; a handle Orca no longer recognizes fails closed as a stale target.
public enum OrcaAdapter {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedCLI: String?

    /// The launcher ships inside the bundle. A running app is found by process so a translocated
    /// or relocated Orca.app still works; the known install folders are the fallback.
    static func cliPath() throws -> String {
        lock.lock(); let cached = cachedCLI; lock.unlock()
        if let cached, FileManager.default.isExecutableFile(atPath: cached) { return cached }
        let suffix = "/Orca.app/Contents/MacOS/Orca"
        let running = ((try? ProcessDiscovery.read()) ?? []).first { $0.executable.hasSuffix(suffix) }
        let bundles = (running.map { [String($0.executable.dropLast(suffix.count - "/Orca.app".count))] } ?? [])
            + ["/Applications/Orca.app", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Orca.app").path]
        guard running != nil else { throw OrcaAdapterError.notRunning }
        guard let path = bundles.map({ $0 + "/Contents/Resources/bin/orca" }).first(where: FileManager.default.isExecutableFile) else {
            throw AppError.message("Orca 명령줄 도구를 찾지 못했습니다. Orca를 다시 설치해주세요.")
        }
        lock.lock(); cachedCLI = path; lock.unlock()
        return path
    }
    static func call(_ arguments: [String], timeout: TimeInterval = 6) throws -> JSONObject {
        let result = try CommandRunner.run(try cliPath(), arguments + ["--json"], timeout: timeout)
        return try parse(result.output)
    }
    /// The CLI prints one envelope: {"ok": true, "result": …} or {"ok": false, "error": {code, message}}.
    public static func parse(_ output: String) throws -> JSONObject {
        guard let envelope = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? JSONObject else {
            throw OrcaAdapterError.cli(code: "invalid_output", message: "Orca 응답을 해석하지 못했습니다.")
        }
        guard envelope["ok"] as? Bool == true, let result = envelope["result"] as? JSONObject else {
            let error = envelope["error"] as? JSONObject
            throw OrcaAdapterError.cli(code: error?["code"] as? String ?? "unknown", message: error?["message"] as? String ?? "알 수 없는 오류")
        }
        return result
    }
    /// Only the rendered frame is a screen. Accumulated stream output repeats repainted fragments.
    public static func screen(from result: JSONObject) throws -> String {
        let terminal = result["terminal"] as? JSONObject
        switch terminal?["source"] as? String {
        case "screen"?:
            guard let rows = terminal?["tail"] as? [String] else { break }
            return rows.joined(separator: "\n")
        case "screen-unavailable"?:
            // Seen for tabs Orca restored after a restart: the pane runs, but no rendered frame exists.
            throw OrcaAdapterError.cli(code: "screen_unavailable", message: "Orca가 이 터미널의 렌더링된 화면을 제공하지 않았습니다. Orca를 다시 실행한 직후 복원된 탭에서 생길 수 있으며, 화면을 받을 때까지 연결하지 않습니다.")
        case nil where terminal != nil:
            throw OrcaAdapterError.cli(code: "screen_unsupported", message: "이 Orca 버전은 현재 화면 읽기를 지원하지 않습니다. Orca를 업데이트해주세요.")
        default: break
        }
        throw OrcaAdapterError.cli(code: "invalid_output", message: "Orca 화면 응답을 해석하지 못했습니다.")
    }
    static func readScreen(handle: String) throws -> String {
        try screen(from: call(["terminal", "read", "--terminal", handle, "--screen"], timeout: 5))
    }
    public static func screens(targets: [ScreenTarget]) throws -> TerminalSnapshot {
        var snapshot = TerminalSnapshot()
        for target in targets {
            guard let handle = target.handle else {
                snapshot.failures.append(TerminalReadFailure(tty: target.tty, message: "Orca 터미널 핸들을 확인하지 못했습니다."))
                continue
            }
            do { snapshot.screens.append(TerminalScreen(tty: target.tty, contents: try readScreen(handle: handle))) }
            catch OrcaAdapterError.notRunning { throw OrcaAdapterError.notRunning }
            catch { snapshot.failures.append(TerminalReadFailure(tty: target.tty, message: error.localizedDescription)) }
        }
        return snapshot
    }
    static func normalize(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
    /// Same active-dialog rule as the Terminal and iTerm2 scripts.
    public static func activeDialog(_ text: String, dialog: String, agent: AgentKind) -> String? {
        var lines = normalize(text).components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        if agent == .claude { return lines.joined(separator: "\n") }
        let heading = normalize(dialog).components(separatedBy: "\n")[0].trimmingCharacters(in: .whitespaces)
        guard let start = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == heading }) else { return nil }
        return lines[start...].joined(separator: "\n")
    }
    /// Orca has no atomic compare-and-write, so the frame is re-read immediately before the write.
    public static func approve(target: ScreenTarget, expectedScreen: String, agent: AgentKind) throws -> TerminalDelivery {
        guard let handle = target.handle else { return .missingTarget }
        let data = try AutomationScript.dialogData(tty: target.tty, expectedScreen: expectedScreen, agent: agent)
        let dialog = data["dialog"] as? String ?? ""
        let current: String
        do { current = try readScreen(handle: handle) }
        catch let error as OrcaAdapterError where error.isStaleHandle { return .missingTarget }
        guard activeDialog(current, dialog: dialog, agent: agent) == normalize(dialog) else { return .screenChanged }
        // A plain write: `--enter` with text would take Orca's agent-prompt delivery path.
        let result: JSONObject
        do { result = try call(["terminal", "send", "--terminal", handle, "--text", "1\r"]) }
        catch let error as OrcaAdapterError where error.isStaleHandle { return .missingTarget }
        guard let send = result["send"] as? JSONObject else { throw AppError.message("Orca 입력 전달 결과를 확인하지 못했습니다.") }
        return send["accepted"] as? Bool == true ? .sent : .missingTarget
    }
    public static func reveal(target: ScreenTarget) throws {
        guard let handle = target.handle else { throw AppError.message("Orca 터미널 핸들을 확인하지 못했습니다.") }
        _ = try call(["terminal", "switch", "--terminal", handle])
    }
    /// Process arguments and environment values reach the child decomposed (NFD). The shell reads the
    /// text from a private file and passes it on unchanged, so Codex receives composed Korean.
    static func sendComposed(handle: String, text: String) throws -> JSONObject {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("autoapprove-send-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: file.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw AppError.message("Orca에 보낼 입력을 준비하지 못했습니다.")
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try CommandRunner.run("/bin/sh", ["-c", #"exec "$0" terminal send --terminal "$1" --text "$(cat "$2")" --json"#,
            try cliPath(), handle, file.path], timeout: 6)
        return try parse(result.output)
    }
    /// The same order as the Terminal script: re-read, type the text alone, then Return for a visible draft.
    public static func resume(target: ScreenTarget, region: String, text: String) throws -> ResumeDelivery {
        guard let handle = target.handle else { return .missingTarget }
        let before: String
        do { before = try readScreen(handle: handle) }
        catch let error as OrcaAdapterError where error.isStaleHandle { return .missingTarget }
        guard CodexResumeCheck.ready(before, region: region, text: text) else { return .screenChanged }
        let typed: JSONObject
        do { typed = try sendComposed(handle: handle, text: text) }
        catch let error as OrcaAdapterError where error.isStaleHandle { return .missingTarget }
        guard (typed["send"] as? JSONObject)?["accepted"] as? Bool == true else { return .missingTarget }
        var state = CodexResumeCheck.TypedState.typed, reads = 0
        let until = Date().addingTimeInterval(8)
        repeat {
            Thread.sleep(forTimeInterval: 0.25)
            state = CodexResumeCheck.state(before: before, after: try readScreen(handle: handle), region: region, text: text)
            reads += 1
        } while state == .typed && (Date() < until || reads < 3)
        switch state {
        case .draft:
            let enter = try call(["terminal", "send", "--terminal", handle, "--text", "\r"])
            guard (enter["send"] as? JSONObject)?["accepted"] as? Bool == true else { return .typed }
            let gone = Date().addingTimeInterval(4)
            var checks = 0
            repeat {
                Thread.sleep(forTimeInterval: 0.25)
                if CodexResumeCheck.state(before: before, after: try readScreen(handle: handle), region: region, text: text) == .submitted { return .sent }
                checks += 1
            } while Date() < gone || checks < 2
            return .typed
        case .submitted: return .sent
        case .typed: return .typed
        }
    }
}
