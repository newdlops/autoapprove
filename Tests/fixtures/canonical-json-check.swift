import Foundation
import CoreFoundation
import CryptoKit
import AutoApproveCore

struct TransientJSONCheck {
    enum Failure: Error { case mismatch(String) }
    static var cases = 0, scalars = 0, units = 0, foreign = 0, models = 0
    static var digest: UInt64 = 1469598103934665603
    static let reference: JSONEncoder = {
        let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601
        value.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return value
    }()
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure.mismatch(message) } }
    static func mix(_ value: UInt64) { digest = (digest ^ value) &* 1099511628211 }
    static func raw(_ text: String) -> [UInt16] {
        let value = text as NSString
        var output = [UInt16](repeating: 0, count: value.length)
        if !output.isEmpty { output.withUnsafeMutableBufferPointer { value.getCharacters($0.baseAddress!, range: NSRange(location: 0, length: $0.count)) } }
        return output
    }
    static func stored(_ units: [UInt16], _ kind: Int) -> String {
        if kind == 0 { return String(decoding: units, as: UTF16.self) }
        if units.isEmpty { return "" }
        return units.withUnsafeBufferPointer {
            if kind == 1 { return NSString(characters: $0.baseAddress!, length: $0.count) as String }
            return unsafeBitCast(CFStringCreateWithCharacters(kCFAllocatorDefault, $0.baseAddress!, $0.count)!, to: NSString.self) as String
        }
    }
    static func error(_ value: Error) -> [String] {
        if case EncodingError.invalidValue(_, let context) = value {
            return ["invalidValue", context.debugDescription] + context.codingPath.map { $0.stringValue + ":" + ($0.intValue.map(String.init) ?? "nil") }
        }
        let ns = value as NSError; return [ns.domain, String(ns.code), String(describing: value)]
    }
    static func check<T: Encodable>(_ value: T, hint: Int = 64) throws {
        let a = Result { try reference.encode(value) }, b = Result { try FixtureCanonicalJSON.encode(value, using: reference, reserveHint: hint) }
        switch (a, b) {
        case (.success(let expected), .success(let actual)):
            try require(expected == actual, "JSON bytes changed at case \(cases): expected \(String(decoding: expected.prefix(350), as: UTF8.self)); actual \(String(decoding: actual.prefix(350), as: UTF8.self))")
            for byte in actual { mix(UInt64(byte)) }
        case (.failure(let a), .failure(let b)): try require(error(a) == error(b), "Encoding error/codingPath changed at case \(cases)"); mix(0)
        default: throw Failure.mismatch("Encoding success/failure changed at case \(cases)")
        }
        cases += 1
    }
    static func text(_ value: String) throws {
        let native = value.isContiguousUTF8, original = raw(value), bytes = Array(value.utf8)
        if !native { foreign += 1 }
        try check(value)
        try require(value.isContiguousUTF8 == native && raw(value) == original && value.utf8.elementsEqual(bytes), "String caller storage or bytes changed")
    }
    struct Specials: Encodable {
        let date: Date, data: Data, url: URL, decimal: Decimal
        let text: String, ints: [Int64], unsigned: [UInt64], floats: [Double]
    }
    struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? = nil
        init(stringValue: String) { self.stringValue = stringValue }
        init(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
    }
    struct Containers: Encodable {
        func encode(to encoder: any Encoder) throws {
            var box = encoder.container(keyedBy: DynamicKey.self)
            let key = DynamicKey(stringValue: "nested")
            var first = box.nestedContainer(keyedBy: DynamicKey.self, forKey: key)
            try first.encode("one", forKey: DynamicKey(stringValue: "a"))
            var second = box.nestedContainer(keyedBy: DynamicKey.self, forKey: key)
            try second.encode(2, forKey: DynamicKey(stringValue: "b"))
            var list = box.nestedUnkeyedContainer(forKey: DynamicKey(stringValue: "list"))
            try list.encodeNil(); try list.encode(true)
            var nested = list.nestedContainer(keyedBy: DynamicKey.self)
            try nested.encode([1,2,3], forKey: DynamicKey(stringValue: "items"))
            var empty = box.superEncoder(forKey: DynamicKey(stringValue: "base")).container(keyedBy: DynamicKey.self)
            try empty.encode("base", forKey: DynamicKey(stringValue: "label"))
        }
    }
    struct Repeated: Encodable {
        func encode(to encoder: any Encoder) throws {
            var box = encoder.container(keyedBy: DynamicKey.self)
            try box.encode("first", forKey: DynamicKey(stringValue: "key"))
            try box.encode("last", forKey: DynamicKey(stringValue: "key"))
        }
    }
    struct Nothing: Encodable { func encode(to encoder: any Encoder) throws {} }
    indirect enum Tree: Encodable {
        case leaf(String), list([Tree]), object([String: Tree])
        func encode(to encoder: any Encoder) throws {
            switch self {
            case .leaf(let value): var box = encoder.singleValueContainer(); try box.encode(value)
            case .list(let value): var box = encoder.unkeyedContainer(); for child in value { try box.encode(child) }
            case .object(let value): var box = encoder.container(keyedBy: DynamicKey.self); for (key, child) in value { try box.encode(child, forKey: DynamicKey(stringValue: key)) }
            }
        }
    }
    static func smoke() throws {
        for value in ["", "hello", "한글🙂", "e\u{301}", "\u{2028}\u{2029}", "\0\u{1F}\t\r\n\"/\\"] { try text(value) }
        try check(["a2": "two", "a11": "eleven", "a1": "one", "A": "upper", "a": "lower"])
        var unicode = ["한글": [1,2], "é": [3]]
        unicode["e\u{301}"] = [4]; try check(unicode)
        try check(Containers()); try check(Repeated()); try check(Nothing()); try check([Nothing(), Nothing()])
        try check(["empty": [String](), "values": ["quoted\"", "slash/"]])
        try check([Int.min, -1, 0, 1, Int.max]); try check([UInt64.min, UInt64.max])
        try check([Double.leastNonzeroMagnitude, -0.0, 0.0, Double.greatestFiniteMagnitude])
        try check([Double.nan]); try check(["bad": Double.infinity])
        try check(Specials(date: Date(timeIntervalSince1970: 1_800_000_000.5), data: Data([0,255,1]), url: URL(string: "https://fixture.invalid/한글?q=a%20b")!, decimal: Decimal(string: "123456789.123456789")!, text: "e\u{301}", ints: [Int64.min, Int64.max], unsigned: [UInt64.max], floats: [0.5, -0.0]))
        print("TRANSIENT_JSON_SMOKE cases \(cases); checksum \(digest)")
    }
    static func strings() throws {
        var batch = ""
        for value in UInt32(0)...0x10ffff {
            guard let scalar = UnicodeScalar(value) else { continue }
            scalars += 1; try check("before" + String(scalar) + "after"); try check(["k" + String(scalar): "value", "z": "last"])
            batch.unicodeScalars.append(scalar)
            if scalars % 256 == 0 {
                for kind in 0..<3 { try text(stored(Array(batch.utf16), kind)) }
                batch = ""
            }
        }
        try require(batch.isEmpty, "Incomplete Unicode block")
        for value in UInt32(0)...65535 {
            units += 1
            for kind in 0..<3 { let value = stored([97,0xd800,UInt16(value),0xdc00,122], kind); try text(value); let native = value.isContiguousUTF8, original = raw(value); try check([value: "foreign-key", "z": "last"]); try require(value.isContiguousUTF8 == native && raw(value) == original, "Foreign key caller changed") }
        }
        for a in UInt8(0)...127 { for b in UInt8(0)...127 { try check(String(decoding: [a,b], as: UTF8.self)) } }
        for count in [0,1,7,8,9,31,32,33,255,256,257,4095,4096,4097,65535,65536,65537,999999,1000000,4000000,4000001] {
            for seed in ["x", "한", "🙂", "e\u{301}", "\u{1F}"] {
                try check(String(repeating: seed, count: count / max(1, seed.utf8.count)))
            }
        }
    }
    static func shapes() throws {
        for value in [Int8.min, -1, 0, 1, Int8.max] { try check(value) }
        for value in [Int16.min, -1, 0, 1, Int16.max] { try check(value) }
        for value in [Int32.min, -1, 0, 1, Int32.max] { try check(value) }
        for value in [Int64.min, -1, 0, 1, Int64.max] { try check(value) }
        try check([UInt8.min, UInt8.max]); try check([UInt16.min, UInt16.max]); try check([UInt32.min, UInt32.max]); try check([UInt64.min, UInt64.max])
        var bits: UInt64 = 0
        for _ in 0..<4096 { try check(["float": Double(bitPattern: bits)]); bits &+= 0x9e3779b97f4a7c15 }
        for value in [-62_135_596_800.0, -1, 0, 1, 1_800_000_000.999, 4_102_444_800] {
            try check(Specials(date: Date(timeIntervalSince1970: value), data: Data((0..<256).map(UInt8.init)), url: URL(fileURLWithPath: "/fixture/한글 e\u{301}/../🙂"), decimal: Decimal(string: "-0.000000000000000000001")!, text: "quoted\"\\/", ints: [Int64.min, Int64.max], unsigned: [UInt64.max], floats: [0.1, -0.0]))
        }
        for key in ["e\u{301}", "é", "👩🏽‍💻", "한글"] { for kind in 0..<3 { try check([stored(Array(key.utf16),kind): "first", "z": "last"]) } }; try check(["2": "b", "11": "a", "": "empty"]); try check([2: "b", 11: "a"])
        try check([String: String?](uniqueKeysWithValues: [("missing", nil), ("some", "value")]))
        var tree = Tree.leaf("leaf")
        for depth in 0...140 { if [0,1,7,8,31,32,127,128,129,140].contains(depth) { try check(tree) }; tree = .list([tree]) }
        for count in [0,1,63,64,65,511,512,513,24999,25000,25001] { try check(Array(repeating: "value", count: count)) }
        try check(Tree.object(["z": .list([.leaf("🙂"), .object(["a": .leaf("quoted\"")])]), "a": .leaf("first")]))
    }
    @MainActor static func coreModels() async throws {
        for count in [1,19,96] { for mixed in [false,true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-transient-json-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let records = ProcessDiscovery.parse((0..<count).map { "\(910001+$0) 1 ttys\(100+$0) \(910001+$0) \(910001+$0) Mon Oct 12 09:00:00 2026 /fixture/codex" }.joined(separator: "\n"))
            let engine = try ApprovalEngine(paths: AppPaths(directory: directory), claudeRegistryReader: { _ in [] }, processReader: { records }, terminalInputAvailable: { false }, terminalInputIdentity: { _ in nil })
            defer { engine.stop() }
            engine.updateDiscovery(ProcessDiscovery.sessions(records), records: records)
            let service = RemoteNetworkService(engine: engine, nodeID: "json-fixture", name: mixed ? "합성 e\u{301} 👩🏽‍💻" : "Synthetic Mac", bonjourEnabled: false, loopbackOnly: true, discoveryAddresses: { [] }, onStatus: { _ in })
            defer { service.stop() }
            var dashboard = try await service.dashboard(localAddressReady: false)
            dashboard.updatedAt = Date(timeIntervalSince1970: 0)
            for index in dashboard.nodes[0].state!.sessions.indices {
                dashboard.nodes[0].state!.sessions[index].session.detail = mixed ? "한글 e\u{301} 🙂 /\"\\\n\0" : "ASCII /fixture/file.swift\nREADY> "
                dashboard.nodes[0].state!.sessions[index].session.lastActivity = Date(timeIntervalSince1970: Double(1_800_000_000 + index))
                dashboard.nodes[0].state!.sessions[index].session.capacityResume = CapacityResume(phase: .scheduled, attempt: 1, limit: 4, deadline: Date(timeIntervalSince1970: 1_800_000_020), message: "Continue safely")
            }
            for paused in [false,true] {
                dashboard.nodes[0].state!.snapshot.paused = paused
                try check(dashboard, hint: count * 40 + 128); models += 1
                let canonical = try FixtureCanonicalJSON.encode(dashboard, using: reference, reserveHint: count * 40 + 128)
                let tag = "W/\"" + SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined() + "\""
                try require(try dashboard.response(ifNoneMatch: nil).entityTag == tag, "Actual Core weak validator changed")
                let state = dashboard.nodes[0].state!.inventory
                try check(state, hint: count * 40 + 128); models += 1
                try require(try state.response(ifNoneMatch: nil).body == FixtureCanonicalJSON.encode(state, using: reference, reserveHint: count * 40 + 128), "Actual Core inventory bytes changed")
            }
        } }
    }
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--smoke") { try smoke(); return }
        try strings(); try shapes(); try await coreModels()
        try require(scalars == 1112064 && units == 65536 && foreign > 100000 && models == 24, "Incomplete corpus")
        print("TRANSIENT_JSON scalars \(scalars); utf16Units \(units); cases \(cases); foreign \(foreign); models \(models); checksum \(digest)")
    }
}

