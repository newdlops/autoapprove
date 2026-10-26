import Foundation
import Darwin

public struct SessionNotice: Codable, Equatable, Identifiable {
    public enum Kind: String, Codable { case question, completion }
    public var id: String
    public var sourceKey: String
    public var kind: Kind
    public var summary: String
    public var date: Date
    public var isRead: Bool
    public var isInterruption: Bool? = nil
    public var isSystemSafety: Bool? = nil
    public var title: String { isSystemSafety == true ? "시스템 변경 경고" : isInterruption == true ? "작업 중단" : kind == .completion ? "작업 완료" : "응답 필요" }

    public static func key(_ kind: Kind, _ identifier: String) -> String {
        kind.rawValue + ":" + PromptDetector.fingerprint(identifier)
    }
    /// Engine-owned,96-entry memoization. The original String is never retained:
    /// at most256 UTF8 bytes per entry are copied into one compact owned buffer.
    final class KeyCache {
        private struct Entry { var offset: UInt16; let length: UInt16; let key: String }
        private var entries: [Entry] = []
        private var identifierBytes: [UInt8] = []
        private var buckets = [UInt8](repeating: 0, count: 128)
        private var seenLow: UInt64 = 0
        private var seenHigh: UInt64 = 0
        init() { entries.reserveCapacity(24); identifierBytes.reserveCapacity(256) }
        func beginPass() { seenLow = 0; seenHigh = 0 }
        private static func slot(_ kind: Kind, _ bytes: UnsafeBufferPointer<UInt8>) -> Int {
            var hint = UInt64(bytes.count) &* 0x9e3779b97f4a7c15
            if kind == .completion { hint ^= 0xc2b2ae35 }
            if bytes.count >= 8 {
                let raw = UnsafeRawBufferPointer(bytes), span = bytes.count - 8
                hint ^= raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self)
                hint ^= raw.loadUnaligned(fromByteOffset: span / 3, as: UInt64.self) &* 0x85ebca6b
                hint ^= raw.loadUnaligned(fromByteOffset: span * 2 / 3, as: UInt64.self) &* 0xc2b2ae35
                hint ^= raw.loadUnaligned(fromByteOffset: span, as: UInt64.self) &* 0x27d4eb2f
            } else { for byte in bytes { hint = (hint ^ UInt64(byte)) &* 0x100000001b3 } }
            hint ^= hint >> 33; hint &*= 0xff51afd7ed558ccd; hint ^= hint >> 33
            return Int(hint & 127)
        }
        @inline(__always) private func mark(_ index: Int) {
            if index < 64 { seenLow |= UInt64(1) << index }
            else { seenHigh |= UInt64(1) << (index - 64) }
        }
        func key(_ kind: Kind, _ identifier: String) -> String {
            guard identifier.isContiguousUTF8, identifier.utf8.count <= 256 else { return SessionNotice.key(kind, identifier) }
            return identifier.utf8.withContiguousStorageIfAvailable { input in
                var position = Self.slot(kind, input)
                let first: UInt8 = kind == .completion ? 99 : 113
                while buckets[position] != 0 {
                    let index = Int(buckets[position]) - 1, entry = entries[index]
                    if entry.key.utf8.first == first && Int(entry.length) == input.count {
                        let matches = identifierBytes.withUnsafeBufferPointer { bytes in
                            input.isEmpty || memcmp(bytes.baseAddress!.advanced(by: Int(entry.offset)), input.baseAddress!, input.count) == 0
                        }
                        if matches { mark(index); return entry.key }
                    }
                    position = (position + 1) & 127
                }
                let key = SessionNotice.key(kind, identifier)
                if entries.count < 96 {
                    if entries.count == 24 { entries.reserveCapacity(48) }
                    if entries.count == 48 { entries.reserveCapacity(96) }
                    let index = entries.count, offset = identifierBytes.count, needed = offset + input.count
                    if needed > identifierBytes.capacity { identifierBytes.reserveCapacity(((needed + 255) / 256) * 256) }
                    identifierBytes.append(contentsOf: input)
                    entries.append(Entry(offset: UInt16(offset), length: UInt16(input.count), key: key))
                    buckets[position] = UInt8(index + 1); mark(index)
                }
                return key
            } ?? SessionNotice.key(kind, identifier)
        }
        func finishPass() -> Bool {
            if entries.isEmpty { return false }
            let low = entries.count >= 64 ? UInt64.max : (UInt64(1) << entries.count) - 1
            let high = entries.count > 64 ? (UInt64(1) << (entries.count - 64)) - 1 : 0
            if seenLow == low && seenHigh == high { return true }
            var kept = 0, byteEnd = 0
            for index in entries.indices {
                let used = index < 64 ? seenLow & (UInt64(1) << index) != 0 : seenHigh & (UInt64(1) << (index - 64)) != 0
                if used {
                    var entry = entries[index]
                    if byteEnd != Int(entry.offset) {
                        for byte in 0..<Int(entry.length) { identifierBytes[byteEnd + byte] = identifierBytes[Int(entry.offset) + byte] }
                    }
                    entry.offset = UInt16(byteEnd); byteEnd += Int(entry.length); entries[kept] = entry; kept += 1
                }
            }
            entries.removeLast(entries.count - kept)
            if entries.isEmpty { return false }
            identifierBytes.removeLast(identifierBytes.count - byteEnd)
            if identifierBytes.capacity > max(1_024, identifierBytes.count * 2) {
                identifierBytes = identifierBytes.withUnsafeBufferPointer { Array($0) }
            }
            if entries.capacity > max(24, entries.count * 2) {
                entries = entries.withUnsafeBufferPointer { Array($0) }; entries.reserveCapacity(24)
            }
            for index in buckets.indices { buckets[index] = 0 }
            identifierBytes.withUnsafeBufferPointer { bytes in
                for index in entries.indices {
                    let entry = entries[index], start = Int(entry.offset), end = start + Int(entry.length)
                    var position = Self.slot(entry.key.utf8.first == 99 ? .completion : .question,
                        UnsafeBufferPointer(rebasing: bytes[start..<end]))
                    while buckets[position] != 0 { position = (position + 1) & 127 }
                    buckets[position] = UInt8(index + 1)
                }
            }
            return true
        }
    }

}

