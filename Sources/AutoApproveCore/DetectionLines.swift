import Foundation

/// Shared preparation during one frame observation. The engine discards this object
/// afterwards; only detector results stay cached, so scrollback arrays do not accumulate.
final class DetectionLines {
    private let screen: String
    lazy var raw = PromptDetector.normalizedLines(screen)
    private var trimmedRows: [String]?
    var trimmed: [String] {
        if let trimmedRows { return trimmedRows }
        let rows = raw.map { $0.trimmingCharacters(in: .whitespaces) }; trimmedRows = rows; return rows
    }
    func trimmedSuffix(_ count: Int) -> [String] {
        if let trimmedRows { return Array(trimmedRows.suffix(count)) }
        return raw.suffix(count).map { $0.trimmingCharacters(in: .whitespaces) }
    }
    init(_ screen: String) { self.screen = screen }
}
