import Foundation
import CoreFoundation
import Darwin

@main struct TerminalUTF16Oracle {
    enum Failure: Error { case mismatch(String) }
    static var cases=0,cursors=0,appearances=0,snapshots=0,foreign=0
    static var digest:UInt64=1469598103934665603
    static func require(_ condition:Bool,_ message:String)throws {if !condition {throw Failure.mismatch(message)}}
    static func mix(_ value:UInt64){digest=(digest^value)&*1099511628211}
    static func rawUnits(_ text:String)->[UInt16]{
        let source=text as NSString
        guard source.length>0 else{return []}
        var result=[UInt16](repeating:0,count:source.length)
        result.withUnsafeMutableBufferPointer {source.getCharacters($0.baseAddress!,range:NSRange(location:0,length:$0.count))}
        return result
    }
    static func stored(_ units:[UInt16])->[String]{
        let native=String(decoding:units,as:UTF16.self)
        guard !units.isEmpty else{return [native,NSString(string:"") as String]}
        let cocoa=units.withUnsafeBufferPointer {NSString(characters:$0.baseAddress!,length:$0.count) as String}
        let cf=units.withUnsafeBufferPointer {unsafeBitCast(CFStringCreateWithCharacters(kCFAllocatorDefault,$0.baseAddress!,$0.count)!,to:NSString.self) as String}
        return [native,cocoa,cf]
    }
    static func equal(_ a:ReferenceTerminalCursor?,_ b:CandidateTerminalCursor?)->Bool{
        guard let a else{return b==nil};guard let b else{return false}
        return a.offset==b.offset && a.padding==b.padding && a.visible==b.visible && a.style.rawValue==b.style.rawValue && a.blink==b.blink
    }
    static func equal(_ a:ReferenceTerminalTextSnapshot?,_ b:CandidateTerminalTextSnapshot?)->Bool{
        guard let a else{return b==nil};guard let b else{return false}
        return a.screen.utf8.elementsEqual(b.screen.utf8) && rawUnits(a.screen)==rawUnits(b.screen) && equal(a.cursor,b.cursor)
    }
    static func json<T:Encodable>(_ value:T)throws->Data{let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];return try encoder.encode(value)}
    static func check(_ text:String,order:Bool=false)throws {
        let before=Array(text.utf8),raw=rawUnits(text),native=text.isContiguousUTF8,count=text.utf16.count
        if !native {foreign += 1}
        if order {_ = text.utf16.count;_ = Array(text.utf8)}
        let offsets=Set([-1,0,1,count/2,count-1,count,count+1]).sorted()
        for offset in offsets {
            let a=ReferenceTerminalCursor(offset:offset,padding:3,visible:false,style:.bar,blink:false).validated(for:text)
            let b=CandidateTerminalCursor(offset:offset,padding:3,visible:false,style:.bar,blink:false).validated(for:text)
            try require(equal(a,b),"Cursor boundary changed \(raw) offset \(offset)");cursors += 1;mix(a==nil ? 0:1)
            let left=ReferenceTerminalAppearance(runs:[.init(offset:offset,length:1,fg:"#aBcD09",bold:true)],foreground:"#FFFFFF").validated(for:text)
            let right=CandidateTerminalAppearance(runs:[.init(offset:offset,length:1,fg:"#aBcD09",bold:true)],foreground:"#FFFFFF").validated(for:text)
            try require((left==nil)==(right==nil),"Appearance boundary changed \(raw) offset \(offset)");appearances += 1;mix(left==nil ? 0:2)
            let range=NSRange(location:offset,length:1),insertion=max(0,offset)
            let sa=ReferenceTerminalTextSnapshot.fromAccessibility(value:text,insertion:insertion,visible:range)
            let sb=CandidateTerminalTextSnapshot.fromAccessibility(value:text,insertion:insertion,visible:range)
            try require(equal(sa,sb),"Visible boundary changed \(raw) offset \(offset)");snapshots += 1;mix(sa==nil ? 0:4)
        }
        let a=ReferenceTerminalTextSnapshot(screen:text,cursor:.init(offset:count)).validated()
        let b=CandidateTerminalTextSnapshot(screen:text,cursor:.init(offset:count)).validated()
        try require(equal(a,b),"Snapshot validation changed");snapshots += 1;mix(a==nil ? 0:8)
        try require(text.utf8.elementsEqual(before) && rawUnits(text)==raw && text.isContiguousUTF8==native,"Changed source bytes/storage")
        cases += 1
    }
    static func main()throws {
        var scalars=0
        for value in UInt32(0)...0x10ffff {
            guard let scalar=UnicodeScalar(value) else{continue}
            let text="A"+String(scalar)+"z"
            for source in stored(Array(text.utf16)).prefix(2) {try check(source)}
            scalars += 1
            if scalars%262144==0 {print("UTF16_SCALARS \(scalars)");fflush(stdout)}
        }
        for value in UInt32(0)...65535 {
            let unit=UInt16(value)
            for units:[UInt16] in [[unit],[97,unit,122],[0xd800,unit,0xdc00],[unit,0xd800,0xdc00]] {
                for source in stored(units) {try check(source,order:value%2==0)}
            }
        }
        for units:[UInt16] in [[],[0xd800,0xd800],[0xdc00,0xdc00],[0xdc00,0xd800],[0xd800,13,10,0xdc00],[0xfeff,0,27,0xd800],[0xd800,0xdc00,0xdc00]] {
            for source in stored(units) {try check(source);try check(source,order:true)}
        }
        let large=[String(repeating:"x",count:199999),String(repeating:"x",count:200000),String(repeating:"x",count:200001),String(repeating:"e\u{301}🧪",count:4097)]
        for text in large {
            for source in [text,NSAppleEventDescriptor(string:text+"›").stringValue!] {
                let count=source.utf16.count
                for offset in [Int.min,-1,0,1,count-1,count,count+1,Int.max] {
                    for padding in [Int.min,-1,0,500,501,Int.max] {
                        let a=ReferenceTerminalCursor(offset:offset,padding:padding).validated(for:source),b=CandidateTerminalCursor(offset:offset,padding:padding).validated(for:source)
                        try require(equal(a,b),"Extreme cursor changed");cursors += 1
                    }
                }
                for location in [Int.min,-1,0,1,max(0,count-1),count,NSNotFound] {
                    for length in [Int.min,-1,0,1,count,Int.max] {
                        let range=NSRange(location:location,length:length)
                        for insertion in [-1,0,count,Int.max] {
                            try require(equal(ReferenceTerminalTextSnapshot.fromAccessibility(value:source,insertion:insertion,visible:range),CandidateTerminalTextSnapshot.fromAccessibility(value:source,insertion:insertion,visible:range)),"Extreme visible range changed");snapshots += 1
                        }
                    }
                }
                try require(try json(ReferenceTerminalTextSnapshot(screen:source,cursor:.init(offset:count)).validated())==json(CandidateTerminalTextSnapshot(screen:source,cursor:.init(offset:count)).validated()),"Snapshot byte budget/JSON changed")
            }
        }
        let display=String(repeating:"x",count:9000)+"🧪›"
        for source in [display,NSAppleEventDescriptor(string:display).stringValue!] {
            for count in [0,1,2,63,64,65,7999,8000,8001] {
                let a=ReferenceTerminalAppearance(runs:(0..<count).map{.init(offset:$0,length:1,fg:"#aBcD09",bg:"#101010",bold:true,dim:false,italic:true,underline:false,strike:true,inverse:false,hidden:true)},foreground:"#FFFFFF",background:"#000000").validated(for:source)
                let b=CandidateTerminalAppearance(runs:(0..<count).map{.init(offset:$0,length:1,fg:"#aBcD09",bg:"#101010",bold:true,dim:false,italic:true,underline:false,strike:true,inverse:false,hidden:true)},foreground:"#FFFFFF",background:"#000000").validated(for:source)
                try require(try json(a)==json(b),"Dense/threshold appearance fields changed");appearances += 1;mix(a==nil ? 0:UInt64(count+1))
            }
            for color:String? in [nil,"#ffffff","#ABCDEF","#000000","#1234567","red","#gggggg","#１２３４５６","url(https://example.invalid)"] {
                for offset in [Int.min,-1,0,8999,9000,9001,9002,Int.max] {
                    for length in [Int.min,-1,0,1,2,9000,Int.max] {
                        let a=ReferenceTerminalAppearance(runs:[.init(offset:offset,length:length,fg:color)],background:color).validated(for:source)
                        let b=CandidateTerminalAppearance(runs:[.init(offset:offset,length:length,fg:color)],background:color).validated(for:source)
                        try require(try json(a)==json(b),"Appearance range/color/JSON changed");appearances += 1
                    }
                }
            }
        }
        try require(scalars==1112064 && foreign>1000000,"Incomplete Unicode/storage coverage")
        print("TERMINAL_UTF16 scalars \(scalars); utf16Units 65536; cases \(cases); foreign \(foreign); cursors \(cursors); appearances \(appearances); snapshots \(snapshots); checksum \(digest)")
        try TerminalUTF16RunEdges.run()
    }
}