/// Read receipts and unread events are independent of whether a question still needs an answer.
public struct SessionInbox: Codable, Equatable {
    public struct Candidate {
        public var key: String
        public var kind: SessionNotice.Kind
        public var summary: String
        public var isInterruption: Bool = false
        public var isSystemSafety: Bool = false
        public init(key: String, kind: SessionNotice.Kind, summary: String, isInterruption: Bool = false, isSystemSafety: Bool = false) {
            self.key = key; self.kind = kind; self.summary = summary; self.isInterruption = isInterruption; self.isSystemSafety = isSystemSafety
        }
    }
    private struct Active: Codable, Equatable {
        var id = UUID().uuidString
        var observedAt: Date
        var posted = false
        var acknowledged = false
    }
    private var active: [String: Active] = [:]
    public private(set) var entries: [SessionNotice] = []
    public init() {}

    /// One synchronous collection pass. Summaries are needed only when a new
    /// notice is posted; live and still-debouncing requests keep their state.
    struct Update {
        private var value: SessionInbox
        private let date: Date
        private let reconcilesAbsence: Bool
        private var keys: Set<String> = []
        private var changed = false
        private(set) var count = 0

        init(moving inbox: inout SessionInbox, at date: Date, reconcilesAbsence: Bool) {
            value = SessionInbox(); self.date = date; self.reconcilesAbsence = reconcilesAbsence
            swap(&value, &inbox)
        }

        mutating func append(key: String, kind: SessionNotice.Kind, isInterruption: Bool = false,
                             isSystemSafety: Bool = false, summary: @autoclosure () -> String) {
            count += 1; keys.insert(key)
            var event: Active
            var eventChanged = false
            if let existing = value.active[key] { event = existing }
            else { event = Active(observedAt: date); eventChanged = true; changed = true }
            let delay: TimeInterval = isSystemSafety ? 0 : kind == .completion ? 3 : 0.8
            if !event.posted && date.timeIntervalSince(event.observedAt) >= delay {
                value.entries.insert(SessionNotice(id: event.id, sourceKey: key, kind: kind,
                    summary: String(summary().prefix(600)), date: date, isRead: event.acknowledged,
                    isInterruption: isInterruption ? true : nil, isSystemSafety: isSystemSafety ? true : nil), at: 0)
                event.posted = true; eventChanged = true; changed = true
            }
            // Avoid copying the active dictionary just to write an identical event.
            if eventChanged { value.active[key] = event }
        }

        mutating func finish(into inbox: inout SessionInbox) -> Bool {
            // Removing unobserved keys after the pass preserves existing events
            // for every observed key, including duplicate candidates in order.
            if reconcilesAbsence {
                let removed = value.active.keys.filter { !keys.contains($0) }
                for key in removed { value.active.removeValue(forKey: key) }
                changed = changed || !removed.isEmpty
            }
            if value.entries.count > 50 { value.entries.removeLast(value.entries.count - 50) }
            swap(&value, &inbox)
            return changed
        }
    }

    @discardableResult public mutating func update(_ candidates: [Candidate], at date: Date = Date(), reconcilesAbsence: Bool = true) -> Bool {
        var update = Update(moving: &self, at: date, reconcilesAbsence: reconcilesAbsence)
        for candidate in candidates {
            update.append(key: candidate.key, kind: candidate.kind, isInterruption: candidate.isInterruption,
                isSystemSafety: candidate.isSystemSafety, summary: candidate.summary)
        }
        return update.finish(into: &self)
    }

    @discardableResult public mutating func markRead() -> Bool {
        let previous = self
        for index in entries.indices { entries[index].isRead = true }
        for key in Array(active.keys) { active[key]?.acknowledged = true }
        return self != previous
    }

    public func isRead(_ sourceKey: String) -> Bool {
        active[sourceKey]?.acknowledged ?? entries.first(where: { $0.sourceKey == sourceKey })?.isRead ?? false
    }
}
