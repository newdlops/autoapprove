import Foundation
import JavaScriptCore
import TerminalInputSupport
import AutoApproveCore

private final class GoalInterruptProbe: @unchecked Sendable {
    var directAvailable=true,keyboardAvailable=false,unknown=false
    var direct=0,keyboard=0,permissions=0
    var environment:TerminalGoalInterrupt.Environment {
        .init(directAvailable:{self.directAvailable},keyboardAvailable:{self.keyboardAvailable},direct:{_,_ in
            self.direct+=1;if self.unknown {throw AppError.message("unknown direct delivery")};return .sent
        },keyboard:{_,_ in self.keyboard+=1;if self.unknown {throw AppError.message("unknown key delivery")};return .sent},requestPermission:{self.permissions+=1})
    }
}
extension ApprovalTests {
    func testGoalInterruptTransportSelectionNeverFallsThrough() throws {
        let raw="⠋ Working (1s • esc to interrupt)\n\n› Ask Codex to do anything\n\n? for shortcuts"
        let identity=TTYInputIdentity(pid:77,processGroup:77,uid:501,effectiveUID:501,device:1,startSeconds:1,startMicroseconds:1)
        let target=ScreenTarget(tty:"/dev/ttys077",jobPIDs:[77],sourcePID:77,sourceStarted:identity.processStart,sourceIdentity:identity)
        let probe=GoalInterruptProbe()
        try expectEqual(try TerminalGoalInterrupt.deliver(target:target,expected:raw,environment:probe.environment),.sent)
        try expectEqual(probe.direct,1);try expectEqual(probe.keyboard,0)
        probe.unknown=true
        try expectThrows(try TerminalGoalInterrupt.deliver(target:target,expected:raw,environment:probe.environment))
        try expectEqual(probe.direct,2);try expectEqual(probe.keyboard,0)
        probe.keyboardAvailable=true;probe.unknown=false
        try expectEqual(try TerminalGoalInterrupt.deliver(target:target,expected:raw,environment:probe.environment),.sent)
        try expectEqual(probe.keyboard,1,"Authorized exact-window keyboard must not depend on helper health")
        try expectEqual(probe.direct,2)
        probe.keyboard=0
        probe.directAvailable=false;probe.unknown=false
        try expectEqual(try TerminalGoalInterrupt.deliver(target:target,expected:raw,environment:probe.environment),.sent)
        try expectEqual(probe.keyboard,1)
        probe.unknown=true
        try expectThrows(try TerminalGoalInterrupt.deliver(target:target,expected:raw,environment:probe.environment))
        try expectEqual(probe.keyboard,2);try expectEqual(probe.direct,2)
        probe.keyboardAvailable=false
        do { _=try TerminalGoalInterrupt.deliver(target:target,expected:raw,environment:probe.environment);throw AppError.message("Expected permissions") }
        catch let error as RemoteHTTPError {try expectEqual(error.diagnostics?["delivery"],"not_started")}
        try expectEqual(probe.permissions,1);try expectEqual(probe.keyboard,2);try expectEqual(probe.direct,2)
        try expectEqual(try TerminalGoalInterrupt.deliver(target:target,expected:raw.replacingOccurrences(of:"Ask Codex to do anything",with:"DRAFT"),environment:probe.environment),.screenChanged)
        try expectEqual(probe.permissions,1)
    }
    func testGoalInterruptGeneratedScriptPreservesDraftAndBody() throws {
        let raw="⠋ Working (1s • esc to interrupt)\n\n› Ask Codex to do anything\n\n? for shortcuts",target=ScreenTarget(tty:"/dev/ttys077")
        func result(_ current:String,relaxed:Bool)throws->String {
            let context=JSContext()!,literal=String(decoding:try JSONEncoder().encode(current),as:UTF8.self)
            context.evaluateScript("""
            const tab={tty:()=>'/dev/ttys077',contents:()=>\(literal),processes:()=>['codex']};
            const win={tabs:()=>[tab],id:()=>77};
            Object.defineProperty(win,'selectedTab',{get:()=>()=>tab,set:value=>{}});
            const app={running:()=>true,windows:()=>[win],activate:()=>{},frontmost:()=>true};
            function Application(){return app;}
            """)
            let answer=context.evaluateScript(try RemoteTerminalAdapter.script(host:.terminal,target:target,expected:raw,agent:.codex,input:.init(kind:.escape),goalWorkingComparison:relaxed))?.toString() ?? ""
            try expectNil(context.exception);return answer
        }
        let changed=raw.replacingOccurrences(of:"⠋ Working (1s",with:"⠙ Working (2s")
        try expectEqual(try result(changed,relaxed:false),"screenChanged")
        try expectEqual(try result(changed,relaxed:true),"ready:77")
        for current in [changed.replacingOccurrences(of:"Ask Codex to do anything",with:"UNSENT DRAFT"),"New response\n"+changed,changed+"\n1. Approve\n› 2. Reject"] {
            try expectEqual(try result(current,relaxed:true),"screenChanged")
        }
        try expectThrows(try RemoteTerminalAdapter.script(host:.terminal,target:target,expected:raw,agent:.codex,input:.init(kind:.interrupt),goalWorkingComparison:true))
    }
}
