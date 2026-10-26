import Foundation
import Darwin

/// Only response snapshots enter this encoder. Nothing is cached between
/// events. Unsupported representations retain the existing JSON encoder.
enum RemoteTerminalWire {
    static let version = 3
    static let contentType = "application/vnd.autoapprove.terminal-v2"
    static let compactContentType = "application/vnd.autoapprove.terminal-v3"
    static let byteLimit = 2_000_000
    static let heartbeat = Data([65,65,2,4,0])
    static let fields = ["sessionID","screen","revision","observedAt","keys","inputReason","appearance","cursor","streamID","nativeDisplay","outputReason","sequence","question","screenPatch","screenCopy","appearanceUnchanged","ptyID","offset","data","reset","columns","rows","exitCode","canInput"]
    static let fieldIndices = Dictionary(uniqueKeysWithValues: fields.enumerated().map { ($0.element,$0.offset) })
    static func negotiated(_ value: String?) -> Int? { value == "3" ? 3 : value == "2" ? 2 : nil }
    static func contentType(for version: Int) -> String { version == 3 ? compactContentType : contentType }
    static func version(for contentType: String?) -> Int? { contentType == compactContentType ? 3 : contentType == self.contentType ? 2 : nil }
    static func heartbeat(version: Int) -> Data { version == 3 ? Data([65,65,3,4,0]) : heartbeat }
}

final class RemoteTerminalWireEncoder {
    private enum RetryFoundation: Error { case required }
    private static let nodeLimit = 100_000, byteLimit = RemoteTerminalWire.byteLimit, depthLimit = 64
    private let reference: JSONEncoder
    private let version: Int
    init(jsonEncoder: JSONEncoder, version: Int = 2) { precondition(version == 2 || version == 3); reference = jsonEncoder; self.version = version }

