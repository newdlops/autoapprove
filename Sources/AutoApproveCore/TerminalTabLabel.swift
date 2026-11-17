import Foundation

/// Absolute tab label, separate from command input and terminal text colors.
public struct TerminalTabLabel: Codable, Equatable, Sendable {
    public var title: String
    public var color: String?
    public init(title: String, color: String? = nil) { self.title = title; self.color = color }
    public static let markers = ["red":"🔴", "orange":"🟠", "yellow":"🟡", "green":"🟢", "blue":"🔵", "purple":"🟣", "gray":"⚪️"]
    public static func baseTitle(_ title:String) -> String {
        var result=title
        while let prefix=markers.values.map({$0+" "}).first(where:{result.hasPrefix($0)}) {result.removeFirst(prefix.count)}
        return result
    }
    public func validated() throws -> Self {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 80, !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.union(.newlines).contains),
              color.map({ Self.markers[$0] != nil }) ?? true else { throw AppError.message("탭 이름은 한 줄로 1~80자, 색상은 red·orange·yellow·green·blue·purple·gray 또는 default를 사용해주세요.") }
        return .init(title: title, color: color)
    }
    public var rendered: String {
        if let color, let marker = Self.markers[color] { return marker + " " + title }
        return title
    }
}

public enum TerminalTabLabelAdapter {
    public static func apply(host: ScreenHost, target: ScreenTarget, label: TerminalTabLabel) throws -> String {
        let label = try label.validated()
        let output = try AutomationScript.run(script(host: host, tty: target.tty, label: label),
            app: host == .terminal ? "Terminal" : "iTerm2", denied: host == .terminal ? .permissionDenied : .automationDenied("iTerm2"))
        guard let data = output.data(using: .utf8), let result = try JSONSerialization.jsonObject(with: data) as? JSONObject,
              result["tty"] as? String == target.tty, result["title"] as? String == label.rendered else { throw AppError.message("원래 탭에 적용된 이름을 확인하지 못했습니다.") }
        return label.rendered
    }
    public static func script(host: ScreenHost, tty: String, label: TerminalTabLabel) throws -> String {
        guard [.terminal, .iterm].contains(host), tty.hasPrefix("/dev/"), !tty.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AppError.message("탭 이름·색상 표식 변경은 Terminal과 iTerm2에서 지원합니다.")
        }
        let label = try label.validated()
        let target = try AutomationScript.literal(["tty": tty, "title": label.rendered])
        let lookup = host == .terminal
            ? "for (const window of app.windows()) for (const tab of skipClosed(() => window.tabs()) || []) if (skipClosed(() => tab.tty()) === target.tty) { found = tab; break; }"
            : "for (const window of app.windows()) for (const tab of skipClosed(() => window.tabs()) || []) for (const session of skipClosed(() => tab.sessions()) || []) if (skipClosed(() => session.tty()) === target.tty) { found = session; foundTab = tab; break; }"
        let property = host == .terminal ? "customTitle" : "name"
        return """
        (() => {
          const app = Application('\(host == .terminal ? "com.apple.Terminal" : "com.googlecode.iterm2")'), target = \(target);
          if (!app.running()) throw Error('터미널 앱이 실행 중이 아닙니다.');
          function skipClosed(read) { try { return read(); } catch(error) { if ([-1743,-1744].includes(Number(error.errorNumber || error.number))) throw error; return null; } }
          let found = null, foundTab = null;
          \(lookup)
          if (!found || found.tty() !== target.tty) throw Error('원래 터미널 탭을 찾지 못했습니다.');
          \(host == .terminal ? "found.customTitle(); found.titleDisplaysCustomTitle();" : "found.name(); foundTab.title();")
          found.\(property) = target.title;
          \(host == .terminal ? "found.titleDisplaysCustomTitle = true; if (found.titleDisplaysCustomTitle() !== true) throw Error('탭의 사용자 지정 제목 표시를 확인하지 못했습니다.');" : "foundTab.title = target.title; if (String(foundTab.title()) !== target.title) throw Error('탭 제목 적용 결과가 다릅니다.');")
          if (found.tty() !== target.tty || String(found.\(property)()) !== target.title) throw Error('탭 이름 적용 결과가 다릅니다.');
          return JSON.stringify({tty:target.tty,title:String(found.\(property)())});
        })();
        """
    }
}
