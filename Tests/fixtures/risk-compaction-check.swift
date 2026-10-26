import Foundation
import CoreFoundation
import CryptoKit
import AutoApproveCore

@main struct ASCIIRiskCheck {
    static func require(_ value: Bool, _ message: @autoclosure () -> String) throws {
        if !value { throw AppError.message(message()) }
    }
    static func signature(_ value: ReferenceRisk?) -> String {
        guard let value else { return "nil" }
        return [value.kind.rawValue,value.evidence,value.title,value.detail,value.alternative,value.guidance].joined(separator:"\n")
    }
    static func signature(_ value: CandidateRisk?) -> String {
        guard let value else { return "nil" }
        return [value.kind.rawValue,value.evidence,value.title,value.detail,value.alternative,value.guidance].joined(separator:"\n")
    }
    static func main() throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]), a=root.appendingPathComponent("a"), b=root.appendingPathComponent("b")
        for directory in [a,b] { try FileManager.default.createDirectory(at:directory.appendingPathComponent("tools"),withIntermediateDirectories:true) }
        var triples=0, scalars=0, policies=0, normalizations=0, foreign=0, sourceChanges=0, digest=SHA256()
        func exclusion(_ text: String) throws {
            let before = Array(text.utf8), storage = text.isContiguousUTF8
            let expected = ReferenceRisk.oracleCompact(text), actual = CandidateRisk.oracleCompact(text)
            try require(expected.utf8.elementsEqual(actual.utf8), "Changed exact Character compaction: \(text.debugDescription)")
            try require(text.utf8.elementsEqual(before) && text.isContiguousUTF8 == storage, "Changed caller storage")
            normalizations += 1
        }
        func policy(_ text: String, cwd: String="") throws -> String {
            let bytes=Array(text.utf8), storage=text.isContiguousUTF8
            let left=ReferenceRisk.detect(text,cwd:cwd), right=CandidateRisk.detect(text,cwd:cwd)
            let expected=signature(left), actual=signature(right)
            try require(expected==actual,"Changed policy: \(text.debugDescription)")
            try require(text.utf8.elementsEqual(bytes) && text.isContiguousUTF8==storage,"Changed policy input")
            if let left,let right {
                for event in ["PreToolUse","PermissionRequest"] {
                    let lhs=try JSONSerialization.data(withJSONObject:left.denial(event:event),options:[.sortedKeys])
                    let rhs=try JSONSerialization.data(withJSONObject:right.denial(event:event),options:[.sortedKeys])
                    try require(lhs==rhs,"Changed exact denial")
                }
            }
            try exclusion(text);policies += 1;if !storage { foreign += 1 }
            digest.update(data:Data(actual.utf8));digest.update(data:Data([0]))
            return actual
        }
        // Every ASCII triple can include control bytes, CRLF and whitespace
        // that can join a candidate. ICU receives the exact old compact input.
        for first in UInt8(0)..<128 { for second in UInt8(0)..<128 { for third in UInt8(0)..<128 {
            try exclusion("su"+String(decoding:[first,second,third],as:UTF8.self)+"do id")
            triples += 1
        }}}
        print("ASCII_TRIPLES \(triples)")
        // Compare exact compact UTF8 for every valid scalar in three grapheme
        // contexts, including a whitespace base with combining marks.
        for value in UInt32(0)...0x10ffff {
            guard let scalar=Unicode.Scalar(value) else { continue }
            let text="su"+String(scalar)+"do id"
            for raw in [text, "\t"+String(scalar)+"\r\n", " \u{301}"+String(scalar)+"\u{000b}\u{301}"] { try exclusion(raw) }
            scalars += 1
        }
        print("SCALARS \(scalars)")
        for units: [UInt16] in [[0xd800],[0xdc00],[0xd800,0xd800,0xdc00],[0xdc00,0xd800],[0xd800,10,0xdc00],[0xd800,0xdc00],[0xffff,0xfffd,0,27]] {
            let repaired = String(decoding: units, as: UTF16.self)
            for count in [0,1,15,16,31,4096] {
                let raw = String(repeating: " \t\r\n", count: count) + repaired + "\u{000b} \u{301}"
                for text in [raw, NSAppleEventDescriptor(string: raw).stringValue!] { try exclusion(text) }
            }
        }
        let words=ReferenceRisk.oracleWords()
        try require(words==CandidateRisk.oracleWords(),"Candidate words changed")
        for word in words {
            for byte in UInt8(0)..<128 {
                for position in 0...word.utf8.count {
                    var bytes=Array(word.utf8);bytes.insert(byte,at:position)
                    try exclusion(String(decoding:bytes,as:UTF8.self))
                }
            }
            for separator in [" ","\t","\r\n","\u{00a0}","\u{2003}"," \u{0301}","\u{200d}","\u{0085}"] {
                let separated=word.map(String.init).joined(separator:separator)
                for prefix in ["","Old ordinary output\n$ ","한글 e\u{301} 👩🏽‍💻\n$ "] {
                    for text in [prefix+separated,NSAppleEventDescriptor(string:prefix+separated).stringValue!] { _=try policy(text) }
                }
            }
        }
        let commands=["npm test","git status --short","echo e\u{301} 한글 👩🏽‍💻","su👩🏽‍💻do id","l\u{200d}aunchctl bootstrap fixture",
            "sudo id","SUDO id","ſudo id","syﬆemctl start fixture","tccutil reset Accessibility","spctl --master-disable",
            "csrutil authenticated-root disable","defaults write a b c","chmod 777 /etc/fixture","cp x /etc/hosts",
            "networksetup -setairportpower en0 off","systemsetup -setremotelogin on","osascript -e 'with administrator privileges'",
            "launchctl bootstrap gui/501 a.plist","launchctl kickstart gui/501/a","crontab tasks.txt","systemctl start fixture",
            "cp a.plist ~/Library/LaunchAgents/a.plist","mkdir -p ~/Library/LaunchDaemons","echo payload > /Library/LaunchDaemons/a.plist",
            "python3 -c 'Path.home().joinpath(\"Library/LaunchAgents/a.plist\").write_text(payload)'",
            "cat x; cp x ~/Library/LaunchAgents/a.plist","cat x | tee ~/Library/LaunchAgents/a.plist",
            "cp x ~/Library/LaunchA\ngents/a.plist","cp x /Library/LaunchDae\nmons/a.plist",
            "cat ~/Library/LaunchAgents/a.plist","stat ~/Library/LaunchAgents/a.plist","plutil -p ~/Library/LaunchAgents/a.plist",
            "launchctl print gui/501/com.fixture","launchctl list","crontab -l","defaults read a","pmset -g assertions",
            "networksetup -getairportpower en0","python3 tools/report.py","cp fixture ./etc/hosts","echo \u{4}\0\u{1b} ordinary",
            "python3 tools/check.py --install","python3 tools/check.py --register","python3 tools/check.py --inſtall",
            "python3 tools/install_status.py","python3 tools/install_status\n.py --install","python3 tools/check.py --INSTALL",
            "python3 ../tools/check.py --install","python3 tools/check.py -- --install","python3 tools/check.py --\ninstall"]
        for command in commands { for whitespace in [" ","\t","\r\n","\u{00a0}","\u{2003}","\u{0085}"] {
            for prefix in ["","Synthetic history\n$ ","한글 e\u{301} 👩🏽‍💻\n$ ",String(repeating:"Old ordinary ASCII output.\n",count:160)+"$ "] {
                let text=prefix+command.replacingOccurrences(of:" ",with:whitespace)
                for value in [text,NSAppleEventDescriptor(string:text).stringValue!] { _=try policy(value,cwd:a.path) }
            }
        }}
        // An installer is never executed. Its bytes, path, limit and symlink
        // boundaries change between identical requests to prove fresh reads.
        let safe=Data("print('fixture only; never executed')\n".utf8)
        let unsafe=Data("Path.home().joinpath('Library/LaunchAgents/com.fixture.plist').write_text(payload)\n".utf8)
        try unsafe.write(to:b.appendingPathComponent("external.py"))
        for name in ["check.py","install_status.py"] { try unsafe.write(to:b.appendingPathComponent("tools/"+name)) }
        var previous:[String:String]=[:]
        for state in ["missing","safe","unsafe","oversized","invalid","symlink-outside-cwd","safe","unsafe","missing"] {
            for name in ["check.py","install_status.py"] {
                let file=a.appendingPathComponent("tools/"+name)
                if FileManager.default.fileExists(atPath:file.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath:file.path)) != nil { try FileManager.default.removeItem(at:file) }
                switch state {
                case "safe":try safe.write(to:file)
                case "unsafe":try unsafe.write(to:file)
                case "oversized":try (Data(repeating:35,count:131_073)+unsafe).write(to:file)
                case "invalid":try Data([0xff,0xfe,0x80]).write(to:file)
                case "symlink-outside-cwd":try FileManager.default.createSymbolicLink(atPath:file.path,withDestinationPath:b.appendingPathComponent("external.py").path)
                default:break
                }
            }
            for command in commands { for prefix in ["","한글 e\u{301} 👩🏽‍💻\n$ "] { for cwd in [a.path,b.path,""] {
                let text=prefix+command,key=cwd+"\n"+text,result=try policy(text,cwd:cwd)
                if let old=previous[key],old != result { sourceChanges += 1 }
                previous[key]=result
            }}}
        }
        // Tool events and generic questions must retain their existing bypass
        // and destination semantics in addition to the raw-text entry point.
        var tools=0
        for tool in ["Bash","Write","Edit","MultiEdit","Read","Glob","Grep","LS","AskUserQuestion","other"] {
            for command in commands {
                let inputs:[JSONObject]=[["command":command],["file_path":command,"content":"fixture"],["path":command],["questions":[["question":command,"options":[["label":"First"],["label":"Second"]]]]]]
                for input in inputs {
                    let left=ReferenceRisk.detect(tool:tool,input:input,summary:"Synthetic summary",cwd:a.path)
                    let right=CandidateRisk.detect(tool:tool,input:input,summary:"Synthetic summary",cwd:a.path)
                    try require(signature(left)==signature(right),"Changed tool policy: \(tool)")
                    digest.update(data:Data(signature(right).utf8));tools += 1
                }
            }
        }
        try require(sourceChanges>0 && foreign>0 && normalizations>0,"Missing coverage")
        try ReservedBuilderEdges.run()
        try ASCIISpanEdges.run()
        let hex=digest.finalize().map{String(format:"%02x",$0)}.joined()
        print("ASCII_COMPACTION triples \(triples); scalars \(scalars); policies \(policies); tools \(tools); normalizations \(normalizations); foreign \(foreign); sourceChanges \(sourceChanges); digest \(hex)")
    }
}


