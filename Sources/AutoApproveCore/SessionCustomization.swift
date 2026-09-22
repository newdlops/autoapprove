import Foundation

public enum SessionColor: String, Codable, CaseIterable {
    case red, orange, yellow, green, blue, purple, gray

    public var title: String {
        switch self {
        case .red: return "빨강"
        case .orange: return "주황"
        case .yellow: return "노랑"
        case .green: return "초록"
        case .blue: return "파랑"
        case .purple: return "보라"
        case .gray: return "회색"
        }
    }
}

/// User-facing labels belong to an exact execution session, never its project or PID alone.
public struct SessionCustomization: Codable, Equatable {
    public static let titleLimit = 80
    public static let noteLimit = 2_000
    public var title: String
    public var note: String
    public var color: SessionColor?
    public var isEmpty: Bool { title.isEmpty && note.isEmpty && color == nil }

    public init(title: String = "", note: String = "", color: SessionColor? = nil) {
        self.title = title; self.note = note; self.color = color
    }

    public func normalized() throws -> Self {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let memo = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count <= Self.titleLimit else { throw AppError.message("표시 이름은 \(Self.titleLimit)자까지 입력할 수 있습니다.") }
        guard !name.contains(where: \.isNewline) else { throw AppError.message("표시 이름은 한 줄로 입력해주세요.") }
        guard memo.count <= Self.noteLimit else { throw AppError.message("메모는 \(Self.noteLimit.formatted())자까지 입력할 수 있습니다.") }
        return Self(title: name, note: memo, color: color)
    }

    private enum CodingKeys: String, CodingKey { case title, note, color }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        note = try values.decodeIfPresent(String.self, forKey: .note) ?? ""
        // A newer version's color must not discard a saved name or note.
        color = (try values.decodeIfPresent(String.self, forKey: .color)).flatMap(SessionColor.init(rawValue:))
    }
}

extension AgentSession {
    public var displayedTerminalTitle: String {
        if let name = customization?.title, !name.isEmpty { return name }
        return terminalTitle ?? "터미널 제목 미확인"
    }

    public func matchesSearch(_ query: String) -> Bool {
        query.isEmpty || "\(project) \(terminalTitle ?? "") \(customization?.title ?? "") \(customization?.note ?? "") \(gitBranch?.name ?? "") \(cwd) \(agent.title) \(pid) \(tty)".localizedCaseInsensitiveContains(query) || backgroundChildren.contains { $0.matchesSearch(query) }
    }
}