/// Exercises the ordered boundary walk, its dense fallback, and invalid later runs.
struct TerminalUTF16RunEdges {
    static func run() throws {
        let texts=[String(repeating:"x",count:20000),String(repeating:"A🧪e\u{301}한\r\n",count:5000),
                   String(repeating:"🧪",count:9000),String(repeating:"e\u{301}",count:10000)]
        var cases=0,accepted=0,foreign=0
        var digest:UInt64=1469598103934665603
        for text in texts {
            for source in TerminalUTF16Oracle.stored(Array(text.utf16)) {
                let original=Array(source.utf8),raw=TerminalUTF16Oracle.rawUnits(source),native=source.isContiguousUTF8
                if !native {foreign += 1}
                let units=Array(source.utf16),size=units.count
                let boundaries=(0...size).filter{$0==size || !(0xdc00...0xdfff).contains(units[$0])}
                for count in [0,1,2,7,8,63,64,65,127,8000,8001] {
                    let ranges=(0..<count).map {index -> (offset:Int,length:Int) in
                        let slot=index*(boundaries.count-1)/max(1,count)
                        return(boundaries[slot],boundaries[slot+1]-boundaries[slot])
                    }
                    for variant in 0..<10 {
                        var changed=ranges
                        if !changed.isEmpty {
                            let last=changed.count-1
                            switch variant {
                            case 1: if last>0 {changed[last].offset=changed[last-1].offset} else {changed[last].length=0}
                            case 2: changed[last].offset = -1
                            case 3: changed[last].length=0
                            case 4: changed[last].length=Int.max
                            case 5: changed[last].offset=size
                            case 8: changed[last].offset=units.firstIndex(where:{(0xdc00...0xdfff).contains($0)}) ?? Int.max
                            default: break
                            }
                        }
                        let a=ReferenceTerminalAppearance(runs:changed.enumerated().map {index,range in
                            .init(offset:range.offset,length:range.length,fg:variant==6&&index==changed.count-1 ? "red":"#22aAcC",
                                  bg:variant==7&&index==changed.count-1 ? "#gggggg":"#101010",bold:index%2==0,dim:false,
                                  italic:true,underline:false,strike:true,inverse:false,hidden:true)
                        },foreground:variant==9 ? "#１２３４５６":"#ffffff",background:"#000000").validated(for:source)
                        let b=CandidateTerminalAppearance(runs:changed.enumerated().map {index,range in
                            .init(offset:range.offset,length:range.length,fg:variant==6&&index==changed.count-1 ? "red":"#22aAcC",
                                  bg:variant==7&&index==changed.count-1 ? "#gggggg":"#101010",bold:index%2==0,dim:false,
                                  italic:true,underline:false,strike:true,inverse:false,hidden:true)
                        },foreground:variant==9 ? "#１２３４５６":"#ffffff",background:"#000000").validated(for:source)
                        let left=try TerminalUTF16Oracle.json(a),right=try TerminalUTF16Oracle.json(b)
                        try TerminalUTF16Oracle.require(left==right,"Ordered appearance runs changed count \(count), variant \(variant)")
                        if a != nil {accepted += 1}
                        cases += 1;digest=(digest^UInt64(left.count))&*1099511628211
                    }
                }
                try TerminalUTF16Oracle.require(source.utf8.elementsEqual(original) && TerminalUTF16Oracle.rawUnits(source)==raw && source.isContiguousUTF8==native,"Ordered runs changed source storage")
            }
        }
        try TerminalUTF16Oracle.require(cases==1320 && accepted>50 && foreign>0,"Incomplete ordered-run coverage")
        print("TERMINAL_UTF16_RUNS cases \(cases); accepted \(accepted); checksum \(digest)")
    }
}