struct ReservedBuilderEdges {
    static func raw(_ text:String)->[UInt16] {
        let source=text as NSString
        guard source.length>0 else{return []}
        var result=[UInt16](repeating:0,count:source.length)
        result.withUnsafeMutableBufferPointer {source.getCharacters($0.baseAddress!,range:NSRange(location:0,length:$0.count))}
        return result
    }
    static func stores(_ units:[UInt16])->[String] {
        guard !units.isEmpty else{return [""]}
        return [String(decoding:units,as:UTF16.self),
                units.withUnsafeBufferPointer {NSString(characters:$0.baseAddress!,length:$0.count) as String},
                units.withUnsafeBufferPointer {unsafeBitCast(CFStringCreateWithCharacters(kCFAllocatorDefault,$0.baseAddress!,$0.count)!,to:NSString.self) as String}]
    }
    static func run() throws {
        let seeds:[[UInt16]]=[[0xd55c],[0xd800],[0xdc00],[0xd800,32,0xdc00],Array("👩🏽‍💻".utf16),[32,0x301],[13,10],[0x2003]]
        var cases=0,foreign=0
        for seed in seeds {for count in [0,126,127,128,129,4095,4096,4097] {
            let white=[UInt16](repeating:0x2003,count:count),ascii=[UInt16](repeating:32,count:count)
            for units in [[UInt16](repeating:120,count:count)+seed,white+seed+[0x2003],seed+white,ascii+seed+[0x301],white+[120,13,10]+seed+[121]] {
                for source in stores(units) {
                    let before=Array(source.utf8),unitsBefore=raw(source),native=source.isContiguousUTF8
                    if !native {foreign += 1}
                    let left=ReferenceRisk.oracleCompact(source),right=CandidateRisk.oracleCompact(source)
                    guard left.utf8.elementsEqual(right.utf8),raw(left)==raw(right),
                          source.utf8.elementsEqual(before),raw(source)==unitsBefore,source.isContiguousUTF8==native else {
                        throw AppError.message("Reserved builder changed bytes/storage at threshold \(count)")
                    }
                    cases += 1
                }
            }
        }}
        guard cases==960,foreign>0 else {throw AppError.message("Missing reserved builder coverage")}
        print("RESERVED_BUILDER edges \(cases); foreign \(foreign)")
    }
}

