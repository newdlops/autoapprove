import Foundation
import AutoApproveCore

extension ApprovalTests {
    func testTerminalProcessLookupDoesNotRequireApplicationRegistry() throws {
        let live=TerminalProcessIdentity(pid:81001,startedSeconds:1700000000,startedMicroseconds:123456)
        var inspected:[Int32]=[]
        // A kernel PID table, without any LaunchServices application objects.
        let source=TerminalProcessLookup.Source(candidates:{[0,81000,81001,81001]},identity:{pid in
            inspected.append(pid);return pid==live.pid ? live:nil
        })
        try expectEqual(try TerminalProcessLookup.running(source:source),live)
        try expectEqual(inspected,[81000,81001])
        let replacement=TerminalProcessIdentity(pid:live.pid,startedSeconds:live.startedSeconds,startedMicroseconds:live.startedMicroseconds+1)
        try expect(replacement != live,"A reused PID must not keep the original owner identity")
    }

    func testTerminalProcessLookupRejectsMissingAmbiguousAndFailedReads() throws {
        for candidates:[Int32] in [[],[81000]] {
            var caught:Error?
            do {_ = try TerminalProcessLookup.running(source:.init(candidates:{candidates},identity:{_ in nil}))} catch {caught=error}
            try expectEqual(caught as? TerminalProfileAccessError,.terminalNotRunning)
        }
        let unavailable=AppError.message("Kernel process list unavailable")
        var failed:Error?
        do {_ = try TerminalProcessLookup.running(source:.init(candidates:{throw unavailable},identity:{_ in nil}))} catch {failed=error}
        try expectEqual(failed?.localizedDescription,unavailable.localizedDescription)
        try expect(failed as? TerminalProfileAccessError == nil,"A failed query is not evidence that Terminal stopped")
        var ambiguous:Error?
        do {_ = try TerminalProcessLookup.running(source:.init(candidates:{[81000,81001]},identity:{.init(pid:$0,startedSeconds:1,startedMicroseconds:0)}))} catch {ambiguous=error}
        try expect(ambiguous != nil);try expect(ambiguous as? TerminalProfileAccessError == nil)
        var wrongPID:Error?
        do {_ = try TerminalProcessLookup.running(source:.init(candidates:{[81000]},identity:{_ in .init(pid:81001,startedSeconds:1,startedMicroseconds:0)}))} catch {wrongPID=error}
        try expectEqual(wrongPID as? TerminalProfileAccessError,.terminalNotRunning)
    }

    func testTerminalProcessLiveIdentityRejectsUnrelatedExecutableAndInvalidPID() throws {
        try expect(TerminalProcessLookup.identity(pid:getpid())==nil,"The checks executable is not the system Terminal")
        try expect(TerminalProcessLookup.identity(pid:0)==nil)
        try expect(TerminalProcessLookup.identity(pid:-1)==nil)
        try expect(TerminalProcessLookup.identity(pid:Int32.max)==nil)
        try expect(TerminalProcessLookup.ownerBundle(pid:getpid()) != TerminalProcessLookup.bundleID)
    }
}
