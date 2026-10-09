import Foundation
import CoreGraphics
import AppKit
import TerminalInputSupport

public struct TerminalScreen: Codable {
    public var tty: String
    public var contents: String
    public var title: String?
    public var appearance: TerminalAppearance?
    public var cursor: TerminalCursor?
    public var display: TerminalTextSnapshot?
    public init(tty: String, contents: String, title: String? = nil, appearance: TerminalAppearance? = nil, cursor: TerminalCursor? = nil,
                display: TerminalTextSnapshot? = nil) {
        self.tty = tty; self.contents = contents; self.title = title; self.appearance = appearance; self.cursor = cursor
        self.display = display
    }
}

public struct TerminalReadFailure: Codable {
    public var tty: String?
    public var message: String
}

public struct TerminalSnapshot: Codable {
    public var screens: [TerminalScreen]
    public var failures: [TerminalReadFailure]
    public init(screens: [TerminalScreen] = [], failures: [TerminalReadFailure] = []) { self.screens = screens; self.failures = failures }
}

public enum TerminalAdapterError: LocalizedError, Equatable {
    case permissionDenied
    case automationDenied(String)
    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Terminal 자동화 권한이 필요합니다. 시스템 설정 → 개인정보 보호 및 보안 → 자동화에서 AutoApprove를 허용한 후 다시 연결해주세요."
        case .automationDenied(let app):
            return "\(app) 자동화 권한이 필요합니다. 시스템 설정 → 개인정보 보호 및 보안 → 자동화에서 AutoApprove의 \(app) 항목을 허용한 후 다시 연결해주세요."
        }
    }
}

/// One exact screen to read or answer: a tab's tty, and Orca's pane handle when the host needs it.
public struct ScreenTarget: Equatable, Sendable {
    public var tty: String
    public var handle: String?
    /// Processes of the agent's foreground job. A host that reports its own foreground job
    /// must name one of these before any input is written.
    public var jobPIDs: [Int32]
    public var sourcePID: Int32?
    public var sourceStarted: String?
    /// Frozen when the original input stream is first bound, not per keystroke.
    public var sourceIdentity: TTYInputIdentity?
    public init(tty: String, handle: String? = nil, jobPIDs: [Int32] = [], sourcePID: Int32? = nil, sourceStarted: String? = nil,
                sourceIdentity: TTYInputIdentity? = nil) {
        self.tty = tty; self.handle = handle; self.jobPIDs = jobPIDs
        self.sourcePID = sourcePID; self.sourceStarted = sourceStarted
        self.sourceIdentity = sourceIdentity
    }
}