struct ASCIISpanEdges {
    static func equal(_ text:String) throws {
        let bytes=Array(text.utf8),raw=ReservedBuilderEdges.raw(text),native=text.isContiguousUTF8
        let left=ReferenceRisk.oracleCompact(text),right=CandidateRisk.oracleCompact(text)
        guard left.utf8.elementsEqual(right.utf8),ReservedBuilderEdges.raw(left)==ReservedBuilderEdges.raw(right),
              text.utf8.elementsEqual(bytes),ReservedBuilderEdges.raw(text)==raw,text.isContiguousUTF8==native else {
            throw AppError.message("ASCII span compaction changed exact bytes or storage")
        }
    }
    static func run() throws {
        var triples=0,caps=0,foreign=0
        for a in UInt8(0)..<128 {for b in UInt8(0)..<128 {for c in UInt8(0)..<128 {
            // The prefix forces the new path before every ASCII/control triple.
            try equal("한 a useful ASCII prefix su"+String(decoding:[a,b,c],as:UTF8.self)+"do id 🧪")
            triples += 1
        }}}
        let prefix=Array("An ordinary ASCII span long enough. ".utf16)
        let seeds:[[UInt16]]=[[0xd800],[0xdc00],[0xd800,32,0xdc00],[32,0x301],[13,10],Array("👩🏽‍💻".utf16)]
        for total in [65535,65536,65537] {for seed in seeds {
            let units=prefix+[UInt16](repeating:0x2003,count:total-prefix.count-seed.count)+seed
            for text in ReservedBuilderEdges.stores(units) {try equal(text);caps += 1;if !text.isContiguousUTF8 {foreign += 1}}
        }}
        try ASCIISpanLongEdges.run()
        try CharacterRunScalarBatches.run()
        guard triples==2097152,caps==54,foreign>0 else {throw AppError.message("Missing ASCII span coverage")}
        print("ASCII_SPANS triples \(triples); caps \(caps); foreign \(foreign)")
    }
}

