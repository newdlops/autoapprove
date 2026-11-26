import Foundation
import Darwin
import TerminalInputSupport

public enum TerminalDeviceInput {
    public static func deliverBackground(target: ScreenTarget, screen: String, agent: AgentKind, input: RemoteTerminalInput,
        captureIdentity: @escaping @Sendable (Int32) throws -> TTYInputIdentity = { try TTYInputIdentity.capture(pid: $0) },
        run: (@Sendable (String) throws -> String)? = nil) throws -> TerminalDelivery {
        try input.validate()
        if [.eraseLine,.escape].contains(input.kind) {
            guard let pid = target.sourcePID, let identity = target.sourceIdentity,
                  let current = try? captureIdentity(pid), identity.sameProcess(as: current),
                  current.processGroup == current.foregroundGroup else { return .agentMissing }
            let latest = try TerminalAdapter.screens(ttys:[target.tty], includeCursor:false, includeTitles:false, purpose:.validation)
            guard latest.screens.first(where: { $0.tty == target.tty })?.contents == screen else { return .screenChanged }
            return try TerminalKeyboard.deliver(target:target, expected:screen, agent:agent,
                input:.init(kind:input.kind, relay:true), environment:try .live(sourcePID:pid))
        }
        let codexReady = agent == .codex && CodexProgressScreen.emptyComposer(screen)
        let claudeClear = agent == .claude && input.text == "/clear" &&
            ClaudeComposerReadiness.isEmpty(screen) && ActivityDetector.detect(screen,agent:agent).phase != .working
        guard [.message, .submit].contains(input.kind), codexReady || claudeClear || (agent == .agy && AgyComposerReadiness.isEmpty(screen)),
              !RemoteMessageReadiness.hasMenu(screen, agent: agent) else { return .agentMissing }
        let text = claudeClear ? "/clear" : "\u{1b}[200~" + input.text + "\u{1b}[201~"
        return try writeToTab(target: target, screen: screen, agent: agent, text: text, captureIdentity: captureIdentity, run: run)
    }

    static func submitGoalDraft(target: ScreenTarget, screen: String) throws -> TerminalDelivery {
        guard CodexResumeCheck.draftVisible(screen, text: CodexCapacityStop.goalResumeText),
              CodexResumeCheck.goalStalled(CodexResumeCheck.rows(screen)) else { return .screenChanged }
        return try writeToTab(target: target, screen: screen, agent: .codex, text: "",
                              captureIdentity: { try TTYInputIdentity.capture(pid: $0) }, run: nil)
    }