/// The per-host channel behind every screen connection. Tests replace these closures.
public struct ScreenHostAdapter: Sendable {
    public var screens: @Sendable ([ScreenTarget]) throws -> TerminalSnapshot
    public var presentationScreens: (@Sendable ([ScreenTarget]) throws -> TerminalSnapshot)?
    public var approve: @Sendable (ScreenTarget, String, AgentKind) throws -> TerminalDelivery
    /// nil means the host revealed the tab but reports no window frame to highlight.
    public var reveal: @Sendable (ScreenTarget) throws -> TerminalWindowBounds?
    /// Sends a message into a Codex composer stopped at the given region (see `CodexCapacityStop`).
    public var resume: @Sendable (ScreenTarget, String, String) throws -> ResumeDelivery
    /// The source is an already verified, idle original shell after an observed CLI error.
    public var restart: (@Sendable (ScreenTarget, String, String) throws -> TerminalDelivery)?
    public var input: @Sendable (ScreenTarget, String, AgentKind, RemoteTerminalInput) throws -> TerminalDelivery
    public init(screens: @escaping @Sendable ([ScreenTarget]) throws -> TerminalSnapshot,
                approve: @escaping @Sendable (ScreenTarget, String, AgentKind) throws -> TerminalDelivery,
                reveal: @escaping @Sendable (ScreenTarget) throws -> TerminalWindowBounds?,
                resume: @escaping @Sendable (ScreenTarget, String, String) throws -> ResumeDelivery = { _, _, _ in .missingTarget },
                restart: (@Sendable (ScreenTarget, String, String) throws -> TerminalDelivery)? = nil,
                input: @escaping @Sendable (ScreenTarget, String, AgentKind, RemoteTerminalInput) throws -> TerminalDelivery = { _, _, _, _ in .missingTarget },
                presentationScreens: (@Sendable ([ScreenTarget]) throws -> TerminalSnapshot)? = nil) {
        self.screens = screens; self.approve = approve; self.reveal = reveal; self.resume = resume; self.restart = restart; self.input = input
        self.presentationScreens = presentationScreens
    }
    public static func live(_ host: ScreenHost) -> ScreenHostAdapter {
        switch host {
        case .terminal:
            return ScreenHostAdapter(screens: { try TerminalAdapter.screens(ttys: $0.map(\.tty), includeCursor: false) },
                approve: { try TerminalAdapter.approve(tty: $0.tty, expectedScreen: $1, agent: $2) },
                reveal: { try TerminalAdapter.reveal(tty: $0.tty) },
                resume: { try TerminalAdapter.resume(tty: $0.tty, region: $1, text: $2) },
                restart: { try TerminalAdapter.restart(target:$0,expected:$1,command:$2) },
                input: { try RemoteTerminalAdapter.input(host: .terminal, target: $0, expected: $1, agent: $2, input: $3) },
                presentationScreens: { try TerminalAdapter.screens(ttys: $0.map(\.tty)) })
        case .iterm:
            return ScreenHostAdapter(screens: { try ITermAdapter.screens(ttys: $0.map(\.tty)) },
                approve: { try ITermAdapter.approve(target: $0, expectedScreen: $1, agent: $2) },
                reveal: { try ITermAdapter.reveal(tty: $0.tty) },
                resume: { try ITermAdapter.resume(target: $0, region: $1, text: $2) },
                restart: { try ITermAdapter.restart(target:$0,expected:$1,command:$2) },
                input: { try RemoteTerminalAdapter.input(host: .iterm, target: $0, expected: $1, agent: $2, input: $3) })
        case .orca:
            return ScreenHostAdapter(screens: { try OrcaAdapter.screens(targets: $0) },
                approve: { try OrcaAdapter.approve(target: $0, expectedScreen: $1, agent: $2) },
                reveal: { try OrcaAdapter.reveal(target: $0); return nil },
                resume: { try OrcaAdapter.resume(target: $0, region: $1, text: $2) },
                input: { try RemoteTerminalAdapter.input(host: .orca, target: $0, expected: $1, agent: $2, input: $3) })
        case .tmux:
            return TmuxRelay.shared.adapter
        case .pty:
            // An engine installs its own manager here. No global PTYs or slave writes.
            return ScreenHostAdapter(screens: { _ in TerminalSnapshot() }, approve: { _, _, _ in .missingTarget }, reveal: { _ in nil })
        }
    }
}