import Foundation
import CoreFoundation

struct JSONKeyStorageCheck {
    enum Failure: Error { case mismatch(String) }
    static var scalars = 0, units = 0, cases = 0, foreign = 0
    static var digest: UInt64 = 1469598103934665603
    static let reference: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return encoder
    }()
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure.mismatch(message) } }
    static func raw(_ value: String) -> [UInt16] {
        let text = value as NSString
        var units = [UInt16](repeating:0,count:text.length)
        if !units.isEmpty { units.withUnsafeMutableBufferPointer { text.getCharacters($0.baseAddress!,range:NSRange(location:0,length:$0.count)) } }
        return units
    }
    static func stored(_ units: [UInt16], _ kind: Int) -> String {
        if kind == 0 { return String(decoding:units,as:UTF16.self) }
        return units.withUnsafeBufferPointer {
            if kind == 1 { return NSString(characters:$0.baseAddress!,length:$0.count) as String }
            return unsafeBitCast(CFStringCreateWithCharacters(kCFAllocatorDefault,$0.baseAddress!,$0.count)!,to:NSString.self) as String
        }
    }
    static func error(_ value: Error) -> [String] {
        if case EncodingError.invalidValue(_,let context) = value { return [context.debugDescription] + context.codingPath.map { $0.stringValue + ":" + ($0.intValue.map(String.init) ?? "nil") } }
        return [String(describing:value)]
    }
    static func compare<T: Encodable>(_ value: T) throws {
        let a = Result { try reference.encode(value) }, b = Result { try FixtureCanonicalJSON.encode(value,using:reference) }
        switch (a,b) {
        case (.success(let expected),.success(let actual)):
            try require(expected == actual,"Supplement JSON changed at case \(cases)")
            for byte in actual { digest = (digest ^ UInt64(byte)) &* 1099511628211 }
        case (.failure(let a),.failure(let b)): try require(error(a) == error(b),"Mixed error order/codingPath changed")
        default: throw Failure.mismatch("Success/failure changed")
        }
        cases += 1
    }
    static func key(_ value: String) throws {
        let native = value.isContiguousUTF8, before = raw(value), bytes = Array(value.utf8)
        if !native { foreign += 1 }
        try compare([value:"value", "z":"last"])
        try require(value.isContiguousUTF8 == native && raw(value) == before && value.utf8.elementsEqual(bytes),"Valid/invalid foreign key caller storage changed")
    }
    struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    struct Duplicate: Encodable {
        let keys: [String]
        func encode(to encoder: any Encoder) throws {
            var box = encoder.container(keyedBy: Key.self)
            for (index,key) in keys.enumerated() { try box.encode(index,forKey:Key(stringValue:key)) }
        }
    }
    struct FailureOrder: Encodable { let numbers: [Double]; let scalar: Double }
    static func main() throws {
        var block = ""
        for value in UInt32(0)...0x10ffff {
            guard let scalar = UnicodeScalar(value) else { continue }
            scalars += 1; block.unicodeScalars.append(scalar)
            if scalars % 256 == 0 {
                for kind in 0..<3 { try key(stored(Array(("k"+block).utf16),kind)) }
                block = ""
            }
        }
        try require(block.isEmpty,"Incomplete scalar block")
        for value in UInt32(0)...65535 {
            units += 1
            for kind in 0..<3 { try key(stored([97,UInt16(value),122],kind)) }
        }
        let nfd = "e" + String(UnicodeScalar(0x301)!), nfc = "é"
        for order in [[nfd,"z",nfc],[nfc,"z",nfd],["z",nfd,nfc],[nfd,nfc,"z"]] {
            for kind in 0..<3 { try compare(Duplicate(keys:order.map { stored(Array($0.utf16),kind) })) }
        }
        if #available(macOS 15.0, *) { try compare([Int128.min,-1,0,1,Int128.max]); try compare([UInt128.min,1,UInt128.max]) }
        var bits: UInt32 = 0
        for _ in 0..<4096 { try compare(["float":Float(bitPattern:bits)]); bits &+= 0x9e3779b9 }
        for a in [Double.nan,Double.infinity,-Double.infinity] {
            for b in [Double.nan,Double.infinity,-Double.infinity,0.5] { try compare(FailureOrder(numbers:[a],scalar:b)) }
        }
        try require(scalars == 1112064 && units == 65536 && foreign > 100000,"Incomplete key storage coverage")
        print("JSON_KEY_STORAGE scalars \(scalars); utf16Units \(units); cases \(cases); foreign \(foreign); checksum \(digest)")
    }
}

