import Foundation
@testable import AutoApproveCore

private final class PowerProbe: @unchecked Sendable {
    var sleepDisabled = true
    var begins = 0, ends = 0, starts = 0, stops = 0
    var changes: [Bool] = []
    var failGuard = false
    var control: PowerControl {
        PowerControl(read: { PowerReading(sleepDisabled:self.sleepDisabled,lidClosed:true) },
            ruleInstalled: {true},ruleFile:{true},installRule:{fatalError("No new permission")},removeRule:{fatalError("No permission removal")},
            setSleepDisabled: { self.changes.append($0);self.sleepDisabled=$0 },
            startGuard: { _,floor in
                precondition(floor == 20)
                if self.failGuard { throw AppError.message("fixture guard failure") }
                self.starts += 1
                return KeepAwakeGuard(isRunning:{true},stop:{self.stops += 1})
            },activity:KeepAwakeActivityControl(begin:{self.begins += 1;return NSObject()},end:{_ in self.ends += 1}))
    }
}
@main struct Check {
    @MainActor static func main() async throws {
        let home=FileManager.default.temporaryDirectory.appendingPathComponent("aa-closed-lid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:home)}
        let marker=home.appendingPathComponent("keep-awake.hold"),probe=PowerProbe()
        let unowned=try LANUpdateSleepHandoff(home:home.path,control:probe.control)
        precondition(probe.starts==0 && unowned.readyForNewOwner(nil));unowned.complete();unowned.finishActivity()
        try Data("owned".utf8).write(to:marker)
        let transfer=try LANUpdateSleepHandoff(home:home.path,control:probe.control)
        precondition(probe.starts==1 && !transfer.readyForNewOwner(nil))
        precondition(!transfer.readyForNewOwner(["keepAwake":["phase":"failed"]]))
        precondition(transfer.readyForNewOwner(["keepAwake":["phase":"holding"]]))
        transfer.complete();transfer.finishActivity()
        precondition(probe.stops==1 && probe.changes.isEmpty)
        let failed=try LANUpdateSleepHandoff(home:home.path,control:probe.control)
        failed.finishActivity()
        precondition(probe.starts==2 && probe.stops==1,"Failure must retain the installer watchdog for crash cleanup")
        probe.failGuard=true
        do {_ = try LANUpdateSleepHandoff(home:home.path,control:probe.control);preconditionFailure()} catch {}
        precondition(probe.begins==probe.ends)
        probe.failGuard=false
        let engine=try ApprovalEngine(paths:AppPaths(directory:home),powerControl:probe.control)
        precondition(engine.updateWaitReason(allowTunnelRestart:false)==nil,"Closed lid alone cannot block automatic updates")
        engine.prepareLANUpdateExit();engine.stop()
        precondition(probe.changes.isEmpty && FileManager.default.fileExists(atPath:marker.path))
        let ordinary=try ApprovalEngine(paths:AppPaths(directory:home),powerControl:probe.control)
        ordinary.stop()
        precondition(probe.changes==[false] && !FileManager.default.fileExists(atPath:marker.path),"Ordinary Quit must still restore normal sleep")
        precondition(failed.readyForNewOwner(nil),"A disabled/removed hold does not need a new watchdog")
        print("PASS: closed-lid updates, owned-only sleep transfer, idle assertion, new-owner readiness, failure watchdog, guard setup failure and ordinary Quit restoration; no OS power changes")
    }
}
