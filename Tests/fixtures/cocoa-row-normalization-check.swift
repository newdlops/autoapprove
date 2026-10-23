import Foundation
import CoreFoundation
import AutoApproveCore

@main struct CocoaRowBridgeCheck {
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw AppError.message(message) }
    }
    static func foreign(_ units: [UInt16]) -> String {
        units.withUnsafeBufferPointer {
            unsafeBitCast(CFStringCreateWithCharacters(kCFAllocatorDefault, $0.baseAddress, $0.count)!, to: NSString.self) as String
        }
    }
    static func main() throws {
        var probes=0,foreignProbes=0,scalarCount=0,unitCount=0,normalizedRows=0
        var checksum:UInt64=1469598103934665603
        func mix(_ byte:UInt8) { checksum=(checksum ^ UInt64(byte)) &* 1099511628211 }
        func probe(_ text:String) throws {
            let wasNative=text.isContiguousUTF8,original=Array(text.utf8)
            let a=ReferencePromptDetector.normalizedLinesAndUTF8ByteCount(text)
            let b=CandidatePromptDetector.normalizedLinesAndUTF8ByteCount(text)
            try require(a.byteCount==b.byteCount && a.byteCount==original.count,"Original byte budget changed in probe \(probes)")
            try require(a.lines.count==b.lines.count,"Row count changed in probe \(probes)")
            for (left,right) in zip(a.lines,b.lines) {
                try require(left.utf8.elementsEqual(right.utf8),"Exact normalized row changed in probe \(probes)")
                for byte in right.utf8 { mix(byte) };mix(255)
            }
            for shift in stride(from:0,to:64,by:8) { mix(UInt8(truncatingIfNeeded:b.byteCount >> shift)) }
            try require(text.isContiguousUTF8==wasNative && text.utf8.elementsEqual(original),"Original storage/bytes changed")
            if !wasNative { foreignProbes += 1 }
            probes += 1;normalizedRows += b.lines.count
        }
        func both(_ units:[UInt16]) throws {
            try autoreleasepool {
                try probe(String(decoding:units,as:UTF16.self))
                try probe(foreign(units))
            }
        }
        var bank=""
        for code in UInt32(0)...0x10ffff {
            guard let scalar=UnicodeScalar(code) else { continue }
            bank.append(String(scalar));bank.append("\n")
            bank.append("a");bank.append(String(scalar));bank.append("\u{301}\r\n")
            bank.append(" \u{200B}");bank.append(String(scalar));bank.append("\u{2000} \r")
            scalarCount += 1
            if scalarCount.isMultiple(of:1024) {
                try both(Array(bank.utf16));bank=""
                if scalarCount.isMultiple(of:262144) { print("ROW_SCALARS \(scalarCount)");fflush(stdout) }
            }
        }
        if !bank.isEmpty { try both(Array(bank.utf16)) }
        // The foreign source preserves isolated surrogate code units. The native
        // source repairs them before entry; both byte-budget contracts are checked.
        for start in stride(from:0,through:65535,by:1024) {
            var units:[UInt16]=[]
            for value in start..<start+1024 {
                units += [UInt16(value),10,97,UInt16(value),0x301,13,10,32,UInt16(value),0x2000,13]
                unitCount += 1
            }
            try both(units)
        }
        let endings:[[UInt16]]=[[0xd800],[0xdc00],[0xd800,0xd800,0xdc00],[0xdc00,0xd800],[0xd800,10,0xdc00],[0xd800,0xdc00],[0xffff,0xfffd,0,27],[0xd800,13,10,0xdc00]]
        for padding in [0,1,2,4093,4094,4095,4096,4097,8190,8191] {
            for ending in endings {
                try both(Array(repeating:UInt16(120),count:padding)+ending+[13,10,0x61,0x301,10,0x2000,10])
            }
        }
        for row in ["", "ASCII", "a\u{301}", "\u{11099}\u{110BA}", "\u{1109B}\u{110BA}", "\u{1fef}\u{1fef}\u{1fef}", "각", "👩🏽‍💻\0e\u{301}"] {
            for blank in ["", " ", "\t", "\u{2000}", "\u{200B}", "\u{FEFF}", "\u{0085}\u{2028}\u{2029}"] {
                for newline in ["\n","\r","\r\n"] {
                    try both(Array((blank+newline+row+newline+blank+newline+blank).utf16))
                }
            }
        }
        for budget in [4*1024*1024-1,4*1024*1024,4*1024*1024+1] {
            try both(Array((String(repeating:"x",count:budget-2)+"é").utf16))
        }
        try require(scalarCount==1_112_064 && unitCount==65_536 && foreignProbes>1000,"Missing scalar/unit/foreign coverage")
        print("COCOA_ROW_BRIDGE scalars \(scalarCount); contexts 3; scalarRowsPerStorage \(scalarCount*3); utf16Units \(unitCount); probes \(probes); foreign \(foreignProbes); normalizedRows \(normalizedRows); checksum \(checksum)")
        try CompleteSuffixCheck.main()
    }
}