private enum GuardFailure: Error { case assertion, reference }
private final class IncompatibleReference: JSONEncoder, @unchecked Sendable {
    var calls = 0
    var fail = false
    override func encode<T: Encodable>(_ value: T) throws -> Data {
        calls += 1
        if fail { throw GuardFailure.reference }
        return Data("{\"legacy\":true}".utf8)
    }
}
private enum CompatibilityCheck {
    static func require(_ condition: Bool) throws { if !condition { throw GuardFailure.assertion } }
    static func main() throws {
        let reference = JSONEncoder(); reference.dateEncodingStrategy = .iso8601
        reference.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let modern = responseJSONCompatible(reference)
        try require(responseJSONFastCompatible == modern)
        let value = ["text":"한글 e" + String(UnicodeScalar(0x301)!) + "🙂", "a2":"two", "a11":"eleven"]
        let expected = try reference.encode(value)
        try require(try responseCanonicalJSON(value, using:reference, reserveHint:64) == expected)
        try require(try responseCanonicalJSON(value, using:reference, reserveHint:64, compatible:false) == expected)
        let legacy = IncompatibleReference(); legacy.dateEncodingStrategy = .iso8601
        legacy.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try require(!responseJSONCompatible(legacy))
        let calls = legacy.calls
        try require(try responseCanonicalJSON(value, using:legacy, reserveHint:64, compatible:false) == Data("{\"legacy\":true}".utf8))
        try require(legacy.calls == calls + 1)
        legacy.fail = true
        try require(!responseJSONCompatible(legacy))
        do { _ = try responseCanonicalJSON(value, using:legacy, reserveHint:64, compatible:false); throw GuardFailure.assertion }
        catch GuardFailure.reference {}
        reference.outputFormatting = [.prettyPrinted]
        try require(!responseJSONCompatible(reference))
        print("JSON_COMPATIBILITY modern \(modern); incompatible false; explicit fallback exact; reference error preserved; unsupported formatting false")
    }
}

private enum FixtureCanonicalJSON {
    static func encode<T: Encodable>(_ value:T,using reference:JSONEncoder,reserveHint:Int=64)throws->Data {
        try responseCanonicalJSON(value,using:reference,reserveHint:reserveHint)
    }
}
@main struct CanonicalJSONFixture {
    @MainActor static func main() async throws {
        try CompatibilityCheck.main()
        try await TransientJSONCheck.main()
        try JSONKeyStorageCheck.main()
    }
}