    func encode<T: Encodable>(_ value: T, event: UInt8) throws -> Data {
        precondition(event < 4)
        do { return try attempt(value, event: event) }
        catch is RetryFoundation {
            let json = try reference.encode(value)
            guard json.count <= Self.byteLimit else { throw RemoteHTTPError(502,"터미널 화면이 너무 큽니다. 화면 크기를 줄여 다시 연결해주세요.") }
            let out = try Output(hint:json.count)
            try json.withUnsafeBytes { try out.append($0) }
            return out.takeData(event:event | 128,version:version)
        }
    }
    private func attempt<T: Encodable>(_ value: T, event: UInt8) throws -> Data {
        let arena = Arena(reference:reference, reserveHint:64,compact:version == 3), root = arena.add()
        try Cursor(arena:arena,slot:root,parent:nil,key:nil).put(value)
        try arena.check()
        let fields: [(String,Int)]
        switch arena.values[root] {
        case .object(let object): fields = object.fields
        case .empty: fields = []
        default: throw RetryFoundation.required
        }
        var mask: UInt32 = 0
        // The fixed fields already have unique mask bits. Reuse those bits
        // for duplicate detection instead of allocating a second string set.
        var known = [Int](repeating:0,count:RemoteTerminalWire.fields.count), extra: [(String,Int)] = []
        var extraNames = Set<String>()
        for (key,id) in fields {
            if let index = RemoteTerminalWire.fieldIndices[key] {
                let bit: UInt32 = 1 << index
                guard mask & bit == 0 else { throw RetryFoundation.required }
                mask |= bit; known[index] = id
            } else {
                guard extraNames.insert(key).inserted else { throw RetryFoundation.required }
                extra.append((key,id))
            }
        }
        let out = try Output(hint:arena.wireBound+8)
        for shift in stride(from:0,to:32,by:8) { try out.byte(UInt8(truncatingIfNeeded:mask >> shift)) }
        var remaining = mask
        while remaining != 0 {
            let index = remaining.trailingZeroBitCount
            try arena.write(known[index],to:out,depth:0,rawData:event == 2 && index == 18)
            remaining &= remaining - 1
        }
        try out.uint(UInt64(extra.count))
        for (key,id) in extra { try out.string(key); try arena.write(id,to:out,depth:0) }
        return out.takeData(event:event,version:version)
    }
    private final class ObjectValues { var fields: [(String,Int)] = [] }
    private final class ArrayValues { var elements: [Int] = [] }
    private enum Atom { case empty, null, bool(Bool), string(String), unsigned(UInt64), negative(UInt64), double(Double), object(ObjectValues), array(ArrayValues), packed(PackedValue) }
    /// Known value snapshots bypass per-key strings and temporary encoder nodes.
    /// The box keeps the general Atom stride small, including on legacy v2.
    private final class PackedValue {
        enum Value { case cursor(TerminalCursor), run(TerminalAppearance.Run), appearance(TerminalAppearance), patch(RemoteTerminalScreenPatch), copy(RemoteTerminalScreenCopy) }
        let value: Value
        let extraNodes: Int, jsonBound: Int, wireBound: Int, depth: Int
        init(_ value: Value,nodes: Int,json: Int,wire: Int,depth: Int) { self.value=value;extraNodes=nodes;jsonBound=json;wireBound=wire;self.depth=depth }
        static func unsigned(_ value: Int) -> Bool { value >= 0 && value <= 9_007_199_254_740_991 }
        static func color(_ value: String?) -> Bool {
            guard let value else { return true }
            return value.utf8.count == 7 && value.utf8.first == 35 && value.utf8.dropFirst().allSatisfy {
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }
        }
        static func runFields(_ value: TerminalAppearance.Run) -> Int {
            2 + (runFlags(value) & 511).nonzeroBitCount
        }
        static func runFlags(_ value: TerminalAppearance.Run) -> UInt64 {
            var flags: UInt64 = (value.fg == nil ? 0:1) | (value.bg == nil ? 0:2)
            if let b=value.bold { flags |= 4;if b { flags |= 512 } }
            if let b=value.dim { flags |= 8;if b { flags |= 1024 } }
            if let b=value.italic { flags |= 16;if b { flags |= 2048 } }
            if let b=value.underline { flags |= 32;if b { flags |= 4096 } }
            if let b=value.strike { flags |= 64;if b { flags |= 8192 } }
            if let b=value.inverse { flags |= 128;if b { flags |= 16384 } }
            if let b=value.hidden { flags |= 256;if b { flags |= 32768 } }
            return flags
        }
        static func valid(_ value: TerminalAppearance.Run) -> Bool { unsigned(value.offset) && unsigned(value.length) && color(value.fg) && color(value.bg) }
        static func cursor(_ value: TerminalCursor) -> PackedValue? {
            guard unsigned(value.offset), unsigned(value.padding) else { return nil }
            return PackedValue(.cursor(value),nodes:10,json:150,wire:20,depth:1)
        }
        static func run(_ value: TerminalAppearance.Run) -> PackedValue? {
            guard valid(value) else { return nil }
            return PackedValue(.run(value),nodes:2*runFields(value),json:240,wire:48,depth:1)
        }
        static func appearance(_ value: TerminalAppearance) -> PackedValue? {
            guard value.runs.count <= 8000, color(value.foreground), color(value.background) else { return nil }
            var nodes=2*(1+(value.foreground == nil ? 0:1)+(value.background == nil ? 0:1))
            for run in value.runs { guard valid(run) else { return nil };nodes += 1+2*runFields(run) }
            return PackedValue(.appearance(value),nodes:nodes,json:100+value.runs.count*241,wire:32+value.runs.count*48,depth:value.runs.isEmpty ? 1:3)
        }
        static func patch(_ value: RemoteTerminalScreenPatch,valid: (String)->Bool) -> PackedValue? {
            guard unsigned(value.baseLength), unsigned(value.prefix), unsigned(value.suffix), unsigned(value.length),valid(value.baseRevision),valid(value.text) else { return nil }
            let bytes=value.baseRevision.utf8.count+value.text.utf8.count
            return PackedValue(.patch(value),nodes:12,json:200+bytes*6,wire:64+bytes,depth:1)
        }
        static func copy(_ value: RemoteTerminalScreenCopy,valid: (String)->Bool) -> PackedValue? {
            guard unsigned(value.baseLength), unsigned(value.start), unsigned(value.count), unsigned(value.length),valid(value.baseRevision),valid(value.head),valid(value.tail) else { return nil }
            let bytes=value.baseRevision.utf8.count+value.head.utf8.count+value.tail.utf8.count
            return PackedValue(.copy(value),nodes:14,json:220+bytes*6,wire:72+bytes,depth:1)
        }
        private func run(_ value: TerminalAppearance.Run,to out: Output) throws {
            try out.uint(UInt64(value.offset));try out.uint(UInt64(value.length))
            try out.uint(Self.runFlags(value))
            if let color=value.fg { try out.string(color) };if let color=value.bg { try out.string(color) }
        }
        func write(to out: Output) throws {
            switch value {
            case .cursor(let value):
                try out.byte(0x52)
                let style: UInt8 = value.style == .block ? 0 : value.style == .bar ? 1:2
                try out.byte((value.visible ? 1:0) | (value.blink ? 2:0) | style << 2)
                try out.uint(UInt64(value.offset));try out.uint(UInt64(value.padding))
            case .run(let value): try out.byte(0x51);try run(value,to:out)
            case .appearance(let value):
                try out.byte(0x53);try out.byte((value.foreground == nil ? 0:1) | (value.background == nil ? 0:2))
                if let color=value.foreground { try out.string(color) };if let color=value.background { try out.string(color) }
                try out.uint(UInt64(value.runs.count));for value in value.runs { try run(value,to:out) }
            case .patch(let value):
                try out.byte(0x54);try out.string(value.baseRevision)
                try out.uint(UInt64(value.baseLength));try out.uint(UInt64(value.prefix));try out.uint(UInt64(value.suffix))
                try out.string(value.text);try out.uint(UInt64(value.length))
            case .copy(let value):
                try out.byte(0x55);try out.string(value.baseRevision)
                try out.uint(UInt64(value.baseLength));try out.uint(UInt64(value.start));try out.uint(UInt64(value.count))
                try out.string(value.head);try out.string(value.tail);try out.uint(UInt64(value.length))
            }
        }
    }
    private struct PathKey: CodingKey {
        private let name: String?
        let intValue: Int?
        var stringValue: String { name ?? "Index \(intValue!)" }
        init(_ value: any CodingKey) { name = value.stringValue; intValue = value.intValue }
        init(stringValue: String) { name = stringValue; intValue = nil }
        // Most value snapshots never inspect codingPath. Keep the index value
        // until its descriptive string is actually requested.
        init(intValue: Int) { name = nil; self.intValue = intValue }
    }
    private final class Arena {
        // JSON admission and binary capacity have separate upper bounds.
        // UUID/RGB/base64 packing can only reduce the UTF-8 bound below.
        var values: [Atom] = [], estimate = 0, wireBound = 0, keyCount = 0, packedNodes = 0, unsupported = false
        let reference: JSONEncoder
        let compact: Bool
        init(reference: JSONEncoder,reserveHint:Int,compact:Bool) { self.reference=reference;self.compact=compact;values.reserveCapacity(reserveHint) }
        func add() -> Int {
            guard values.count < nodeLimit else { unsupported=true;return 0 }
            let id=values.count;values.append(.empty);wireBound+=1;return id
        }
        func check() throws { if unsupported || estimate > byteLimit || values.count+keyCount+packedNodes > nodeLimit { throw RetryFoundation.required } }
        func set(_ atom:Atom,at id:Int,estimated:Int,wire:Int) throws { try check();values[id]=atom;estimate+=estimated;wireBound+=wire-1;try check() }
        func object(_ id:Int) -> ObjectValues {
            if case .object(let object)=values[id] { return object }
            if case .empty=values[id] {} else { unsupported=true }
            let object=ObjectValues();values[id] = .object(object);estimate+=2;return object
        }
        func array(_ id:Int) -> ArrayValues {
            if case .array(let array)=values[id] { return array }
            if case .empty=values[id] {} else { unsupported=true }
            let array=ArrayValues();values[id] = .array(array);estimate+=2;return array
        }
        // A conservative JSON-size bound preserves the existing 2MB limit.
        // Oversized estimates choose the exact legacy encoding, never reject
        // an otherwise valid large terminal snapshot.
        func textBound(_ count:Int) -> Int {
            return count <= byteLimit ? count*6+2 : byteLimit+1
        }
        // Short strings and empty compounds still occupy their exact one-byte
        // header. Count growth adds a byte only at a varint boundary.
        func wireTextBound(_ count:Int) -> Int {
            let count=min(byteLimit,count)
            return count + (count<15 ? 1 : count<128 ? 2 : count<16384 ? 3 : 4)
        }
        func countHeaderGrowth(_ count:Int) -> Int { count==15 || count==128 || count==16384 ? 1 : 0 }
        func validString(_ value:String) -> Bool {
            if value.isContiguousUTF8 { return true }
            let source=value as NSString;var index=0
            while index < source.length {
                let unit=source.character(at:index)
                if (0xd800...0xdbff).contains(unit) {
                    guard index+1<source.length,(0xdc00...0xdfff).contains(source.character(at:index+1)) else { return false };index+=2
                } else if (0xdc00...0xdfff).contains(unit) { return false }
                else { index+=1 }
            }
            return true
        }
        func field(_ id:Int,key:String,reuse:Bool=false) -> Int {
            let object=object(id)
            if reuse,let old=object.fields.first(where:{$0.0==key}) { return old.1 }
            if !validString(key) { unsupported=true }
            let child=add();object.fields.append((key,child));keyCount+=1;let count=key.utf8.count;estimate+=textBound(count)+2;wireBound+=wireTextBound(count)+countHeaderGrowth(object.fields.count);return child
        }
        func element(_ id:Int) -> (Int,Int) {
            let array=array(id),index=array.elements.count,child=add();array.elements.append(child);estimate+=1;wireBound+=countHeaderGrowth(index+1);return(child,index)
        }
        func string(_ value:String,at id:Int) throws {
            guard validString(value) else { throw RetryFoundation.required }
            let count=value.utf8.count
            try set(.string(value),at:id,estimated:textBound(count),wire:wireTextBound(count))
        }
        func number<T:BinaryInteger>(_ value:T,at id:Int) throws {
            if value >= 0,let exact=UInt64(exactly:value),exact <= 9_007_199_254_740_991 { try set(.unsigned(exact),at:id,estimated:20,wire:9) }
            else if value < 0,let exact=Int64(exactly:value),exact >= -9_007_199_254_740_991 { try set(.negative(UInt64(-(exact+1))),at:id,estimated:20,wire:9) }
            else { throw RetryFoundation.required }
        }
        func primitive<T:Encodable>(_ value:T,at id:Int) throws -> Bool {
            if compact {
                let packed: PackedValue?
                if T.self == TerminalCursor.self { packed=PackedValue.cursor(value as! TerminalCursor) }
                else if T.self == TerminalAppearance.self { packed=PackedValue.appearance(value as! TerminalAppearance) }
                else if T.self == TerminalAppearance.Run.self { packed=PackedValue.run(value as! TerminalAppearance.Run) }
                else if T.self == RemoteTerminalScreenPatch.self { packed=PackedValue.patch(value as! RemoteTerminalScreenPatch,valid:validString) }
                else if T.self == RemoteTerminalScreenCopy.self { packed=PackedValue.copy(value as! RemoteTerminalScreenCopy,valid:validString) }
                else { packed=nil }
                if let packed { packedNodes+=packed.extraNodes;try set(.packed(packed),at:id,estimated:packed.jsonBound,wire:packed.wireBound);return true }
            }
            if #available(macOS 15.0, *) {
                if T.self == Int128.self { try number(value as! Int128,at:id);return true }
                if T.self == UInt128.self { try number(value as! UInt128,at:id);return true }
            }
            if T.self == String.self { try string(value as! String,at:id) }
            else if T.self == Bool.self { try set(.bool(value as! Bool),at:id,estimated:5,wire:1) }
            else if T.self == Int.self { try number(value as! Int,at:id) }
            else if T.self == Int8.self { try number(value as! Int8,at:id) }
            else if T.self == Int16.self { try number(value as! Int16,at:id) }
            else if T.self == Int32.self { try number(value as! Int32,at:id) }
            else if T.self == Int64.self { try number(value as! Int64,at:id) }
            else if T.self == UInt.self { try number(value as! UInt,at:id) }
            else if T.self == UInt8.self { try number(value as! UInt8,at:id) }
            else if T.self == UInt16.self { try number(value as! UInt16,at:id) }
            else if T.self == UInt32.self { try number(value as! UInt32,at:id) }
            else if T.self == UInt64.self { try number(value as! UInt64,at:id) }
            else if T.self == Double.self {
                let double=value as! Double;guard double.isFinite else { throw RetryFoundation.required }
                try set(.double(double),at:id,estimated:32,wire:9)
            } else if T.self == Date.self {
                // Date keeps Foundation's exact ISO8601 formatting. No complete
                // event JSON is generated or parsed on the normal binary path.
                let bytes=try reference.encode(value)
                guard bytes.count>=2,bytes.first==34,bytes.last==34 else { throw RetryFoundation.required }
                let text=String(decoding:bytes.dropFirst().dropLast(),as:UTF8.self)
                guard text.utf8.allSatisfy({$0>=32 && $0<127 && $0 != 34 && $0 != 92}) else { throw RetryFoundation.required }
                try set(.string(text),at:id,estimated:bytes.count,wire:wireTextBound(bytes.count-2))
            } else if T.self == Data.self { try string((value as! Data).base64EncodedString(),at:id) }
            else if T.self == Float.self || T.self == Decimal.self || T.self == URL.self { throw RetryFoundation.required }
            else { return false }
            return true
        }
        func write(_ id:Int,to out:Output,depth:Int,rawData:Bool=false) throws {
            try check();guard depth<=depthLimit else { throw RetryFoundation.required }
            switch values[id] {
            case .empty: try out.head(8,0)
            case .null: try out.byte(0)
            case .bool(let value): try out.byte(value ? 32 : 16)
            case .string(let value):
                if rawData,let raw=Data(base64Encoded:value),raw.base64EncodedString()==value { try out.head(9,raw.count);try raw.withUnsafeBytes { try out.append($0) } }
                else { try out.string(value) }
            case .unsigned(let value): try out.number(3,value)
            case .negative(let value): try out.number(4,value)
            case .double(let value):
                try out.byte(80);var bits=value.bitPattern.littleEndian;try withUnsafeBytes(of:&bits) { try out.append($0) }
            case .array(let array):
                try out.head(7,array.elements.count)
                for child in array.elements { try write(child,to:out,depth:depth+1) }
            case .object(let object):
                try out.head(8,object.fields.count);var seen=Set<String>()
                for(key,child) in object.fields {
                    guard seen.insert(key).inserted else { throw RetryFoundation.required }
                    try out.string(key);try write(child,to:out,depth:depth+1)
                }
            case .packed(let value):
                guard depth+value.depth <= depthLimit else { throw RetryFoundation.required }
                try value.write(to:out)
            }
        }
    }
    private final class Output {
        private var pointer:UnsafeMutableRawPointer?
        private var capacity:Int,count=7
        init(hint:Int) throws {
            capacity=min(byteLimit+7,max(64,hint+7));pointer=malloc(capacity)
            guard pointer != nil else { throw RetryFoundation.required }
        }
        deinit { free(pointer) }
        private func reserve(_ amount:Int) throws {
            guard amount>=0,amount<=byteLimit+7-count else { throw RetryFoundation.required }
            let wanted=count+amount
            if wanted>capacity {
                let next=min(byteLimit+7,max(wanted,capacity*2))
                guard let resized=realloc(pointer,next) else { throw RetryFoundation.required };pointer=resized;capacity=next
            }
        }
        func byte(_ value:UInt8) throws { try reserve(1);pointer!.storeBytes(of:value,toByteOffset:count,as:UInt8.self);count+=1 }
        func append(_ bytes:UnsafeRawBufferPointer) throws {
            try reserve(bytes.count)
            if !bytes.isEmpty { pointer!.advanced(by:count).copyMemory(from:bytes.baseAddress!,byteCount:bytes.count);count+=bytes.count }
        }
        func uint(_ value:UInt64) throws {
            var rest=value
            while rest>=128 { try byte(UInt8(truncatingIfNeeded:rest) | 128);rest >>= 7 }
            try byte(UInt8(rest))
        }
        func head(_ tag:UInt8,_ count:Int) throws { try number(tag,UInt64(count)) }
        func number(_ tag:UInt8,_ value:UInt64) throws {
            if value<15 { try byte(tag << 4 | UInt8(value)) }
            else { try byte(tag << 4 | 15);try uint(value) }
        }
        private func nibble(_ byte:UInt8) -> UInt8? {
            if byte>=48 && byte<=57 { return byte-48 }
            if byte>=65 && byte<=70 { return byte-55 }
            if byte>=97 && byte<=102 { return byte-87 }
            return nil
        }
        func string(_ value:String) throws {
            var text=value;text.makeContiguousUTF8()
            guard let _ = try text.utf8.withContiguousStorageIfAvailable({ bytes in
                let count=bytes.count
                let uuid=count==36,color=count==7 && bytes[0]==35,hex=count>=32 && count<=512 && count.isMultiple(of:2)
                if uuid || color || hex {
                    var upper=false,lower=false,valid=true
                    for(index,byte) in bytes.enumerated() {
                        if uuid && (index==8 || index==13 || index==18 || index==23) { if byte != 45 { valid=false;break };continue }
                        if color && index==0 { continue }
                        guard nibble(byte) != nil else { valid=false;break }
                        if byte>=65 && byte<=70 { upper=true }
                        if byte>=97 && byte<=102 { lower=true }
                    }
                    if valid && !(upper && lower) {
                        let tag:UInt8 = uuid ? (upper ? 13:12) : color ? (upper ? 15:14) : (upper ? 11:10)
                        if uuid || color { try byte(tag << 4) }
                        else { try head(tag,count/2) }
                        var high:UInt8?
                        for(index,value) in bytes.enumerated() {
                            if color && index==0 || uuid && (index==8 || index==13 || index==18 || index==23) { continue }
                            let part=nibble(value)!
                            if let previous=high { try byte(previous << 4 | part);high=nil } else { high=part }
                        }
                        return
                    }
                }
                try head(6,count);try append(UnsafeRawBufferPointer(bytes))
            }) else { throw RetryFoundation.required }
        }
        func takeData(event:UInt8,version:Int) -> Data {
            let length=count-7,headerCount=length<128 ? 5 : length<16384 ? 6 : 7,owned=pointer!
            if headerCount<7 { memmove(owned.advanced(by:headerCount),owned.advanced(by:7),length) }
            let bytes=owned.assumingMemoryBound(to:UInt8.self);bytes[0]=65;bytes[1]=65;bytes[2]=UInt8(version);bytes[3]=event
            var rest=length,index=4
            repeat { bytes[index]=UInt8(rest&127) | (rest>=128 ? 128 : 0);rest >>= 7;index+=1 } while rest>0
            pointer=nil;return Data(bytesNoCopy:owned,count:headerCount+length,deallocator:.free)
        }
    }
    private final class Cursor: Encoder {
        let arena: Arena, slot: Int, parent: Cursor?, key: PathKey?
        let depth: Int
        var codingPath: [any CodingKey] { (parent?.codingPath ?? []) + (key.map { [$0 as any CodingKey] } ?? []) }
        var userInfo: [CodingUserInfoKey: Any] { [:] }
        init(arena: Arena, slot: Int, parent: Cursor?, key: PathKey?) {
            self.arena = arena; self.slot = slot; self.parent = parent; self.key = key; depth = (parent?.depth ?? -1) + 1
        }
        func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
            _ = arena.object(slot); return KeyedEncodingContainer(Keyed<Key>(cursor: self))
        }
        func unkeyedContainer() -> any UnkeyedEncodingContainer { _ = arena.array(slot); return Unkeyed(cursor: self) }
        func singleValueContainer() -> any SingleValueEncodingContainer { Single(cursor: self) }
        func child(_ id: Int, key: PathKey) -> Cursor { Cursor(arena: arena, slot: id, parent: self, key: key) }
        func put<T: Encodable>(_ value: T) throws {
            try arena.check(); guard depth <= depthLimit else { throw RetryFoundation.required }
            if try arena.primitive(value, at: slot) { return }
            try value.encode(to: self)
        }
        func putChild<T: Encodable, Key: CodingKey>(_ value: T, at id: Int, key: Key) throws {
            try arena.check(); guard depth < depthLimit else { throw RetryFoundation.required }
            if try arena.primitive(value, at: id) { return }
            try value.encode(to: child(id, key: PathKey(key)))
        }
        func putElement<T: Encodable>(_ value: T, at id: Int, index: Int) throws {
            try arena.check(); guard depth < depthLimit else { throw RetryFoundation.required }
            if try arena.primitive(value, at: id) { return }
            try value.encode(to: child(id, key: PathKey(intValue: index)))
        }
        func number<T: BinaryInteger>(_ value: T) throws { try arena.number(value, at: slot) }
        func null() throws { try arena.set(.null, at: slot, estimated: 4, wire:1) }
    }
    private struct Keyed<Key: CodingKey>: KeyedEncodingContainerProtocol {
        let cursor: Cursor
        var codingPath: [any CodingKey] { cursor.codingPath }
        private func target(_ key: Key, reuse: Bool = false) -> Cursor { cursor.child(cursor.arena.field(cursor.slot, key: key.stringValue, reuse: reuse), key: PathKey(key)) }
        private func put<T: Encodable>(_ value: T, forKey key: Key) throws {
            let id = cursor.arena.field(cursor.slot, key: key.stringValue)
            try cursor.putChild(value, at: id, key: key)
        }
        private func integer<T: BinaryInteger>(_ value: T, forKey key: Key) throws {
            let id = cursor.arena.field(cursor.slot, key: key.stringValue)
            try cursor.arena.number(value, at: id)
        }
        mutating func encodeNil(forKey key: Key) throws {
            let id = cursor.arena.field(cursor.slot, key: key.stringValue)
            try cursor.arena.set(.null, at: id, estimated: 4, wire:1)
        }
        mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws { try put(value, forKey: key) }
        mutating func encode(_ value: Bool, forKey key: Key) throws { try put(value, forKey: key) }
        mutating func encode(_ value: String, forKey key: Key) throws { let id = cursor.arena.field(cursor.slot, key: key.stringValue); try cursor.arena.string(value, at: id) }
        mutating func encode(_ value: Double, forKey key: Key) throws { try put(value, forKey: key) }
        mutating func encode(_ value: Float, forKey key: Key) throws { try put(value, forKey: key) }
        mutating func encode(_ value: Int, forKey key: Key) throws { try integer(value, forKey: key) }
        mutating func encode(_ value: Int8, forKey key: Key) throws { try integer(value, forKey: key) }
        mutating func encode(_ value: Int16, forKey key: Key) throws { try integer(value, forKey: key) }
        mutating func encode(_ value: Int32, forKey key: Key) throws { try integer(value, forKey: key) }
        mutating func encode(_ value: Int64, forKey key: Key) throws { try integer(value, forKey: key) }
        mutating func encode(_ value: UInt, forKey key: Key) throws { try integer(value, forKey: key) }
        mutating func encode(_ value: UInt8, forKey key: Key) throws { try integer(value, forKey: key) }
        mutating func encode(_ value: UInt16, forKey key: Key) throws { try integer(value, forKey: key) }
        mutating func encode(_ value: UInt32, forKey key: Key) throws { try integer(value, forKey: key) }
        mutating func encode(_ value: UInt64, forKey key: Key) throws { try integer(value, forKey: key) }
        mutating func nestedContainer<Nested: CodingKey>(keyedBy type: Nested.Type, forKey key: Key) -> KeyedEncodingContainer<Nested> { target(key, reuse: true).container(keyedBy: type) }
        mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer { target(key, reuse: true).unkeyedContainer() }
        mutating func superEncoder() -> any Encoder {
            let key = PathKey(stringValue: "super"); return cursor.child(cursor.arena.field(cursor.slot, key: key.stringValue, reuse: true), key: key)
        }
        mutating func superEncoder(forKey key: Key) -> any Encoder { target(key, reuse: true) }
    }
    private struct Unkeyed: UnkeyedEncodingContainer {
        let cursor: Cursor
        var codingPath: [any CodingKey] { cursor.codingPath }
        var count: Int { cursor.arena.array(cursor.slot).elements.count }
        private func target() -> Cursor { let (id, index) = cursor.arena.element(cursor.slot); return cursor.child(id, key: PathKey(intValue: index)) }
        private func put<T: Encodable>(_ value: T) throws {
            let (id, index) = cursor.arena.element(cursor.slot)
            try cursor.putElement(value, at: id, index: index)
        }
        private func integer<T: BinaryInteger>(_ value: T) throws {
            let (id, _) = cursor.arena.element(cursor.slot)
            try cursor.arena.number(value, at: id)
        }
        mutating func encodeNil() throws {
            let (id, _) = cursor.arena.element(cursor.slot)
            try cursor.arena.set(.null, at: id, estimated: 4, wire:1)
        }
        mutating func encode<T: Encodable>(_ value: T) throws { try put(value) }
        mutating func encode(_ value: Bool) throws { try put(value) }
        mutating func encode(_ value: String) throws { let (id, _) = cursor.arena.element(cursor.slot); try cursor.arena.string(value, at: id) }
        mutating func encode(_ value: Double) throws { try put(value) }
        mutating func encode(_ value: Float) throws { try put(value) }
        mutating func encode(_ value: Int) throws { try integer(value) }
        mutating func encode(_ value: Int8) throws { try integer(value) }
        mutating func encode(_ value: Int16) throws { try integer(value) }
        mutating func encode(_ value: Int32) throws { try integer(value) }
        mutating func encode(_ value: Int64) throws { try integer(value) }
        mutating func encode(_ value: UInt) throws { try integer(value) }
        mutating func encode(_ value: UInt8) throws { try integer(value) }
        mutating func encode(_ value: UInt16) throws { try integer(value) }
        mutating func encode(_ value: UInt32) throws { try integer(value) }
        mutating func encode(_ value: UInt64) throws { try integer(value) }
        mutating func nestedContainer<Nested: CodingKey>(keyedBy type: Nested.Type) -> KeyedEncodingContainer<Nested> { target().container(keyedBy: type) }
        mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer { target().unkeyedContainer() }
        mutating func superEncoder() -> any Encoder { target() }
    }
    private struct Single: SingleValueEncodingContainer {
        let cursor: Cursor
        var codingPath: [any CodingKey] { cursor.codingPath }
        mutating func encodeNil() throws { try cursor.null() }
        mutating func encode<T: Encodable>(_ value: T) throws { try cursor.put(value) }
        mutating func encode(_ value: Bool) throws { try cursor.put(value) }
        mutating func encode(_ value: String) throws { try cursor.arena.string(value, at: cursor.slot) }
        mutating func encode(_ value: Double) throws { try cursor.put(value) }
        mutating func encode(_ value: Float) throws { try cursor.put(value) }
        mutating func encode(_ value: Int) throws { try cursor.number(value) }
        mutating func encode(_ value: Int8) throws { try cursor.number(value) }
        mutating func encode(_ value: Int16) throws { try cursor.number(value) }
        mutating func encode(_ value: Int32) throws { try cursor.number(value) }
        mutating func encode(_ value: Int64) throws { try cursor.number(value) }
        mutating func encode(_ value: UInt) throws { try cursor.number(value) }
        mutating func encode(_ value: UInt8) throws { try cursor.number(value) }
        mutating func encode(_ value: UInt16) throws { try cursor.number(value) }
        mutating func encode(_ value: UInt32) throws { try cursor.number(value) }
        mutating func encode(_ value: UInt64) throws { try cursor.number(value) }
    }
}
