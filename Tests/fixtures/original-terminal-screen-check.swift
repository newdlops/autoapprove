import Foundation
import AutoApproveCore

@main struct OriginalScreenChecks {
    static func main() throws {
        let source = "\u{1b}[38;2;217;119;87;1mClaude 한글 🧪\u{1b}[0m plain\r\n\u{1b}[38;2;135;215;255;48;2;48;48;48;3;4;9mCodex\u{1b}[0m"
        let screen = try OriginalTerminalScreen.render(ansi: source, columns: 80, rows: 12, tty: "/dev/original")
        precondition(screen.contents.hasPrefix("Claude 한글 🧪 plain\nCodex"))
        let appearance = screen.appearance!.validated(for: screen.contents)!
        precondition(appearance.runs[0].fg == "#d97757" && appearance.runs[0].bold == true)
        precondition(appearance.runs[0].length == "Claude 한글 🧪".utf16.count)
        let codex = appearance.runs.first { $0.fg == "#87d7ff" }!
        precondition(codex.offset == "Claude 한글 🧪 plain\n".utf16.count)
        precondition(codex.bg == "#303030" && codex.italic == true && codex.underline == true && codex.strike == true)
        precondition(screen.cursor!.offset == "Claude 한글 🧪 plain\nCodex".utf16.count)
        precondition(screen.tty == "/dev/original")
        print("PASS original ANSI RGB/styles/Unicode ranges/authoritative cursor")
        let hidden = try OriginalTerminalScreen.render(ansi: "\u{1b}[?1049h\u{1b}[H\u{1b}[7;8mALT\u{1b}[0m\u{1b}[?25l\u{1b}[5 q", columns: 40, rows: 6, tty: "/dev/original")
        precondition(hidden.contents.hasPrefix("ALT") && hidden.cursor?.visible == false && hidden.cursor?.style == .bar)
        precondition(hidden.appearance?.runs[0].inverse == true && hidden.appearance?.runs[0].hidden == true)
        let padded = try OriginalTerminalScreen.render(ansi: "x\u{1b}[2;10H", columns: 40, rows: 6, tty: "/dev/original")
        precondition(padded.cursor?.offset == 2 && padded.cursor?.padding == 9)
        print("PASS alternate screen/hidden cursor/inverse/padding")
        let emojiCell = try OriginalTerminalScreen.render(ansi: "A🧪B\u{1b}[1;3H", columns: 40, rows: 6, tty: "/dev/original")
        let koreanCell = try OriginalTerminalScreen.render(ansi: "가나\u{1b}[1;2H", columns: 40, rows: 6, tty: "/dev/original")
        let afterEmoji = try OriginalTerminalScreen.render(ansi: "A🧪B\u{1b}[1;4H", columns: 40, rows: 6, tty: "/dev/original")
        guard emojiCell.cursor?.offset == 1, emojiCell.cursor?.padding == 1,
              koreanCell.cursor?.offset == 0, koreanCell.cursor?.padding == 1,
              afterEmoji.cursor?.offset == 3, afterEmoji.cursor?.padding == 0 else {
            throw AppError.message("Cursor must preserve the exact cell inside wide Korean and emoji characters")
        }
        print("PASS wide Korean/emoji cursor cells and UTF-16 boundaries")
        for (columns, rows) in [(0, 12), (501, 12), (80, 0), (80, 301)] {
            do { _ = try OriginalTerminalScreen.render(ansi: source, columns: columns, rows: rows, tty: "/dev/original"); fatalError("Invalid owner geometry accepted") }
            catch { }
        }
        do { _ = try OriginalTerminalScreen.render(ansi: String(repeating: "x", count: 4_194_305), columns: 80, rows: 12, tty: "/dev/original"); fatalError("Oversized original state accepted") }
        catch { }
        print("PASS bounded original state; no PTY or process created")
    }
}
