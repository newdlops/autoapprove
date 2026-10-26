// Synthetic protocol regression. Compile against matching release Core with
// -disable-access-control;the exact product encoder source is compiled without
// edits. The terminal DTO,patch/copy and gzip implementations are linked Core.
import Foundation
import CryptoKit
import AutoApproveCore

private struct SyntheticAlive: Encodable {
    let streamID: String?
    let revision: String
    let sequence: Int?
    let observedAt: Date
}

@main private enum TerminalWireFixture {
    static let version = CommandLine.arguments.contains("--v3") ? 3 : 2
    static let referenceWire = RemoteTerminalWireEncoder(jsonEncoder:encoder(),version:2)
    static func output(_ value: [String: Any]) throws {
        print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self))
    }
    static func encoder() -> JSONEncoder {
        let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601
        value.outputFormatting = [.withoutEscapingSlashes]; return value
    }
    static func emit(name: String, index: Int, event: String, id: String?, json: Data, binary: Data, reference: Data? = nil) throws {
        var sse = Data("event: \(event)\n".utf8)
        if let id { sse.append(contentsOf: "id: \(id)\n".utf8) }
        sse.append(contentsOf: "data: ".utf8); sse.append(json); sse.append(contentsOf: "\n\n".utf8)
        try output(["case": name, "index": index, "event": event, "id": id as Any? ?? NSNull(),
                    "json": json.base64EncodedString(), "sse": sse.base64EncodedString(), "binary":binary.base64EncodedString(), "v2":reference?.base64EncodedString() as Any? ?? NSNull()])
    }
    static func emitValue<T:Encodable>(name:String,index:Int,event:String,id:String?,value:T,wire:RemoteTerminalWireEncoder) throws {
        let mode:UInt8 = event == "output" ? 2 : event == "alive" ? 1 : 0
        try emit(name:name,index:index,event:event,id:id,json:encoder().encode(value),binary:wire.encode(value,event:mode),reference:version == 3 ? referenceWire.encode(value,event:mode) : nil)
    }
    static func frame() throws -> RemoteTerminalFrame {
        let value: [String: Any] = ["sessionID": "codex:synthetic-session", "screen": "", "revision": "initial",
            "observedAt": "2026-10-25T00:00:00Z", "keys": ["Enter", "Escape"], "streamID": "synthetic-original-stream", "sequence": 0]
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RemoteTerminalFrame.self, from: JSONSerialization.data(withJSONObject: value))
    }
    static func emitScreens() throws {
        let wire = RemoteTerminalWireEncoder(jsonEncoder:encoder(),version:version), header = "$ synthetic terminal\n"
        for name in ["original-idle", "original-cursor", "original-append", "original-scroll", "original-styled"] {
            let stream = UUID().uuidString
            var previous: RemoteTerminalFrame?
            for index in 0..<64 {
                var value = try frame(); value.streamID = stream
                let lines = (0..<80).map { row in "line \(row + (name == "original-scroll" ? index : 0)): synthetic output / 한글 🧪 / stdout and stderr" }
                value.screen = header + lines.joined(separator: "\n")
                if name == "original-append" || name == "original-styled" {
                    value.screen += "\n" + (0...index).map { "working step \($0): pending → complete" }.joined(separator: "\n")
                }
                value.observedAt = Date(timeIntervalSince1970: 1_790_000_000 + Double(index * 2))
                value.sequence = 123456 + index
                value.cursor = TerminalCursor(offset: value.screen.utf16.count, padding: name == "original-cursor" ? index % 3 : 0)
                if name == "original-styled" {
                    value.appearance = TerminalAppearance(runs: [.init(offset: 0, length: 12, fg: index.isMultiple(of: 2) ? "#79b8ff" : "#98c379", bold: true)], foreground: "#f8f8f2", background: "#1e1e1e")
                }
                let same = previous?.screen == value.screen && previous?.appearance == value.appearance &&
                    previous?.cursor == value.cursor && previous?.nativeDisplay == value.nativeDisplay && previous?.outputReason == value.outputReason
                value.revision = same ? previous!.revision : UUID().uuidString
                if name == "original-idle", index > 0 {
                    try emitValue(name:name,index:index,event:"alive",id:nil,value:SyntheticAlive(streamID:value.streamID,revision:value.revision,sequence:value.sequence,observedAt:value.observedAt),wire:wire)
                } else {
                    let update = RemoteTerminalUpdate(value, previous: previous, delta: true, copy: true)
                    try emitValue(name:name,index:index,event:"screen",id:value.revision,value:update,wire:wire)
                }
                previous = value
            }
        }
    }
    static func emitPTY() throws {
        let wire = RemoteTerminalWireEncoder(jsonEncoder:encoder(),version:version)
        let initial: [String: Any] = ["ptyID": UUID().uuidString, "streamID": UUID().uuidString,
            "offset": 0, "data": "", "reset": false, "columns": 80, "rows": 24, "canInput": true]
        let template = try JSONDecoder().decode(ManagedPTYOutput.self, from: JSONSerialization.data(withJSONObject: initial))
        for name in ["pty-controls", "pty-small", "pty-log", "pty-random"] {
            var offset = 0, random: UInt64 = 0x1234face
            for index in 0..<64 {
                var value = template
                let raw: Data
                switch name {
                case "pty-controls": raw = Data()
                case "pty-small": raw = Data("\u{1b}[32mstep \(index)\u{1b}[0m\r\n".utf8)
                case "pty-log": raw = Data(String(repeating: "\u{1b}[36msynthetic terminal output 한글 🧪 \(index)\u{1b}[0m\r\n", count: 32).utf8)
                default:
                    raw = Data((0..<1024).map { _ in random = random &* 6364136223846793005 &+ 1442695040888963407; return UInt8(truncatingIfNeeded: random >> 32) })
                }
                offset += raw.count; value.offset = offset; value.data = raw.base64EncodedString()
                value.reset = index == 0; value.canInput = !index.isMultiple(of: 3)
                value.columns = 80 + index % 2; value.rows = 24 + index % 2
                if index == 63 { value.exitCode = 0 }
                try emitValue(name:name,index:index,event:"output",id:String(offset),value:value,wire:wire)
            }
        }
    }
    static func gzip() throws {
        while let line = readLine() {
            let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            let frames = request["frames"] as! [String], encoder = try RemoteGzipEncoder(level: 1)
            var bytes = 0, checksum = SHA256()
            for frame in frames {
                let part = try encoder.encode(Data(base64Encoded: frame)!)
                bytes += part.count; checksum.update(data: part)
            }
            let beforeFinish = bytes, final = try encoder.encode(Data(), final: true)
            bytes += final.count; checksum.update(data: final)
            try output(["name": request["name"] as! String, "frames": frames.count, "streamBytes": beforeFinish, "completeBytes": bytes,
                        "sha256": checksum.finalize().map { String(format: "%02x", $0) }.joined()])
        }
    }
    static func main() throws {
        if CommandLine.arguments.dropFirst().first == "gzip" { try gzip() }
        else if CommandLine.arguments.contains("benchmark") { try benchmark() }
        else { try selfChecks(); try emitScreens(); try emitPTY(); try emitAllocationEdges(); if version == 3 { try emitProfiles() } }
    }
}

