import Foundation
import CoreFoundation
import Darwin
#if ACTUAL_CORE
import AutoApproveCore
#endif

@main struct NativePatchOracle {
    enum Failure: Error { case mismatch(String) }
    static var cases=0,foreign=0,accepted=0,jsonCases=0,scalars=0,units=0
    static var digest:UInt64=1469598103934665603
    static func require(_ condition:Bool,_ message:String)throws{if !condition{throw Failure.mismatch(message)}}
    static func mix(_ value:UInt64){digest=(digest^value)&*1099511628211}
    static func json<T:Encodable>(_ value:T)throws->Data{let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];return try encoder.encode(value)}
    static func raw(_ text:String)->[UInt16]{let s=text as NSString;var result=[UInt16](repeating:0,count:s.length);if !result.isEmpty{result.withUnsafeMutableBufferPointer{s.getCharacters($0.baseAddress!,range:NSRange(location:0,length:$0.count))}};return result}
    static func stored(_ units:[UInt16],_ kind:Int)->String{
        if kind==0{return String(decoding:units,as:UTF16.self)}
        if units.isEmpty{return NSString(string:"") as String}
        if kind==1{return units.withUnsafeBufferPointer{NSString(characters:$0.baseAddress!,length:$0.count) as String}}
        return units.withUnsafeBufferPointer{unsafeBitCast(CFStringCreateWithCharacters(kCFAllocatorDefault,$0.baseAddress!,$0.count)!,to:NSString.self) as String}
    }
    static func check(_ before:String,_ after:String,_ revision:String="base",encode:Bool=false)throws{
        let native=[before.isContiguousUTF8,after.isContiguousUTF8],original=[raw(before),raw(after)],bytes=[Array(before.utf8),Array(after.utf8)]
        if native.contains(false){foreign += 1}
        let a=ReferencePatch.make(previous:before,current:after,baseRevision:revision),b=CandidatePatch.make(previous:before,current:after,baseRevision:revision)
        try require((a==nil)==(b==nil),"Patch nil threshold changed")
        if let a,let b {
            try require(a.baseRevision.utf8.elementsEqual(b.baseRevision.utf8) && a.baseLength==b.baseLength && a.prefix==b.prefix && a.suffix==b.suffix && a.length==b.length && a.text.utf8.elementsEqual(b.text.utf8) && raw(a.text)==raw(b.text),"Patch fields or exact replacement bytes changed")
            let source=before as NSString
            let restoredA=source.substring(to:a.prefix)+a.text+source.substring(from:source.length-a.suffix)
            let restoredB=source.substring(to:b.prefix)+b.text+source.substring(from:source.length-b.suffix)
            try require(restoredA.utf8.elementsEqual(restoredB.utf8),"Browser reconstruction changed")
            if native.allSatisfy({$0}){try require(restoredB.utf8.elementsEqual(after.utf8),"Native patch failed exact reconstruction")}
            accepted += 1;mix(UInt64(a.prefix));mix(UInt64(a.suffix));mix(UInt64(a.length));for byte in a.text.utf8{mix(UInt64(byte))}
        }else{mix(0)}
        if encode{try require(try json(a)==json(b),"Patch JSON changed");jsonCases += 1}
#if ACTUAL_CORE
        let actual=RemoteTerminalScreenPatch.make(previous:before,current:after,baseRevision:revision)
        try require((actual==nil)==(b==nil),"Actual Core omitted or invented a patch")
        if let actual,let b{try require(actual.baseLength==b.baseLength && actual.prefix==b.prefix && actual.suffix==b.suffix && actual.length==b.length && actual.baseRevision.utf8.elementsEqual(b.baseRevision.utf8) && actual.text.utf8.elementsEqual(b.text.utf8) && raw(actual.text)==raw(b.text),"Actual Core fields differ from bound source")}
        if encode{try require(try json(actual)==json(b),"Actual Core JSON changed")}
#endif
        try require(before.isContiguousUTF8==native[0] && after.isContiguousUTF8==native[1] && raw(before)==original[0] && raw(after)==original[1] && before.utf8.elementsEqual(bytes[0]) && after.utf8.elementsEqual(bytes[1]),"Caller bytes or storage changed")
        cases += 1
    }
    static func matrix(_ before:[UInt16],_ after:[UInt16],_ revision:String="base",cross:Bool=false,encode:Bool=false)throws{
        for kind in 0..<3{try check(stored(before,kind),stored(after,kind),revision,encode:encode)}
        if cross{try check(stored(before,0),stored(after,1),revision,encode:encode);try check(stored(before,2),stored(after,0),revision,encode:encode)}
    }
    static func main()throws{
        let head=String(repeating:"P",count:270),tail=String(repeating:"T",count:270)
        var batch=""
        for value in UInt32(0)...0x10ffff{
            guard let scalar=UnicodeScalar(value) else{continue};scalars += 1
            let text=String(repeating:"a",count:Int(value%8))+String(scalar)+"tail12345"
            try require(CandidatePatch.oracleUnits(text)==text.utf16.count,"Word UTF16 count changed for scalar \(value)")
            batch.unicodeScalars.append(scalar)
            if scalars%128==0{
                try matrix(Array((head+batch+"🧪a"+tail).utf16),Array((head+batch+"🙃b"+tail).utf16),cross:scalars%8192==0,encode:scalars%8192==0)
                try matrix(Array((head+batch+tail).utf16),Array((head+"插入"+batch+tail).utf16))
                batch=""
            }
        }
        try require(batch.isEmpty,"Unexpected incomplete scalar block")
        for value in UInt32(0)...65535{
            let unit=UInt16(value);units += 1
            let prefix=Array(head.utf16),suffix=Array(tail.utf16)
            try matrix(prefix+[0xd800,unit,0xdc00]+suffix,prefix+[0xd800,unit,0xdc01]+suffix,cross:value%1024==0,encode:value%1024==0)
        }
        for size in [0,1,7,8,9,15,16,17,255,256,257,259,260,261,511,512,513,1023,1024,1025,159999,160000,160001]{
            for seed in ["x","한","🧪","e\u{301}","👩🏽‍💻"]{
                let body=String(repeating:seed,count:size/max(1,seed.utf8.count))+"end"
                for (a,b) in [(body,body),(body,body+"追加🙂"),(body+"tail",body),("head"+body,"HEAD"+body),(body,"全交換"),("",body)]{
                    for revision in ["", "base", "🧪e\u{301}",String(repeating:"r",count:512)]{
                        try matrix(Array(a.utf16),Array(b.utf16),revision,cross:true,encode:true)
                    }
                }
            }
        }
        for alignment in 0..<16{
            let p=String(repeating:"a",count:270+alignment)
            for before in ["🙂","🙃","\u{1F200}","é","e\u{301}","\r\n","\0","", "ab"]{
                for after in ["🧪","🙃","\u{1F600}","e\u{301}","é","\n\r","\0","", "ba"]{
                    try matrix(Array((p+before+tail).utf16),Array((p+after+tail).utf16),cross:true,encode:true)
                }
            }
        }
        try require(scalars==1112064 && units==65536 && foreign>100000,"Incomplete Unicode/storage coverage")
        print("NATIVE_PATCH scalars \(scalars); utf16Units \(units); cases \(cases); foreign \(foreign); accepted \(accepted); json \(jsonCases); checksum \(digest)")
    }
}
