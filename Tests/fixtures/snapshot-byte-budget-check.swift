import Foundation
import CoreFoundation
import Darwin

@main struct SnapshotBudgetOracle {
    enum Failure: Error { case mismatch(String) }
    static var cases=0,foreign=0,snapshots=0,jsonCases=0,scalars=0,unitValues=0
    static var digest:UInt64=1469598103934665603
    static func require(_ condition:Bool,_ message:String)throws { if !condition {throw Failure.mismatch(message)} }
    static func mix(_ value:UInt64){digest=(digest^value)&*1099511628211}
    static func stored(_ units:[UInt16])->[String]{
        let native=String(decoding:units,as:UTF16.self)
        guard !units.isEmpty else{return [native,NSString(string:"") as String]}
        let cocoa=units.withUnsafeBufferPointer {NSString(characters:$0.baseAddress!,length:$0.count) as String}
        let cf=units.withUnsafeBufferPointer {unsafeBitCast(CFStringCreateWithCharacters(kCFAllocatorDefault,$0.baseAddress!,$0.count)!,to:NSString.self) as String}
        return [native,cocoa,cf]
    }
    static func raw(_ text:String)->[UInt16]{
        let text=text as NSString;var units=[UInt16](repeating:0,count:text.length)
        if !units.isEmpty {units.withUnsafeMutableBufferPointer{text.getCharacters($0.baseAddress!,range:NSRange(location:0,length:$0.count))}}
        return units
    }
    static func json<T:Encodable>(_ value:T)throws->Data{let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];return try encoder.encode(value)}
    static func check(_ text:String,edges:Bool=false,encode:Bool=false)throws {
        let native=text.isContiguousUTF8,units=raw(text),bytes=Array(text.utf8),count=text.utf16.count
        if !native {foreign += 1}
        try require(count<=bytes.count && bytes.count<=count*3,"UTF16 bounds do not cover the actual repaired UTF8")
        let offsets=edges ? [Int.min,-1,0,1,max(0,count/2),max(0,count-1),count,count+1,Int.max]:[0,count/2,count]
        for offset in offsets {
            let paddings=edges ? [Int.min,-1,0,500,501,Int.max]:[0]
            for padding in paddings {
                let a=ReferenceTerminalTextSnapshot(screen:text,cursor:.init(offset:offset,padding:padding,visible:false,style:.underline,blink:false)).validated()
                let b=CandidateTerminalTextSnapshot(screen:text,cursor:.init(offset:offset,padding:padding,visible:false,style:.underline,blink:false)).validated()
                try require((a==nil)==(b==nil),"Snapshot acceptance changed: bytes \(bytes.count), units \(count), offset \(offset), padding \(padding)")
                if let a,let b {
                    try require(a.screen.utf8.elementsEqual(b.screen.utf8) && raw(a.screen)==raw(b.screen),"Snapshot screen bytes or malformed raw units changed")
                    try require(a.cursor.offset==b.cursor.offset && a.cursor.padding==b.cursor.padding && a.cursor.visible==b.cursor.visible && a.cursor.style.rawValue==b.cursor.style.rawValue && a.cursor.blink==b.cursor.blink,"Cursor fields changed")
                    try require(a.screen.isContiguousUTF8==native && b.screen.isContiguousUTF8==native,"Snapshot storage changed")
                }
                snapshots += 1;mix(a==nil ? 0:UInt64(bytes.count+1))
            }
        }
        if encode {
            let a=ReferenceTerminalTextSnapshot(screen:text,cursor:.init(offset:count)).validated()
            let b=CandidateTerminalTextSnapshot(screen:text,cursor:.init(offset:count)).validated()
            try require(try json(a)==json(b),"Snapshot JSON changed");jsonCases += 1
        }
        try require(text.isContiguousUTF8==native && text.utf8.elementsEqual(bytes) && raw(text)==units,"Caller bytes or storage mutated")
        cases += 1
    }
    static func main()throws {
        var batch=""
        for value in UInt32(0)...0x10ffff {
            guard let scalar=UnicodeScalar(value) else{continue};batch.unicodeScalars.append(scalar);scalars += 1
            if scalars%256==0 {for text in stored(Array(("A"+batch+"z").utf16)){try check(text)};batch=""}
        }
        if !batch.isEmpty {for text in stored(Array(batch.utf16)){try check(text)}}
        var units:[UInt16]=[]
        for value in UInt32(0)...65535 {
            let unit=UInt16(value);units += [97,unit,0xd800,unit,0xdc00,122];unitValues += 1
            if unitValues%64==0 {for text in stored(units){try check(text)};units=[]}
        }
        for seed in ["x","¢","한","🧪","e\u{301}","👩🏽‍💻","\r\n","\0"] {
            for target in [66664,66665,66666,66667,66668,199997,199998,199999,200000,200001,200002,200003] {
                let size=seed.utf8.count,repeats=target/size
                let text=String(repeating:seed,count:repeats)+String(repeating:"x",count:target%size)
                try require(text.utf8.count==target,"Boundary fixture has the wrong byte count")
                for source in stored(Array(text.utf16)){try check(source,edges:true,encode:true)}
            }
        }
        for unit:UInt16 in [0,0x7f,0x80,0x7ff,0x800,0xd7ff,0xd800,0xdbff,0xdc00,0xdfff,0xe000,0xffff] {
            for count in [66665,66666,66667,199999,200000,200001] {
                for source in stored([UInt16](repeating:unit,count:count)) {try check(source,edges:true,encode:true)}
            }
        }
        for source in stored([UInt16](repeating:0xd800,count:1_000_001)){try check(source,encode:true)}
        for value in ["", "a", "🧪", "\u{301}", "\r\n", "a\0b", "\u{FEFF}"] {
            for source in stored(Array(value.utf16)){try check(source,edges:true,encode:true)}
        }
        try require(scalars==1112064 && unitValues==65536 && foreign>8000,"Incomplete storage/scalar coverage")
        print("SNAPSHOT_BYTE_BUDGET scalars \(scalars); utf16Units \(unitValues); cases \(cases); foreign \(foreign); snapshots \(snapshots); json \(jsonCases); checksum \(digest)")
    }
}
