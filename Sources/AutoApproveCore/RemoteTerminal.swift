import Foundation

public struct RemoteTerminalInput: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, enter, escape, interrupt, up, down, tab }
    public var kind: Kind
    public var text: String
    public init(kind: Kind, text: String = "") { self.kind = kind; self.text = text }
    public var bytes: String {
        switch kind {
        case .text: return text
        case .enter: return "\r"
        case .escape: return "\u{1b}"
        case .interrupt: return "\u{03}"
        case .up: return "\u{1b}[A"
        case .down: return "\u{1b}[B"
        case .tab: return "\t"
        }
    }
    public func validate() throws {
        guard kind != .text || (!text.isEmpty && text.utf8.count <= 8_000 && text.unicodeScalars.allSatisfy({ ($0.value >= 32 && $0.value != 127) || $0 == "\n" || $0 == "\t" })),
              kind == .text || text.isEmpty else { throw RemoteHTTPError(400, "텍스트는 제어 문자 없이 8,000바이트 이내로 입력해주세요.") }
    }
}

public enum RemoteTerminalAdapter {
    public static func input(host: ScreenHost, target: ScreenTarget, expected: String, agent: AgentKind, input: RemoteTerminalInput) throws -> TerminalDelivery {
        try input.validate()
        if host == .orca {
            guard let handle = target.handle else { return .missingTarget }
            guard OrcaAdapter.normalize(try OrcaAdapter.readScreen(handle: handle)) == OrcaAdapter.normalize(expected) else { return .screenChanged }
            let result = try OrcaAdapter.sendComposed(handle: handle, text: input.bytes)
            return (result["send"] as? JSONObject)?["accepted"] as? Bool == true ? .sent : .missingTarget
        }
        let result = try AutomationScript.run(script(host: host, target: target, expected: expected, agent: agent, input: input),
            app: host.title, denied: host == .terminal ? .permissionDenied : .automationDenied(host.title))
        guard let delivery = TerminalDelivery(rawValue: result) else { throw AppError.message("입력 전달 결과를 확인하지 못했습니다. 화면을 확인해주세요.") }
        return delivery
    }
    public static func script(host: ScreenHost, target: ScreenTarget, expected: String, agent: AgentKind, input: RemoteTerminalInput) throws -> String {
        guard agent != .shell, host != .orca else { throw RemoteHTTPError(400, "이 터미널의 입력 방식은 지원하지 않습니다.") }
        try input.validate()
        guard host != .terminal || [.text, .enter].contains(input.kind) else { throw RemoteHTTPError(400, "Terminal에서는 텍스트와 Enter만 사용할 수 있습니다.") }
        let data = try AutomationScript.literal(["tty": target.tty, "expected": expected, "agent": agent.rawValue,
            "text": input.kind == .enter && host == .terminal ? "" : input.bytes, "jobPIDs": target.jobPIDs.map(Int.init)] as JSONObject)
        let helpers = """
        function normalize(text) { return String(text).normalize('NFC').replace(/\\r\\n?/g, '\\n'); }
        function skipClosed(read) {
          try { return read(); } catch (error) {
            if (Number(error.errorNumber || error.number) === -1743 || String(error).includes('-1743')) throw error;
            return null;
          }
        }
        """
        if host == .terminal {
            return """
            (() => {
            const app = Application('com.apple.Terminal'); const target = \(data);
            \(helpers)
            if (app.running()) for (const window of app.windows()) for (const tab of skipClosed(() => window.tabs()) || []) {
              if (skipClosed(() => tab.tty()) !== target.tty) continue;
              if (normalize(tab.contents()) !== normalize(target.expected)) return 'screenChanged';
              if (!tab.processes().some(p => p.toLowerCase().includes(target.agent))) return 'agentMissing';
              app.doScript(String(target.text).normalize('NFC'), {in:tab});
              return 'sent';
            }
            return 'missingTarget';
            })();
            """
        }
        return """
        (() => {
        const app = Application('com.googlecode.iterm2'); const target = \(data);
        \(helpers)
        \(ITermAdapter.visibleFunction)
        if (app.running()) for (const window of app.windows()) for (const tab of skipClosed(() => window.tabs()) || [])
        for (const session of skipClosed(() => tab.sessions()) || []) {
          if (skipClosed(() => session.tty()) !== target.tty) continue;
          if (normalize(visible(session)) !== normalize(target.expected)) return 'screenChanged';
          let job = 0;
          try { job = Number(session.variable({named: 'jobPid'})) || 0; } catch (_) {}
          if (!target.jobPIDs.includes(job)) return 'agentMissing';
          session.write({text: String(target.text).normalize('NFC'), newline: false});
          return 'sent';
        }
        return 'missingTarget';
        })();
        """
    }
}
