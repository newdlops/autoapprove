import Foundation
import CoreFoundation
import AutoApproveCore

struct WordSuffixEdges {
    static func foreign(_ units:[UInt16])->String {
        units.withUnsafeBufferPointer {unsafeBitCast(CFStringCreateWithCharacters(kCFAllocatorDefault,$0.baseAddress,$0.count)!,to:NSString.self) as String}
    }
    static func rawUnits(_ text:String)->[UInt16] {
        let source=text as NSString
        guard source.length>0 else{return []}
        var units=[UInt16](repeating:0,count:source.length)
        units.withUnsafeMutableBufferPointer {source.getCharacters($0.baseAddress!,range:NSRange(location:0,length:$0.count))}
        return units
    }
    static func run() throws {
        var cases=0,foreignCases=0,scalars=0,batches=0,checksum:UInt64=1469598103934665603
        func same(_ left:[String],_ right:[String])->Bool {left.count==right.count && zip(left,right).allSatisfy{$0.utf8.elementsEqual($1.utf8)}}
        func mix(_ rows:[String]) {for row in rows {for byte in row.utf8 {checksum=(checksum ^ UInt64(byte)) &* 1099511628211};checksum=(checksum ^ 255) &* 1099511628211}}
        func check(_ text:String,count:Int=300) throws {
            let before=Array(text.utf8),units=rawUnits(text),native=text.isContiguousUTF8
            let a=ReferenceDetectionLines(text),b=CandidateDetectionLines(text)
            let left=a.normalizedSuffix(count),right=b.normalizedSuffix(count)
            guard same(left.rows,right.rows),left.byteStarts==right.byteStarts,left.normalizedLineOffset==right.normalizedLineOffset,
                  same(a.trimmedSuffix(count),b.trimmedSuffix(count)),a.sourceByteCount==b.sourceByteCount,a.sourceByteCount==before.count else {
                throw AppError.message("WORD_SUFFIX exact rows/metadata changed at case \(cases), count \(count)")
            }
            for index in [0,left.rows.count/2,left.rows.count] {
                guard a.hasOpenCodeFence(beforeSuffixRow:index,in:left)==b.hasOpenCodeFence(beforeSuffixRow:index,in:right) else {throw AppError.message("WORD_SUFFIX prior fence changed")}
            }
            guard same(a.raw,b.raw),same(a.trimmed,b.trimmed),text.utf8.elementsEqual(before),rawUnits(text)==units,text.isContiguousUTF8==native else {throw AppError.message("WORD_SUFFIX source/raw storage changed")}
            mix(right.rows);cases+=1;if !native {foreignCases+=1}
        }
        func stores(_ text:String,count:Int=300) throws {
            try autoreleasepool {try check(text,count:count);try check(NSAppleEventDescriptor(string:text).stringValue!,count:count);try check(foreign(Array(text.utf16)),count:count)}
        }
        // Delimiters, embedded zeroes and high bytes appear at every word lane.
        for byte in UInt8(0)...255 {for lane in 0..<8 {
            var bytes=Array(repeating:UInt8(120),count:48);bytes[16+lane]=byte
            for ending:[UInt8] in [[],[10],[13],[13,10],[10,13],[13,13,10]] {
                let text="```\r\n"+String(decoding:bytes+ending+[0,1,10,0,1,13,10],as:UTF8.self)+"한글 tail\r\n \t\n"
                try stores(text,count:[1,18,299,300,301,512][ending.count % 6])
            }
        }}
        for length in [0,1,7,8,9,15,16,17,31,32,33,63,64,65,127,128,129,4095,4096,4097] {
            for tail in ["","\n","\r","\r\n","\n\r\n","\r\r\n"] {
                let row=String(repeating:"x",count:length)+"한e\u{301}👩🏽‍💻"
                for rows in [0,1,17,18,299,300,301] {
                    let text=String(repeating:row+tail,count:rows)+"```\n \t\r\n"
                    try stores(text,count:300)
                }
            }
        }
        // Every scalar enters a long row through its complete UTF8 sequence.
        var batch=""
        for value in UInt32(0)...0x10ffff {
            guard let scalar=Unicode.Scalar(value) else{continue}
            let value=String(scalar)
            batch+="ASCIIrow1234"+value+"\u{301}\r\n\u{327}"+value+"\u{300} padding1234\n"
            scalars+=1
            if scalars.isMultiple(of:64) {try autoreleasepool {try check(batch)};batch="";batches+=1}
        }
        if !batch.isEmpty {try check(batch);batches+=1}
        guard scalars==1112064,batches==17376 else{throw AppError.message("WORD_SUFFIX missing scalar coverage")}
        for seed:[UInt16] in [[0xd800],[0xdc00],[0xd800,32,0xdc00],[0xd800,0xd800,0xdc00],[0xdc00,0xd800],[0xd800,0xdc00]] {
            for count in [7,8,9,15,16,17,4095,4096,4097] {
                let units=Array(repeating:UInt16(120),count:count)+seed+[13,10,0,1,10,0xac00]
                try autoreleasepool {try check(String(decoding:units,as:UTF16.self));try check(foreign(units))}
            }
        }
        for length in [4*1024*1024-1,4*1024*1024,4*1024*1024+1] {try stores(String(repeating:"x",count:length)+"한\r\n› 1. Yes\r\n2. No\nEsc to cancel\n")}
        print("WORD_SUFFIX scalars \(scalars); batches \(batches); cases \(cases); foreign \(foreignCases); checksum \(checksum)")
    }
}

@main struct NativeRowBoundaryCheck { static func main() throws { try WordSuffixEdges.run() } }
