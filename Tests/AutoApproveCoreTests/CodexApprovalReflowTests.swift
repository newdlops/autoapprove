import Foundation
import JavaScriptCore
import AutoApproveCore

private func approvalCellWrap(_ text:String,width:Int)->String {
    var result:[String]=[]
    for line in text.components(separatedBy:"\n") {
        var remainder=line
        while remainder.count>width {result.append(String(remainder.prefix(width)));remainder=String(remainder.dropFirst(width))}
        result.append(remainder)
    }
    return result.joined(separator:"\n")
}
private let reflowPermission="Would you like to run the following command?\n\n  $ echo synthetic_한글🙂\n\n› 1. Yes, proceed (y)\n  2. Yes, and don't ask again for commands that start with `echo synthetic-long-command-prefix` (p)\n  3. No, and tell Codex what to do differently (esc)\n\nPress enter to confirm or esc to cancel"

extension ApprovalTests {
    func testCodexApprovalCellWrappedChoicesAndSubagentPreserveOneTimeScope() throws {
        for child in [false,true] {
            let raw=child ? reflowPermission.replacingOccurrences(of:"\n\n  $",with:"\n\nThread: synthetic [explorer]\n\n  $")+" or o to open thread":reflowPermission
            let original=PromptDetector.detect(raw,agent:.codex)!
            for width in 20...120 {
                let wrapped=approvalCellWrap(raw,width:width)
                let detected=PromptDetector.detect(wrapped,agent:.codex)
                try expectEqual(detected?.answer,"1","Every complete cell-wrapped permission must remain recognizable at width \(width)")
                try expectEqual(detected?.requestIdentity,original.requestIdentity,"Reflow must not turn the same request into another permission")
                try expectEqual(detected?.dialog,wrapped,"Keep the complete original command and dialog for final validation")
                let units=Array(wrapped.utf16)
                let cocoa=units.withUnsafeBufferPointer {NSString(characters:$0.baseAddress!,length:$0.count) as String}
                try expectEqual(PromptDetector.detect(cocoa,agent:.codex)?.requestIdentity,original.requestIdentity,"Cocoa and native screen paths must agree")
            }
            let ansi="\u{1b}[33m"+raw.replacingOccurrences(of:"\n",with:"\r\n")+"\u{1b}[0m"
            for width in [20,24,25,40,60,80,120] {
                let cells=try OriginalTerminalScreen.render(ansi:ansi,columns:width,rows:80,tty:"/dev/reflow")
                try expectEqual(PromptDetector.detect(cells.contents,agent:.codex)?.requestIdentity,original.requestIdentity)
                let clipped=try OriginalTerminalScreen.render(ansi:ansi,columns:width,rows:4,tty:"/dev/reflow")
                try expectNil(PromptDetector.detect(clipped.contents,agent:.codex))
            }
        }
    }
    func testCodexAllowReasonCannotReplaceTheEnclosingCommandHeading() throws {
        let reason="Reason: Inspect the synthetic workspace.\nAllow the sandboxed process to inspect the fixture."
        let raw=reflowPermission.replacingOccurrences(of:"\n\n  $",with:"\n\n"+reason+"\n\n  $")
        for width in [25,40,60,80,120] {
            let detected=PromptDetector.detect(approvalCellWrap(raw,width:width),agent:.codex)
            try expectEqual(detected?.answer,"1","A reason paragraph is not another tool capability prompt")
            try expect(detected?.summary.contains("Would") == true)
        }
        let later=raw+"\n\nAllow Preview?\n\n  $ echo new-tool-request\n\n› 1. Allow once\n  2. Always allow\n  3. Cancel\n\nEnter to confirm or esc to cancel"
        let current=PromptDetector.detect(later,agent:.codex)
        try expectEqual(current?.answer,"1","A genuine later Allow card must replace the old command, even when its body contains a command")
        try expect(current?.summary.hasPrefix("Allow Preview?")==true,"Keep the current tool request's own identity")
    }
    func testCodexReflowNeverCompletesClippedUnknownOrTaskChoices() throws {
        for raw in [
            reflowPermission.replacingOccurrences(of:"Yes, proceed (y)",with:"Yes, use staging (y)"),
            reflowPermission.replacingOccurrences(of:"No, and tell Codex what to do differently (esc)",with:"No, use production (esc)"),
            reflowPermission.replacingOccurrences(of:"Yes, proceed (y)",with:"Yes, pro…"),
            reflowPermission.replacingOccurrences(of:"Press enter to confirm or esc to cancel",with:"Press enter to conf…"),
            reflowPermission.replacingOccurrences(of:"› 1.",with:"  1.").replacingOccurrences(of:"  3.",with:"› 3."),
            reflowPermission+"\nWhich project should we change?\n› 1. Staging\n  2. Production\nEnter to confirm or esc to cancel"
        ] {
            for width in [25,40,60,80,120] {try expectNil(PromptDetector.detect(approvalCellWrap(raw,width:width),agent:.codex))}
        }
    }
    func testCodexReflowFinalValidatorStillChecksExactCommandAndQuestion() throws {
        let wrapped=approvalCellWrap(reflowPermission,width:40)
        let context=JSContext()!
        context.setObject(wrapped,forKeyedSubscript:"current" as NSString)
        context.evaluateScript("var writes=[];var tab={tty:()=>'/dev/reflow',contents:()=>current,processes:()=>['codex']};function Application(){return {running:()=>true,windows:()=>[{tabs:()=>[tab]}],doScript:value=>writes.push(value)};}")
        let script=try TerminalAdapter.approvalScript(tty:"/dev/reflow",expectedScreen:wrapped,agent:.codex)
        try expectEqual(context.evaluateScript(script)?.toString(),"sent")
        try expectEqual(context.evaluateScript("writes.join(',')")?.toString(),"1")
        for changed in [wrapped.replacingOccurrences(of:"synthetic_",with:"different_"),"Which environment?\n› 1. Staging\n  2. Production\nEnter to confirm or esc to cancel"] {
            context.setObject(changed,forKeyedSubscript:"current" as NSString)
            try expectEqual(context.evaluateScript(script)?.toString(),"screenChanged")
        }
        try expectEqual(context.evaluateScript("writes.length")?.toInt32(),1,"A valid wrapped frame never authorizes a different command or an intervening question")
    }
}
