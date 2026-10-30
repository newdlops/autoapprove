import Foundation
import AppKit
import AutoApproveCore

/// Read-only production-boundary check. Never reads or controls Terminal UI.
@main private struct Main {
    static func pids() throws -> [Int32] {
        let result=try CommandRunner.run("/bin/ps",["-axo","pid=,uid=,comm="],timeout:3)
        guard result.status==0 else {throw AppError.message("Independent process snapshot failed")}
        return result.output.split(separator:"\n").compactMap {line in
            let fields=line.split(maxSplits:2,whereSeparator:{$0.isWhitespace})
            guard fields.count==3,UInt32(fields[1])==getuid(),fields[2]==TerminalProcessLookup.executable else {return nil}
            return Int32(fields[0])
        }.sorted()
    }
    static func main() async {
        do {
            let before=try pids()
            guard before.count<=1 else {throw AppError.message("Multiple system Terminal processes: live check requires an unambiguous owner")}
            let report=try await Task.detached(priority:.utility) {() throws -> [String:Any] in
                let registry=NSRunningApplication.runningApplications(withBundleIdentifier:TerminalProcessLookup.bundleID).filter {!$0.isTerminated}.map(\.processIdentifier).sorted()
                var checks=0
                for _ in 0..<16 {
                    if let expected=before.first {
                        let owner=try TerminalProcessLookup.running()
                        guard owner.pid==expected,owner==TerminalProcessLookup.identity(pid:expected),TerminalProcessLookup.ownerBundle(pid:expected)==TerminalProcessLookup.bundleID else {throw AppError.message("Kernel owner differs from independent process snapshot")}
                        _ = try TerminalNativeTabReader.terminal() // Creates an AX handle; performs no AX reads/actions.
                    } else {
                        do {_ = try TerminalProcessLookup.running();throw AppError.message("Unexpected Terminal owner")}
                        catch TerminalProfileAccessError.terminalNotRunning {}
                    }
                    checks+=1
                }
                return ["passed":true,"backgroundChecks":checks,"terminalRunning":!before.isEmpty,"registryAgreesWithKernel":registry==before,"terminalUIAccess":false,"accessibilityReads":0,"accessibilityActions":0,"keyEvents":0]
            }.value
            guard try pids()==before else {throw AppError.message("Terminal process changed during the read-only check")}
            print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),as:UTF8.self))
        } catch {
            fputs("Terminal process check failed: \(error.localizedDescription)\n",stderr);exit(1)
        }
    }
}