enum AutomationScript {
    static func run(_ body: String, app: String, denied: TerminalAdapterError, timeout: TimeInterval = 8) throws -> String {
        let result = try CommandRunner.run("/usr/bin/osascript", ["-l", "JavaScript", "-e", body], timeout: timeout)
        guard result.status == 0 else {
            if result.error.contains("-1743") { throw denied }
            throw AppError.message("\(app) 연결 실패: \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func literal(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]), as: UTF8.self)
    }
    /// Scripts compare the dialog exactly as the detector returned it.
    static func dialogData(tty: String, expectedScreen: String, agent: AgentKind) throws -> JSONObject {
        guard agent != .shell else { throw AppError.message("일반 셸에는 승인 입력을 전달할 수 없습니다.") }
        guard let prompt = PromptDetector.detect(expectedScreen, agent: agent) else { throw AppError.message("승인 요청의 내용과 선택지를 확인하지 못했습니다.") }
        return ["tty": tty, "dialog": prompt.dialog, "agent": agent.rawValue]
    }
}

public enum TerminalDelivery: String, Codable { case sent, screenChanged, missingTarget, agentMissing }

public struct TerminalWindowBounds: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    /// Terminal uses a top-left desktop origin; AppKit uses the primary screen's bottom-left.
    public func appKitFrame(primaryScreenHeight: Double) -> CGRect? {
        guard [x, y, width, height, primaryScreenHeight].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
        let bottom = primaryScreenHeight - y - height
        guard bottom.isFinite else { return nil }
        return CGRect(x: x, y: bottom, width: width, height: height)
    }
}

public struct TerminalWindowMetadata: Equatable, Sendable {
    public var tty: String
    public var windowID: UInt32
    public var ownerPID: Int32
    public var ownerBundleID: String
    public var selected: Bool
    public var minimized: Bool
    public var bounds: TerminalWindowBounds?
    public var bindingToken: String?
    public init(tty: String, windowID: UInt32, ownerPID: Int32, ownerBundleID: String, selected: Bool, minimized: Bool, bounds: TerminalWindowBounds? = nil, bindingToken: String? = nil) {
        self.tty = tty; self.windowID = windowID; self.ownerPID = ownerPID; self.ownerBundleID = ownerBundleID
        self.selected = selected; self.minimized = minimized; self.bounds = bounds; self.bindingToken = bindingToken
    }
}

public enum TerminalAdapter {
    public static func restart(target: ScreenTarget, expected: String, command: String) throws -> TerminalDelivery {
        let output = try AutomationScript.run(restartScript(target:target,expected:expected,command:command),app:"Terminal",denied:.permissionDenied)
        guard let result = TerminalDelivery(rawValue:output) else { throw AppError.message("같은 대화 복구 명령의 전달 결과를 확인하지 못했습니다.") }
        return result
    }
    public static func restartScript(target: ScreenTarget, expected: String, command: String) throws -> String {
        let literal = try AutomationScript.literal(["tty":target.tty,"screen":expected,"command":command] as JSONObject)
        return """
        (() => {
          const app = Application('com.apple.Terminal'), target = \(literal);
          const normalize = text => String(text).normalize('NFC').replace(/\\r\\n?/g,'\\n');
          if (!app.running()) return 'missingTarget';
          for (const window of app.windows()) for (const tab of window.tabs()) {
            if (tab.tty() !== target.tty) continue;
            if (normalize(tab.contents()) !== normalize(target.screen)) return 'screenChanged';
            const jobs = tab.processes().map(p => String(p).toLowerCase());
            if (jobs.length !== 1 || !/^(?:-)?(?:zsh|bash|sh|fish|dash|ksh)$/.test(jobs[0])) return 'agentMissing';
            app.doScript(String(target.command).normalize('NFC'), {in:tab});
            return 'sent';
          }
          return 'missingTarget';
        })();
        """
    }
    /// Reads the exact native window's selected TTY. It never activates/selects a tab.
    /// The caller preflights Automation without prompting before running this helper.
    public static func windowMetadata(tty: String, host: ScreenHost = .terminal) throws -> TerminalWindowMetadata? {
        guard [.terminal, .iterm].contains(host) else { return nil }
        let output = try AutomationScript.run(windowMetadataScript(tty: tty, host: host), app: host.title,
            denied: host == .terminal ? .permissionDenied : .automationDenied(host.title), timeout: 3)
        if output == "null" { return nil }
        struct Selection: Decodable { var tty: String; var windowID: UInt32; var selected: Bool; var minimized: Bool; var bounds: TerminalWindowBounds? }
        let selection = try JSONDecoder().decode(Selection.self, from: Data(output.utf8))
        guard selection.tty == tty, selection.windowID > 0,
              let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, selection.windowID) as? [[String: Any]],
              let window = windows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == selection.windowID }),
              let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let owner = NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier, owner == host.bundleID else { return nil }
        return TerminalWindowMetadata(tty: tty, windowID: selection.windowID, ownerPID: ownerPID, ownerBundleID: owner,
            selected: selection.selected, minimized: selection.minimized, bounds: selection.bounds)
    }
    public static func windowMetadataScript(tty: String, host: ScreenHost = .terminal) throws -> String {
        guard [.terminal, .iterm].contains(host) else { throw RemoteHTTPError(400, "이 앱은 정확한 원본 창 주소를 제공하지 않습니다.") }
        let value = try AutomationScript.literal(tty)
        let lookup = host == .terminal ? """
          for (const tab of skip(() => window.tabs()) || []) {
            const tty = skip(() => tab.tty()); if (tty !== wanted) continue;
            const selected = skip(() => window.selectedTab().tty()) === wanted && skip(() => tab.selected()) === true;
            return result(window, tty, selected);
          }
        """ : """
          for (const tab of skip(() => window.tabs()) || []) for (const session of skip(() => tab.sessions()) || []) {
            const tty = skip(() => session.tty()); if (tty !== wanted) continue;
            const tabID = skip(() => tab.id()), currentTabID = skip(() => window.currentTab().id());
            const selected = tabID !== null && currentTabID === tabID && skip(() => tab.currentSession().tty()) === wanted;
            return result(window, tty, selected);
          }
        """
        return """
        (() => {
        const app = Application('\(host.bundleID)'), wanted = \(value);
        function skip(read) { try { return read(); } catch(error) {
          if (Number(error.errorNumber || error.number) === -1743 || String(error).includes('-1743')) throw error;
          return null;
        } }
        function result(window, tty, selected) {
          const id = Number(skip(() => window.id()));
          if (!Number.isSafeInteger(id) || id <= 0 || id > 4294967295) return 'null';
          return JSON.stringify({tty,windowID:id,selected,minimized:skip(() => window.miniaturized()) === true,bounds:skip(() => window.bounds())});
        }
        if (app.running()) for (const window of app.windows()) {
          \(lookup)
        }
        return 'null';
        })();
        """
    }
    private static func javascript(_ body: String) throws -> String {
        try AutomationScript.run(body, app: "Terminal", denied: .permissionDenied)
    }
    private static func literal(_ object: Any) throws -> String { try AutomationScript.literal(object) }
    public static func screens(ttys: [String], includeCursor: Bool = true) throws -> TerminalSnapshot {
        let output = try javascript(screenScript(ttys: ttys, includeCursor: includeCursor))
        let data = Data(output.utf8)
        var snapshot = try JSONDecoder().decode(TerminalSnapshot.self, from: data)
        guard includeCursor else { return snapshot }
        let records = (try? JSONSerialization.jsonObject(with: data) as? JSONObject)?["screens"] as? [JSONObject] ?? []
        for index in snapshot.screens.indices {
            guard let metadata = records.first(where: { $0["tty"] as? String == snapshot.screens[index].tty })?["cursorWindow"] as? JSONObject,
                  let windowID = metadata["windowID"] as? UInt32,
                  let title = metadata["title"] as? String, let boundsObject = metadata["bounds"],
                  let boundsData = try? JSONSerialization.data(withJSONObject: boundsObject),
                  let bounds = try? JSONDecoder().decode(TerminalWindowBounds.self, from: boundsData) else { continue }
            let visible = TerminalCursorReader.snapshot(screen: snapshot.screens[index].contents, windowID: windowID, title: title, bounds: bounds)
            snapshot.screens[index].display = visible
            if visible?.screen == snapshot.screens[index].contents { snapshot.screens[index].cursor = visible?.cursor }
        }
        return snapshot
    }
    /// Exposed for contract tests against Terminal's scripting dictionary, without sending Apple events.
    public static func screenScript(ttys: [String], includeCursor: Bool = true) throws -> String {
        let allowed = try literal(ttys)
        return """
        const app = Application('com.apple.Terminal');
        const allowed = new Set(\(allowed)); const screens = []; const failures = [];
        function recordFailure(tty, error) {
          if (Number(error.errorNumber || error.number) === -1743 || String(error).includes('-1743')) throw error;
          failures.push({tty:tty, message:String(error)});
        }
        if (!app.running()) throw Error('Terminal 앱을 먼저 실행해주세요.');
        screenWindows: for (const window of app.windows()) {
          let tabs;
          try { tabs = window.tabs(); } catch (error) { recordFailure(null, error); continue; }
          for (const tab of tabs) {
            let tty = null;
            try {
              tty = tab.tty();
              if (!allowed.has(tty)) continue;
              // A tab has customTitle, not name. Window name belongs only to its selected tab.
              let title = null;
              try { title = String(tab.customTitle() || '').trim() || null; } catch (_) {}
              if (!title) try {
                if (tabs.length === 1 || tab.selected()) title = String(window.name() || '').trim() || null;
              } catch (_) {}
              let cursorWindow = null;
              try { if (\(includeCursor ? "true" : "false") && tab.selected()) cursorWindow = {windowID:Number(window.id()), title:String(window.name()), bounds:window.bounds()}; } catch (_) {}
              screens.push({tty:tty, contents:tab.contents(), title:title, cursorWindow:cursorWindow});
              allowed.delete(tty);
              if (!allowed.size) break screenWindows;
            } catch (error) { recordFailure(tty, error); }
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
        let value = try literal(tty)
        return """
        (() => {
        const app = Application('com.apple.Terminal');
        function ignoreClosed(error) {
          if (Number(error.errorNumber || error.number) === -1743 || String(error).includes('-1743')) throw error;
        }
        if (app.running()) for (const window of app.windows()) {
          let tabs;
          try { tabs = window.tabs(); } catch (error) { ignoreClosed(error); continue; }
          for (const tab of tabs) {
            let tty;
            try { tty = tab.tty(); } catch (error) { ignoreClosed(error); continue; }
            if (tty !== \(value)) continue;
            window.miniaturized = false;
            window.selectedTab = tab;
            window.index = 1;
            app.activate();
            return JSON.stringify(window.bounds());
          }
        }
        throw Error('대상 터미널이 닫혔습니다. 목록을 새로고침해주세요.');
        })();
        """
    }
    @discardableResult public static func approve(tty: String, expectedScreen: String, agent: AgentKind) throws -> TerminalDelivery {
        let result = try javascript(approvalScript(tty: tty, expectedScreen: expectedScreen, agent: agent))
        guard let delivery = TerminalDelivery(rawValue: result) else { throw AppError.message("승인 입력의 전달 결과를 확인하지 못했습니다.") }
        return delivery
    }

    public static func approvalScript(tty: String, expectedScreen: String, agent: AgentKind) throws -> String {
        // Compare the complete active dialog, preserving command whitespace. Unrelated history can change.
        let data = try literal(AutomationScript.dialogData(tty: tty, expectedScreen: expectedScreen, agent: agent))
        return """
        (() => {
        const app = Application('com.apple.Terminal'); const target = \(data);
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
        // Terminal lists each native tab as a window, and can list one it no longer resolves.
        // Skip windows and tabs that cannot be read; only the matching tab is compared and written.
        function skipClosed(read) {
          try { return read(); } catch (error) {
            if (Number(error.errorNumber || error.number) === -1743 || String(error).includes('-1743')) throw error;
            return null;
          }
        }
        if (app.running()) for (const window of app.windows()) for (const tab of skipClosed(() => window.tabs()) || []) {
          if (skipClosed(() => tab.tty()) !== target.tty) continue;
          if (activeDialog(tab.contents()) !== normalize(target.dialog)) return 'screenChanged';
          if (!tab.processes().some(p => p.toLowerCase().includes(target.agent))) return 'agentMissing';
          app.doScript('1', {in:tab});
          return 'sent';
        }
        return 'missingTarget';
        })();
        """
    }

    public static func resume(tty: String, region: String, text: String) throws -> ResumeDelivery {
        let result = try AutomationScript.run(resumeScript(tty: tty, region: region, text: text), app: "Terminal", denied: .permissionDenied, timeout: 40)
        guard let delivery = ResumeDelivery(rawValue: result) else { throw AppError.message("이어서 진행 요청의 전달 결과를 확인하지 못했습니다.") }
        return delivery
    }

    public static func resumeScript(tty: String, region: String, text: String) throws -> String {
        let data = try literal(["tty": tty, "region": region, "text": text])
        return """
        (() => {
        const app = Application('com.apple.Terminal'); const target = \(data);
        \(CodexResumeScript.functions)
        function skipClosed(read) {
          try { return read(); } catch (error) {
            if (Number(error.errorNumber || error.number) === -1743 || String(error).includes('-1743')) throw error;
            return null;
          }
        }
        // osascript receives this script as a decomposed (NFD) argument; type and compare composed text.
        const text = String(target.text).normalize('NFC');
        if (app.running()) for (const window of app.windows()) for (const tab of skipClosed(() => window.tabs()) || []) {
          if (skipClosed(() => tab.tty()) !== target.tty) continue;
          const before = resumeRows(tab.contents());
          if (!resumeReady(before, target.region, text)) return 'screenChanged';
          if (!tab.processes().some(p => p.toLowerCase().includes(resumeAgent(target.region)))) return 'agentMissing';
          // do script types the text and Return in one write, which Codex keeps as a paste.
          // A separate Return submits it, only while the draft sits in the same stopped composer.
          app.doScript(text, {in:tab});
          const state = awaitTypedState(() => tab.contents(), before, target.region, text);
          if (state === 'draft') { app.doScript('', {in:tab}); return awaitSubmitted(() => tab.contents(), before, target.region, text) ? 'sent' : 'typed'; }
          return state === 'submitted' ? 'sent' : 'typed';
        }
        return 'missingTarget';
        })();
        """
    }
}
