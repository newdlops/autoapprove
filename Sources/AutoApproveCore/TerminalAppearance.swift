import Foundation

/// Display text and insertion point captured together from the verified native
/// text area. Command authorization continues to use TerminalScreen.contents.
public struct TerminalTextSnapshot: Codable, Equatable, Sendable {
    public var screen: String
    public var cursor: TerminalCursor
    public init(screen: String, cursor: TerminalCursor) { self.screen = screen; self.cursor = cursor }
    public func validated() -> Self? {
        let withinBudget: Bool
        if screen.isContiguousUTF8 {
            withinBudget = screen.utf8.count <= 200_000
        } else {
            // Each repaired UTF-16 unit needs between one and three UTF-8
            // bytes. Cocoa supplies its UTF-16 length without transcoding.
            let count = screen.utf16.count
            withinBudget = count <= 200_000 && (count <= 200_000 / 3 || screen.utf8.count <= 200_000)
        }
        guard withinBudget, cursor.validated(for: screen) != nil else { return nil }
        return self
    }
    public static func fromAccessibility(value: String, insertion: Int, visible: NSRange) -> Self? {
        let text = value as NSString
        guard visible.location != NSNotFound, visible.location >= 0, visible.length > 0,
              visible.location <= text.length, visible.length <= text.length - visible.location,
              insertion >= visible.location, insertion - visible.location <= visible.length else { return nil }
        let units = value.utf16
        let start = units.index(units.startIndex, offsetBy: visible.location)
        let end = units.index(start, offsetBy: visible.length)
        guard !(0xdc00...0xdfff).contains(units[start]),
              end == units.endIndex || !(0xdc00...0xdfff).contains(units[end]) else { return nil }
        return Self(screen: text.substring(with: visible), cursor: TerminalCursor(offset: insertion - visible.location)).validated()
    }
}

/// An insertion point reported by the terminal, never inferred from prompt text.
public struct TerminalCursor: Codable, Equatable, Sendable {
    public enum Style: String, Codable, Sendable { case block, bar, underline }
    public var offset: Int
    public var padding: Int
    public var visible: Bool
    public var style: Style
    public var blink: Bool
    public init(offset: Int, padding: Int = 0, visible: Bool = true, style: Style = .block, blink: Bool = true) {
        self.offset = offset; self.padding = padding; self.visible = visible; self.style = style; self.blink = blink
    }
    public func validated(for screen: String) -> TerminalCursor? {
        guard offset >= 0, padding >= 0, padding <= 500 else { return nil }
        if offset == 0 { return self }
        let units = screen.utf16, count = units.count
        guard offset <= count else { return nil }
        if offset == count { return self }
        let index = units.index(units.startIndex, offsetBy: offset)
        return (0xdc00...0xdfff).contains(units[index]) ? nil : self
    }
    static func decode(_ object: Any?, screen: String) -> TerminalCursor? {
        guard let object, JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object), data.count <= 1_024,
              let cursor = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        return cursor.validated(for: screen)
    }
}

/// Original terminal cell attributes; never inferred from words or command output.
/// UTF-16 ranges match the browser and VS Code. Text used to authorize input stays separate.
public struct TerminalAppearance: Codable, Equatable, Sendable {
    public struct Run: Codable, Equatable, Sendable {
        public var offset: Int
        public var length: Int
        public var fg: String?
        public var bg: String?
        public var bold: Bool?
        public var dim: Bool?
        public var italic: Bool?
        public var underline: Bool?
        public var strike: Bool?
        public var inverse: Bool?
        public var hidden: Bool?
        public init(offset: Int, length: Int, fg: String? = nil, bg: String? = nil, bold: Bool? = nil,
                    dim: Bool? = nil, italic: Bool? = nil, underline: Bool? = nil, strike: Bool? = nil,
                    inverse: Bool? = nil, hidden: Bool? = nil) {
            self.offset = offset; self.length = length; self.fg = fg; self.bg = bg; self.bold = bold
            self.dim = dim; self.italic = italic; self.underline = underline; self.strike = strike
            self.inverse = inverse; self.hidden = hidden
        }
    }
    public var runs: [Run]
    public var foreground: String?
    public var background: String?
    public init(runs: [Run], foreground: String? = nil, background: String? = nil) {
        self.runs = runs; self.foreground = foreground; self.background = background
    }
    public func validated(for screen: String) -> TerminalAppearance? {
        func color(_ value: String?) -> Bool {
            guard let value else { return true }
            return value.utf8.count == 7 && value.first == "#" && value.dropFirst().utf8.allSatisfy {
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }
        }
        guard runs.count <= 8_000, color(foreground), color(background) else { return nil }
        if runs.isEmpty { return self }
        @inline(__always) func validate(count: Int, boundary: (Int) -> Bool) -> Self? {
            var end = 0
            for run in runs {
                guard run.offset >= end, run.offset <= count, run.length > 0, run.length <= count - run.offset,
                      boundary(run.offset), boundary(run.offset + run.length), color(run.fg), color(run.bg) else { return nil }
                end = run.offset + run.length
            }
            return self
        }
        // Dense attributes amortize one contiguous array over many lookups.
        if runs.count > 64 {
            let units = Array(screen.utf16)
            return validate(count: units.count) { index in
                index == 0 || index == units.count || !(0xdc00...0xdfff).contains(units[index])
            }
        }
        let units = screen.utf16, count = units.count
        var position = units.startIndex, offset = 0
        return validate(count: count) { index in
            if index == 0 || index == count { return true }
            // Validated, nonoverlapping runs visit boundaries in order.
            units.formIndex(&position, offsetBy: index - offset)
            offset = index
            return !(0xdc00...0xdfff).contains(units[position])
        }
    }
    static func decode(_ object: Any?, screen: String) -> TerminalAppearance? {
        guard let object, JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object), data.count <= 1_500_000,
              let appearance = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        return appearance.validated(for: screen)
    }
}
