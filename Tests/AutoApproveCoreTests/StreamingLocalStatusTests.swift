import Foundation
import AutoApproveCore

// Independent released 0.2.163 algorithm; do not share the streaming helpers.
private func releasedLocalStatus(_ text:String) -> LocalDashboardAddress.Status {
    var found=false
    for line in text.components(separatedBy:.newlines) {
        let fields=line.split(separator:"#",maxSplits:1,omittingEmptySubsequences:false)[0].split(whereSeparator:{$0.isWhitespace})
        guard fields.count>1,fields.dropFirst().contains(where:{
            let name=$0.lowercased();return (name.hasSuffix(".") ? String(name.dropLast()) : name)=="autoapprove"
        }) else {continue}
        found=true;let address=String(fields[0])
        if address != "::1" && address != "127.0.0.1" {return .conflict}
    }
    return found ? .ready : .missing
}
private func foreignStatusText(_ text:String) -> String {
    let units=Array(text.utf16)
    return units.withUnsafeBufferPointer {NSString(characters:$0.baseAddress!,length:$0.count) as String}
}
private func assertLocalStatusParity(_ text:String,foreign:Bool=false) throws {
    try autoreleasepool {
        let value=foreign ? foreignStatusText(text) : text
        try expectEqual(LocalDashboardAddress.status(in:value),releasedLocalStatus(value),"Released parser parity for "+String(reflecting:text.prefix(120)))
    }
}

extension ApprovalTests {
    func testStreamingLocalStatusMatchesReleasedLexicalCorpus() throws {
        let addresses=["::1","127.0.0.1","10.0.0.1","0.0.0.0","\u{feff}127.0.0.1","127.0.0.1\u{301}"]
        let aliases=["autoapprove","AUTOAPPROVE.","autoapprove..","autoapprove-other",".autoapprove","ＡＵＴＯＡＰＰＲＯＶＥ","autoapprove\u{301}","other autoapprove"]
        let spaces=[" ","\t","\u{00a0}","\u{2003}","\u{202f}"," \u{301}","\u{200b}","\0"]
        let comments=["","#ignored"," # ignored","#\u{301} ignored","#\u{fe0f} ignored"]
        let newlines=["\n","\r","\r\n","\u{000b}","\u{000c}","\u{0085}","\u{2028}","\u{2029}"]
        for address in addresses {for alias in aliases {for space in spaces {for comment in comments {
            let line="한글 e\u{301}🙂 # ignored\n"+address+space+alias+comment
            try assertLocalStatusParity(line)
            for newline in newlines {
                let text=line+newline+"127.0.0.1 AUTOAPPROVE."+newline+"10.0.0.8 autoapprove\n"
                try assertLocalStatusParity(text)
            }
        }}}}
        for prefix in ["# 한글🙂\n","\u{feff}","\0","#\u{301}"] {
            for newline in newlines {
                try assertLocalStatusParity(prefix+"::1 autoapprove"+newline+"10.0.0.1 AUTOAPPROVE.",foreign:true)
            }
        }
    }

    func testStreamingLocalStatusKeepsNewlineSetAndCocoaBlockBoundaries() throws {
        var scalars:[UInt32]=[]
        for raw in UInt32(0)...0x10ffff {if let scalar=Unicode.Scalar(raw),CharacterSet.newlines.contains(scalar) {scalars.append(raw)}}
        try expectEqual(scalars,[10,11,12,13,133,8232,8233],"Fast line boundaries must match Foundation's complete newline set")
        for offset in [4094,4095,4096,4097,8190,8191,8192] {
            for newline in ["\r\n","\u{0085}","\u{2028}","\u{2029}"] {
                let text="#"+String(repeating:"a",count:offset-1)+"🙂"+newline+"::1\u{2003}AUTOAPPROVE."+newline+"#한글\n"
                try assertLocalStatusParity(text)
                let foreign=foreignStatusText(text)
                try expect(foreign.utf8.withContiguousStorageIfAvailable {_ in true} == nil,"The UTF-16 block test must exercise foreign storage")
                try assertLocalStatusParity(foreign)
            }
        }
    }

    func testStreamingLocalStatusDenseInputsKeepLateConflictsAndLongLines() throws {
        let limit=1_048_576
        let values=[String(repeating:"\n",count:limit),String(repeating:"#x\n",count:limit/3),
            String(repeating:"x",count:limit),String(repeating:"#한글 e\u{301}🙂\u{2028}",count:30_000)+"::1 autoapprove\n",
            "127.0.0.1 autoapprove\n"+String(repeating:"#x\n",count:100_000)+"10.0.0.1 AUTOAPPROVE.\n",
            String(repeating:"127.0.0.1 other ",count:20_000)+"autoapprove\n"]
        for value in values {try assertLocalStatusParity(value)}
        let foreign=foreignStatusText(values[3])
        try expectNil(foreign.utf8.withContiguousStorageIfAvailable {_ in true})
        try assertLocalStatusParity(foreign)
    }

    func testStreamingLocalStatusPreservesPreparedTextAndConflictRejection() throws {
        for text in ["","# 한글🙂\n","127.0.0.1 localhost\r\n","::1 AUTOAPPROVE.\n","10.0.0.9 autoapprove\n",
            "127.0.0.1 autoapprove#\u{301} keep\u{2028}","127.0.0.1\u{00a0}autoapprove\n"] {
            let status=releasedLocalStatus(text)
            if status == .conflict {try expectThrows(try LocalDashboardAddress.prepared(text))}
            else if status == .ready {try expectEqual(try LocalDashboardAddress.prepared(text),text)}
            else {
                let newline=text.contains("\r\n") ? "\r\n" : "\n"
                let expected=text+(text.isEmpty || text.hasSuffix("\n") ? "" : newline)
                    + [LocalDashboardAddress.marker,"127.0.0.1 autoapprove","::1 autoapprove",""].joined(separator:newline)
                try expectEqual(try LocalDashboardAddress.prepared(text),expected)
            }
        }
    }
}
