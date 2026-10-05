import Foundation
private import CPTY

/// Restores owner-provided ANSI cells. This parser never creates a terminal
/// process, takes a PTY driver lease, resizes the owner or answers its queries.
public enum OriginalTerminalScreen {
    private struct Cell {
        var text: String
        var column: Int
        var info: APVTCellInfo
        var visible: Bool { text != " " || info.background_default == 0 || info.flags & (4 | 8) != 0 }
    }
    private struct Style: Equatable {
        var flags: Int32
        var foreground: UInt32?
        var background: UInt32?
        init(_ info: APVTCellInfo) {
            flags = info.flags; foreground = info.foreground_default == 0 ? info.foreground : nil
            background = info.background_default == 0 ? info.background : nil
        }
        var plain: Bool { flags == 0 && foreground == nil && background == nil }
        func run(offset: Int, length: Int) -> TerminalAppearance.Run {
            TerminalAppearance.Run(offset: offset, length: length,
                fg: foreground.map { String(format: "#%06x", $0) }, bg: background.map { String(format: "#%06x", $0) },
                bold: flags & 1 != 0 ? true : nil, italic: flags & 2 != 0 ? true : nil,
                underline: flags & 4 != 0 ? true : nil, strike: flags & 32 != 0 ? true : nil,
                inverse: flags & 8 != 0 ? true : nil, hidden: flags & 16 != 0 ? true : nil)
        }
    }
    public static func render(ansi: String, columns: Int, rows: Int, tty: String) throws -> TerminalScreen {
        guard (1...500).contains(columns), (1...300).contains(rows), ansi.utf8.count <= 4_194_304,
              let terminal = ap_vt_new(Int32(rows), Int32(columns)) else {
            throw RemoteHTTPError(502, "원본 터미널 상태의 크기나 형식을 확인하지 못했습니다.")
        }
        defer { ap_vt_free(terminal) }
        let bytes = Data(ansi.utf8)
        bytes.withUnsafeBytes { ap_vt_feed(terminal, $0.baseAddress?.assumingMemoryBound(to: CChar.self), $0.count) }
        var cursor = APVTCursorInfo(); ap_vt_cursor(terminal, &cursor)
        var screen = "", offset = 0, runs = [TerminalAppearance.Run](), previousStyle: Style?
        var cursorOffset = 0, cursorPadding = 0
        var buffer = [CChar](repeating: 0, count: 32)
        for row in 0..<rows {
            if row > 0 { screen += "\n"; offset += 1; previousStyle = nil }
            var cells = [Cell](); cells.reserveCapacity(columns)
            for column in 0..<columns {
                var info = APVTCellInfo()
                let count = ap_vt_cell(terminal, Int32(row), Int32(column), &info, &buffer, buffer.count)
                guard count >= 0 else { throw RemoteHTTPError(502, "원본 터미널 셀을 복원하지 못했습니다.") }
                if count > 0 { cells.append(Cell(text: String(cString: buffer), column: column, info: info)) }
            }
            let used = cells.lastIndex(where: \.visible).map { $0 + 1 } ?? 0
            let visible = cells.prefix(used)
            if row == Int(cursor.row) {
                let before = visible.prefix { $0.column + Int($0.info.width) <= Int(cursor.column) }
                cursorOffset = offset + before.reduce(0) { $0 + $1.text.utf16.count }
                let occupied = before.last.map { $0.column + Int($0.info.width) } ?? 0
                cursorPadding = max(0, Int(cursor.column) - occupied)
            }
            for cell in visible {
                let length = cell.text.utf16.count, style = Style(cell.info)
                if !style.plain {
                    if previousStyle == style, let last = runs.last, last.offset + last.length == offset {
                        runs[runs.count - 1].length += length
                    } else { runs.append(style.run(offset: offset, length: length)) }
                }
                previousStyle = style; screen += cell.text; offset += length
            }
        }
        guard screen.utf8.count <= 200_000, runs.count <= 8_000 else {
            throw RemoteHTTPError(502, "원본 터미널 화면이나 서식이 전송 한도를 넘었습니다. Mac에서 화면 크기를 줄여주세요.")
        }
        let insertion = TerminalCursor(offset: cursorOffset, padding: cursorPadding, visible: cursor.visible != 0,
            style: cursor.shape == 2 ? .underline : cursor.shape == 3 ? .bar : .block, blink: cursor.blink != 0)
        return TerminalScreen(tty: tty, contents: screen, appearance: TerminalAppearance(runs: runs).validated(for: screen),
            cursor: insertion.validated(for: screen))
    }
}
