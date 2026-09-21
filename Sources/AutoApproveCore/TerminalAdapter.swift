import Foundation
import CoreGraphics

public struct TerminalScreen: Codable {
    public var tty: String
    public var contents: String
    public var title: String?
    public init(tty: String, contents: String, title: String? = nil) { self.tty = tty; self.contents = contents; self.title = title }
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
    public var errorDescription: String? {
        "Terminal 자동화 권한이 필요합니다. 시스템 설정 → 개인정보 보호 및 보안 → 자동화에서 AutoApprove를 허용한 후 다시 연결해주세요."
    }
}

public enum TerminalDelivery: String, Codable { case sent, screenChanged, missingTarget, agentMissing }

public struct TerminalWindowBounds: Codable, Equatable {
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

public enum TerminalAdapter {
    private static func javascript(_ body: String) throws -> String {
        let result = try CommandRunner.run("/usr/bin/osascript", ["-l", "JavaScript", "-e", body], timeout: 8)
        guard result.status == 0 else {
            if result.error.contains("-1743") { throw TerminalAdapterError.permissionDenied }
            throw AppError.message("Terminal 연결 실패: \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func literal(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]), as: UTF8.self)
    }
    public static func screens(ttys: [String]) throws -> TerminalSnapshot {
        let output = try javascript(screenScript(ttys: ttys))
        return try JSONDecoder().decode(TerminalSnapshot.self, from: Data(output.utf8))
    }
    /// Exposed for contract tests against Terminal's scripting dictionary, without sending Apple events.
    public static func screenScript(ttys: [String]) throws -> String {
        let allowed = try literal(ttys)
        return """
        const app = Application('com.apple.Terminal');
        const allowed = \(allowed); const screens = []; const failures = [];
        function recordFailure(tty, error) {
          if (Number(error.errorNumber || error.number) === -1743 || String(error).includes('-1743')) throw error;
          failures.push({tty:tty, message:String(error)});
        }
        if (!app.running()) throw Error('Terminal 앱을 먼저 실행해주세요.');
        for (const window of app.windows()) {
          let tabs;
          try { tabs = window.tabs(); } catch (error) { recordFailure(null, error); continue; }
          for (const tab of tabs) {
            let tty = null;
            try {
              tty = tab.tty();
              if (!allowed.includes(tty)) continue;
              // A tab has customTitle, not name. Window name belongs only to its selected tab.
              let title = null;
              try { title = String(tab.customTitle() || '').trim() || null; } catch (_) {}
              if (!title) try {
                if (tabs.length === 1 || tab.selected()) title = String(window.name() || '').trim() || null;
              } catch (_) {}
              screens.push({tty:tty, contents:tab.contents(), title:title});
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
        guard agent != .shell else { throw AppError.message("일반 셸에는 승인 입력을 전달할 수 없습니다.") }
        guard let prompt = PromptDetector.detect(expectedScreen, agent: agent) else { throw AppError.message("승인 요청의 내용과 선택지를 확인하지 못했습니다.") }
        // Compare the complete active dialog, preserving command whitespace. Unrelated history can change.
        let data = try literal(["tty": tty, "dialog": prompt.dialog, "agent": agent.rawValue])
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
        if (app.running()) for (const window of app.windows()) for (const tab of window.tabs()) {
          if (tab.tty() !== target.tty) continue;
          if (activeDialog(tab.contents()) !== normalize(target.dialog)) return 'screenChanged';
          if (!tab.processes().some(p => p.toLowerCase().includes(target.agent))) return 'agentMissing';
          app.doScript('1', {in:tab});
          return 'sent';
        }
        return 'missingTarget';
        })();
        """
    }
}
