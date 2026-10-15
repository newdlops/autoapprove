import Foundation

/// A negotiated scroll delta: retain one verified UTF-16 span from the previous
/// screen and surround it with new text. KMP finds both scroll directions in
/// linear time. Work is bounded to 128Ki code units per screen; larger or
/// unrelated screens keep the existing replacement/full-frame fallback.
public struct RemoteTerminalScreenCopy: Codable, Sendable {
    public let baseRevision: String
    public let baseLength: Int
    public let start: Int
    public let count: Int
    public let head: String
    public let tail: String
    public let length: Int

    public static func make(previous: String, current: String, baseRevision: String) -> Self? {
        guard previous.utf16.count <= 131_072, current.utf16.count <= 131_072,
              min(previous.utf16.count,current.utf16.count) >= 1024, baseRevision.utf8.count <= 512 else { return nil }
        let before = Array(previous.utf16), after = Array(current.utf16)
        func overlap(_ source: [UInt16], _ pattern: [UInt16]) -> Int {
            var table = [Int](repeating: 0, count: pattern.count), matched = 0
            for index in 1..<pattern.count {
                while matched > 0, pattern[index] != pattern[matched] { matched = table[matched-1] }
                if pattern[index] == pattern[matched] { matched += 1 }
                table[index] = matched
            }
            matched = 0
            for unit in source {
                while matched > 0, matched == pattern.count || unit != pattern[matched] { matched = table[matched-1] }
                if unit == pattern[matched] { matched += 1 }
            }
            return matched
        }
        let forward = overlap(before,after), backward = overlap(after,before)
        let count = max(forward,backward)
        guard count >= 1024, count > baseRevision.utf8.count + 512 else { return nil }
        let start = forward >= backward ? before.count-count : 0
        let headLength = forward >= backward ? 0 : after.count-count
        func boundary(_ index: Int, in units: [UInt16]) -> Bool {
            index == 0 || index == units.count || !(0xD800...0xDBFF).contains(units[index-1]) || !(0xDC00...0xDFFF).contains(units[index])
        }
        guard boundary(start,in:before), boundary(start+count,in:before),
              boundary(headLength,in:after), boundary(headLength+count,in:after) else { return nil }
        return Self(baseRevision:baseRevision,baseLength:before.count,start:start,count:count,
            head:String(decoding:after[..<headLength],as:UTF16.self),
            tail:String(decoding:after[(headLength+count)...],as:UTF16.self),length:after.count)
    }
}
