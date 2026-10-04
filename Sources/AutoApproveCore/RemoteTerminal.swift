import Foundation
import ApplicationServices

public enum TerminalKeyboard {
    public static var isAvailable: Bool { AXIsProcessTrusted() }
}

public struct RemoteTerminalInput: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, submit, characters, enter, escape, interrupt, up, down, left, right, backspace, delete, home, end, tab }
    public var kind: Kind
    public var text: String
    public var relay: Bool? = nil
    public init(kind: Kind, text: String = "", relay: Bool = false) { self.kind = kind; self.text = text; self.relay = relay ? true : nil }
    public var isRelay: Bool { relay == true && ![.text, .submit].contains(kind) }
    public var bytes: String {
        switch kind {
        case .text, .characters: return text
        case .submit: return text + "\r"
        case .enter: return "\r"
        case .escape: return "\u{1b}"
        case .interrupt: return "\u{03}"
        case .up: return "\u{1b}[A"
        case .down: return "\u{1b}[B"
        case .left: return "\u{1b}[D"
        case .right: return "\u{1b}[C"
        case .backspace: return "\u{7f}"
        case .delete: return "\u{1b}[3~"
        case .home: return "\u{1b}[H"
        case .end: return "\u{1b}[F"
        case .tab: return "\t"
        }
    }
    public func validate() throws {
        let textual = [.text, .submit, .characters].contains(kind)
        guard !textual || (!text.isEmpty && text.utf8.count <= 8_000 && text.unicodeScalars.allSatisfy({ ($0.value >= 32 && $0.value != 127) || kind != .characters && ($0 == "\n" || $0 == "\t") })),
              textual || text.isEmpty else { throw RemoteHTTPError(400, "텍스트는 제어 문자 없이 8,000바이트 이내로 입력해주세요.") }
    }
}

public enum RemoteTerminalAdapter {
    public static func input(host: ScreenHost, target: ScreenTarget, expected: String, agent: AgentKind, input: RemoteTerminalInput) throws -> TerminalDelivery {
        try input.validate()
        if host == .terminal, ![.text, .submit].contains(input.kind), !TerminalKeyboard.isAvailable, input.kind != .enter {
            throw RemoteHTTPError(409, "Mac의 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 AutoApprove를 허용하면 Terminal의 실시간 입력과 특수 키를 사용할 수 있습니다.")
        }
        if host == .orca {
            guard let handle = target.handle else { return .missingTarget }
            if !input.isRelay, OrcaAdapter.normalize(try OrcaAdapter.readScreen(handle: handle)) != OrcaAdapter.normalize(expected) { return .screenChanged }
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
        let terminalKeyboard = host == .terminal && (!([.text, .submit, .enter].contains(input.kind)) || input.isRelay && input.kind == .enter)
        let data = try AutomationScript.literal(["tty": target.tty, "expected": expected, "agent": agent.rawValue,
            "text": host == .terminal && [.text, .submit].contains(input.kind) ? input.text : input.kind == .enter && host == .terminal ? "" : input.bytes,
            "jobPIDs": target.jobPIDs.map(Int.init), "relay": input.isRelay] as JSONObject)
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
            let keyCodes: [RemoteTerminalInput.Kind: Int] = [.escape: 53, .interrupt: 8, .up: 126, .down: 125, .left: 123, .right: 124, .backspace: 51, .delete: 117, .home: 115, .end: 119, .tab: 48]
            let keyboardAction = input.kind == .characters
                ? "events.keystroke(String(target.text).normalize('NFC'));"
                : "events.keyCode(\(keyCodes[input.kind] ?? 36)\(input.kind == .interrupt ? ", {using: ['control down']}" : ""));"
            let delivery = terminalKeyboard ? """
              ObjC.import('ApplicationServices');
              if (!$.AXIsProcessTrusted()) throw Error('Mac의 손쉬운 사용 설정에서 AutoApprove를 허용해주세요.');
              window.miniaturized = false; window.selectedTab = tab; window.index = 1; app.activate();
              if (!app.frontmost() || window.selectedTab().tty() !== target.tty) return 'missingTarget';
              if (!target.relay && normalize(tab.contents()) !== normalize(target.expected)) return 'screenChanged';
              const events = Application('com.apple.systemevents');
              \(keyboardAction)
            """ : "app.doScript(String(target.text).normalize('NFC'), {in:tab});"
            return """
            (() => {
            const app = Application('com.apple.Terminal'); const target = \(data);
            \(helpers)
            if (app.running()) for (const window of app.windows()) for (const tab of skipClosed(() => window.tabs()) || []) {
              if (skipClosed(() => tab.tty()) !== target.tty) continue;
              if (!target.relay && normalize(tab.contents()) !== normalize(target.expected)) return 'screenChanged';
              if (!tab.processes().some(p => p.toLowerCase().includes(target.agent))) return 'agentMissing';
              \(delivery)
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
          if (!target.relay && normalize(visible(session)) !== normalize(target.expected)) return 'screenChanged';
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