    private static func writeToTab(target: ScreenTarget, screen: String, agent: AgentKind, text: String,
                                   captureIdentity: @Sendable (Int32) throws -> TTYInputIdentity,
                                   run: (@Sendable (String) throws -> String)?) throws -> TerminalDelivery {
        guard let pid = target.sourcePID, target.jobPIDs.contains(pid), let original = target.sourceIdentity,
              original.pid == pid, original.processStart == target.sourceStarted,
              let current = try? captureIdentity(pid), current.sameProcess(as: original),
              current.uid == getuid(), current.effectiveUID == geteuid(), current.processGroup == current.foregroundGroup else {
            return .agentMissing
        }
        let data = try AutomationScript.literal(["tty": target.tty, "screen": screen,
            "text": text, "agent": agent.rawValue] as JSONObject)
        let script = """
        (() => {
          const app = Application('com.apple.Terminal'), target = \(data);
          \(AutomationScript.terminalSelectionGuard)
          const normalize = value => String(value).normalize('NFC').replace(/\\r\\n?/g, '\\n');
          if (!app.running()) return 'missingTarget';
          function skipClosed(read) {try {return read();} catch(error) {if ([-1743,-1744].includes(Number(error.errorNumber || error.number))) throw error;return null;}}
          const matches = [];
          for (const window of app.windows()) for (const tab of skipClosed(() => window.tabs()) || []) {
            if (skipClosed(() => String(tab.tty())) === target.tty) matches.push(tab);
          }
          if (!matches.length) return 'missingTarget';
          for (const tab of matches) {
            if (normalize(tab.contents()) !== normalize(target.screen)) return 'screenChanged';
            if (!tab.processes().some(name => String(name).toLowerCase().includes(target.agent))) return 'agentMissing';
          }
          const tab = matches[0];
          if (normalize(tab.contents()) !== normalize(target.screen)) return 'screenChanged';
          if (!tab.processes().some(name => String(name).toLowerCase().includes(target.agent))) return 'agentMissing';
          if (!preservesSelection(target.tty)) return 'focusHeld';
          app.doScript(target.text, {in: tab});
          return 'sent';
        })();
        """
        let result = try run?(script) ?? AutomationScript.run(script, app: "Terminal", denied: .permissionDenied, timeout: 25)
        if result == "focusHeld" {
            throw RemoteHTTPError(409, "다른 Terminal 창이나 탭의 포커스를 유지하기 위해 입력을 보류했습니다.",
                diagnostics: ["delivery":"not_started", "reason":"terminal_focus"])
        }
        guard let delivered = TerminalDelivery(rawValue: result) else {
            throw RemoteHTTPError(409, "백그라운드 전달 결과를 확인하지 못했습니다. 중복 전송하지 말고 대상 입력을 확인해주세요.", diagnostics: ["delivery": "unknown"])
        }
        return delivered
    }

    static func restartEscape(target: ScreenTarget, agent: AgentKind) throws -> TerminalDelivery {
        guard let pid = target.sourcePID, let identity = try? TTYInputIdentity.capture(pid: pid),
              identity.processStart == target.sourceStarted, identity.processGroup == identity.foregroundGroup,
              identity.uid == getuid(), identity.effectiveUID == geteuid() else { return .agentMissing }
        let environment = try TerminalKeyboard.Environment.live(sourcePID: pid)
        return try TerminalKeyboard.deliver(target: target, expected: "", agent: agent, input: .init(kind: .escape, relay: true),
            environment: environment, timeout: 0.8)
    }

    public static let unavailableBeforeInputMessage = "Mac의 손쉬운 사용에서 AutoApprove의 직접 입력 권한을 허용해주세요."
    public static func deliver(target: ScreenTarget, agent: AgentKind, input: RemoteTerminalInput, screen: String = "",
                               environment: TerminalKeyboard.Environment? = nil,
                               captureIdentity: @escaping @Sendable (Int32) throws -> TTYInputIdentity = { try TTYInputIdentity.capture(pid:$0) }) throws -> TerminalDelivery {
        let startedAt=RemoteTerminalPerformance.now
        var succeeded=false
        defer {RemoteTerminalPerformance.shared.observe(.inputDelivery,elapsed:RemoteTerminalPerformance.now-startedAt,succeeded:succeeded)}
        try input.validate()
        guard let pid = target.sourcePID, let started = target.sourceStarted, target.jobPIDs.contains(pid),
              let original = target.sourceIdentity, original.pid == pid, original.processStart == started else { return .agentMissing }
        let valid: @Sendable () -> Bool = {
            guard let current = try? captureIdentity(pid) else { return false }
            return current.sameProcess(as:original) && current.uid == getuid() && current.effectiveUID == geteuid()
                && current.processGroup == current.foregroundGroup
        }
        guard valid() else { return .agentMissing }
        let environment = try environment ?? TerminalKeyboard.Environment.live(sourcePID:pid)
        var keyboard = environment
        keyboard.postPair = { owner, down, up in
            guard valid() else { throw RemoteHTTPError(409,"원본 CLI의 실행 식별자나 전경 작업이 바뀌어 입력하지 않았습니다.") }
            try environment.postPair(owner,down,up)
        }
        let result=try TerminalKeyboard.deliver(target:target,expected:screen,agent:agent,input:input,environment:keyboard)
        succeeded=result == .sent
        return result
    }
}