extension TerminalWireFixture {
    struct AllocationScreen: Encodable {
        let screen:String
        let sessionID="synthetic-allocation",revision="ABCDEF12-1234-5678-ABCD-EF1234567890",streamID="BADC0FFE-1234-5678-ABCD-EF1234567890"
        let keys=["characters","enter"],observedAt=Date(timeIntervalSince1970:1_790_000_000),sequence=123456
    }
    struct EmptyObject: Encodable {
        enum Key:String,CodingKey { case unused }
        func encode(to encoder:any Encoder) throws { _=encoder.container(keyedBy:Key.self) }
    }
    struct EmptyStrings:Encodable { let values:[String] }
    struct EmptyObjects:Encodable { let values:[EmptyObject] }
    struct Presence:Encodable {
        enum Key:String,CodingKey { case screen,appearanceUnchanged,extra }
        func encode(to encoder:any Encoder) throws {
            var container=encoder.container(keyedBy:Key.self)
            try container.encodeNil(forKey:.screen);try container.encode(false,forKey:.appearanceUnchanged)
            try container.encode(["__proto__":"kept","null":"null"],forKey:.extra)
        }
    }
    struct FoundationFallback:Encodable { let value:Float }
    indirect enum Nested:Encodable {
        case leaf,child(Nested)
        func encode(to encoder:any Encoder) throws {
            var container=encoder.unkeyedContainer()
            switch self { case .leaf:try container.encode(0);case .child(let value):try container.encode(value) }
        }
    }
    struct Deep:Encodable { let extra:Nested }
    static func bound<T:Encodable>(_ name:String,_ value:T,event:String="screen") throws {
        let wire=RemoteTerminalWireEncoder(jsonEncoder:encoder(),version:version)
        try emitValue(name:name,index:0,event:event,id:nil,value:value,wire:wire)
    }
    static func emitAllocationEdges() throws {
        for count in [0,1,14,15,127,128,16383,16384,50000,200000,300000,333333,700000] {
            try bound("bound-ascii-\(count)",AllocationScreen(screen:String(repeating:"x",count:count)))
        }
        try bound("bound-controls",AllocationScreen(screen:String(repeating:"\u{0}\\\"\n",count:20000)))
        try bound("bound-unicode",AllocationScreen(screen:String(repeating:"한글🧪e\u{301}\r\n",count:4096)))
        let badUnits:[UInt16]=[0xd800,65,0xdc00,0x1b]
        let foreign=badUnits.withUnsafeBufferPointer { NSString(characters:$0.baseAddress!,length:$0.count) } as String
        try bound("bound-foreign-utf16",AllocationScreen(screen:foreign))
        for count in [0,1,14,15,127,128,16383,16384,50000] {
            try bound("bound-empty-strings-\(count)",EmptyStrings(values:Array(repeating:"",count:count)))
            try bound("bound-empty-objects-\(count)",EmptyObjects(values:Array(repeating:EmptyObject(),count:count)))
        }
        try bound("bound-presence",Presence())
        try bound("bound-float-fallback",FoundationFallback(value:0.1))
        var nested=Nested.leaf
        for depth in 0...70 {
            if [0,14,15,62,63,64,65,70].contains(depth) { try bound("bound-depth-\(depth)",Deep(extra:nested)) }
            nested = .child(nested)
        }
        var random:UInt64=0x1234face
        for count in [0,1,14,15,127,128,16383,16384,65536,500000] {
            let raw=Data((0..<count).map { _ in random=random &* 6364136223846793005 &+ 1442695040888963407;return UInt8(truncatingIfNeeded:random>>32) })
            var value=try JSONDecoder().decode(ManagedPTYOutput.self,from:Data(#"{"ptyID":"ABCDEF12-1234-5678-ABCD-EF1234567890","streamID":"BADC0FFE-1234-5678-ABCD-EF1234567890","offset":0,"data":"","reset":false,"columns":80,"rows":24,"canInput":false}"#.utf8))
            value.data=raw.base64EncodedString();value.offset=count
            try bound("bound-pty-\(count)",value,event:"output")
        }
    }
}

extension TerminalWireFixture {
    struct Profile<T:Encodable>:Encodable { let extra:T }
    static func decoded<T:Decodable>(_ type:T.Type,_ fields:[String:Any]) throws -> T {
        try JSONDecoder().decode(type,from:JSONSerialization.data(withJSONObject:fields))
    }
    static func emitProfiles() throws {
        // Every optional boolean has three distinct states: absent,false,true.
        for pattern in 0..<2187 {
            var digits=pattern
            func next()->Bool? { defer { digits /= 3 };return digits%3 == 0 ? nil : digits%3 == 2 }
            let run=TerminalAppearance.Run(offset:pattern,length:15,fg:pattern%2 == 0 ? "#aB12Cd":nil,bg:pattern%5 == 0 ? "#ABCDEF":nil,
                bold:next(),dim:next(),italic:next(),underline:next(),strike:next(),inverse:next(),hidden:next())
            try bound("bound-profile-run-\(pattern)",Profile(extra:run))
        }
        for style in [TerminalCursor.Style.block,.bar,.underline] {
            for flags in 0..<4 {
                for value in [0,14,15,127,128,16384,4_294_967_296,9_007_199_254_740_991] {
                    try bound("bound-profile-cursor-\(style)-\(flags)-\(value)",Profile(extra:TerminalCursor(offset:value,padding:value,visible:flags&1 != 0,style:style,blink:flags&2 != 0)))
                }
            }
        }
        for color in [nil,"#abcdef","#ABCDEF","#aBcDeF","invalid-color",""] as [String?] {
            for count in [0,1,127,128] {
                try bound("bound-profile-appearance-\(color ?? "absent")-\(count)",Profile(extra:TerminalAppearance(runs:Array(repeating:.init(offset:0,length:1,fg:color,bold:false,hidden:true),count:count),foreground:color,background:color)))
            }
        }
        for count in [7999,8000,8001] {
            try bound("bound-profile-run-count-\(count)",Profile(extra:TerminalAppearance(runs:Array(repeating:.init(offset:0,length:1),count:count))))
        }
        try bound("bound-profile-logical-node-limit",Profile(extra:TerminalAppearance(runs:Array(repeating:.init(offset:0,length:1,fg:"#abcdef",bg:"#ABCDEF",bold:true,dim:false,italic:true,underline:false,strike:true,inverse:false,hidden:true),count:5000))))
        for value in [-1,Int.max,Int.min] {
            try bound("bound-profile-fallback-cursor-\(value)",Profile(extra:TerminalCursor(offset:value,padding:value)))
            try bound("bound-profile-fallback-run-\(value)",Profile(extra:TerminalAppearance.Run(offset:value,length:value)))
        }
        for text in ["","한글 🧪e\u{301}\r\n","\u{0}\\\"\n",String(repeating:"🧪",count:8192)] {
            try bound("bound-profile-patch-\(text.utf8.count)",Profile(extra:decoded(RemoteTerminalScreenPatch.self,["baseRevision":"aB12Cd","baseLength":9_007_199_254_740_991,"prefix":0,"suffix":128,"text":text,"length":16384])))
            try bound("bound-profile-copy-\(text.utf8.count)",Profile(extra:decoded(RemoteTerminalScreenCopy.self,["baseRevision":"ABCDEF12-1234-5678-ABCD-EF1234567890","baseLength":9_007_199_254_740_991,"start":127,"count":128,"head":text,"tail":text,"length":16384])))
        }
        // Dense attribute changes are measured as a normal gzip stream too.
        let wire=RemoteTerminalWireEncoder(jsonEncoder:encoder(),version:version)
        for index in 0..<64 {
            let runs=(0..<128).map { row in TerminalAppearance.Run(offset:row*8,length:8,fg:(row+index)%2 == 0 ? "#79b8ff":"#98c379",bold:row%3 == 0,dim:row%5 == 0,underline:row%7 == 0) }
            try emitValue(name:"original-dense",index:index,event:"screen",id:nil,value:Profile(extra:TerminalAppearance(runs:runs,foreground:"#f8f8f2",background:"#1e1e1e")),wire:wire)
        }
    }
    static func benchmark() throws {
        func measure<T:Encodable>(_ name:String,_ value:T,count:Int) throws {
            var times=[2:[Double](),3:[Double]()],checksum=0
            for round in 0..<9 {
                for version in round%2 == 0 ? [2,3]:[3,2] {
                    let wire=RemoteTerminalWireEncoder(jsonEncoder:encoder(),version:version)
                    for _ in 0..<20 { checksum += try wire.encode(value,event:0).count }
                    let start=DispatchTime.now().uptimeNanoseconds
                    for _ in 0..<count { checksum += try wire.encode(value,event:0).count }
                    if round > 1 { times[version]!.append(Double(DispatchTime.now().uptimeNanoseconds-start)/Double(count)) }
                }
            }
            let v2=times[2]!.sorted()[3],v3=times[3]!.sorted()[3]
            try output(["case":name,"v2Nanoseconds":v2,"v3Nanoseconds":v3,"ratio":v3/v2,"checksum":checksum,"samples":7])
        }
        try measure("cursor",Profile(extra:TerminalCursor(offset:127,padding:2)),count:5000)
        try measure("styled",Profile(extra:TerminalAppearance(runs:(0..<64).map { .init(offset:$0*8,length:8,fg:"#79b8ff",bold:true,dim:false,underline:true) },foreground:"#f8f8f2",background:"#1e1e1e")),count:300)
        try measure("patch",Profile(extra:decoded(RemoteTerminalScreenPatch.self,["baseRevision":"ABCDEF12-1234-5678-ABCD-EF1234567890","baseLength":6000,"prefix":5950,"suffix":0,"text":"synthetic appended output 한글 🧪","length":6010])),count:3000)
        struct PTYControls:Encodable { let ptyID="ABCDEF12-1234-5678-ABCD-EF1234567890",streamID="BADC0FFE-1234-5678-ABCD-EF1234567890",offset=4_294_967_296,columns=80,rows=24,reset=false,canInput=true,data="" }
        try measure("pty-controls",PTYControls(),count:3000)
    }
    static func selfChecks() throws {
        guard RemoteTerminalWire.version == 3,RemoteTerminalWire.fields.count == 24,
              RemoteTerminalWire.heartbeat == Data([65,65,2,4,0]) else {
            throw NSError(domain:"TerminalWireFixture",code:1)
        }
        let value=RemoteTerminalWireEncoder(jsonEncoder:encoder(),version:version)
        var oversizedRejected=false
        do { _ = try value.encode(AllocationScreen(screen:String(repeating:"x",count:2_000_001)),event:0) }
        catch let error as RemoteHTTPError { oversizedRejected=error.status == 502 }
        guard oversizedRejected else { throw NSError(domain:"TerminalWireFixture",code:2) }
        try output(["validation":true,"version":version,"fields":RemoteTerminalWire.fields,"heartbeat":RemoteTerminalWire.heartbeat(version:version).base64EncodedString(),"oversizedRejected":true,"exactProductEncoderSource":true])
    }
}