struct ASCIISpanLongEdges {
    static func run() throws {
        var cases=0,foreign=0
        for count in [1,2,3,31,32,63,64,65,127,128,1024,4096] {
            let prefix="An ordinary ASCII span long enough. "
            let rows=[prefix+String(repeating:"🇦🇧",count:count),
                      prefix+String(repeating:"\u{301}",count:count)+" x",
                      prefix+String(repeating:"👩🏽‍💻",count:count)+" x",
                      prefix+String(repeating:"a\u{600}",count:count)+" x",
                      String(repeating:"x",count:max(64,count*8))+" "+String(repeating:"🇦🇧",count:count)]
            for row in rows {for text in ReservedBuilderEdges.stores(Array(row.utf16)) {
                try ASCIISpanEdges.equal(text);cases += 1;if !text.isContiguousUTF8 {foreign += 1}
            }}
        }
        guard cases==180,foreign>0 else {throw AppError.message("Missing long-grapheme coverage")}
        print("ASCII_SPAN_LONG cases \(cases); foreign \(foreign)")
    }
}

struct CharacterRunScalarBatches {
    static func run() throws {
        var scalars=0,batches=0,foreign=0,text=""
        func check() throws {
            guard !text.isEmpty else{return}
            for source in ReservedBuilderEdges.stores(Array(text.utf16)) {
                try ASCIISpanEdges.equal(source);batches += 1
                if !source.isContiguousUTF8 {foreign += 1}
            }
            text=""
        }
        for value in UInt32(0)...0x10ffff {
            guard let scalar=UnicodeScalar(value) else{continue}
            let s=String(scalar)
            text += "su"+s+"do id\n "+s+"\u{b}\u{301}\n\t"+s+"\r\n"
            scalars += 1
            if scalars%256==0 {try check()}
        }
        try check()
        guard scalars==1112064,batches==13032,foreign>0 else {throw AppError.message("Missing forced character-run scalar coverage")}
        print("CHARACTER_RUN_SCALARS scalars \(scalars); batches \(batches); foreign \(foreign)")
    }
}
