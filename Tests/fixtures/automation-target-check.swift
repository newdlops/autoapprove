// The runner appends the real non-prompting preflight implementation. OS
// application lookup and permission transport are substituted; no TCC call runs.
import Foundation
import AppKit
import Carbon

private struct ScreenHost { let bundleID: String }
private struct FixtureRunningApplication {
    let processIdentifier: pid_t
    static var applications: [String:[FixtureRunningApplication]] = [:]
    static var lookedUp: [String] = []
    static func runningApplications(withBundleIdentifier id: String) -> [Self] {
        lookedUp.append(id); return applications[id] ?? []
    }
}
private struct PermissionQuery {
    let type: DescType
    let pid: pid_t
    let eventClass: AEEventClass
    let eventID: AEEventID
    let prompt: Bool
}
private var queries: [PermissionQuery] = []
private var permissionStatus: OSStatus = noErr
private func fixturePermission(_ target: UnsafePointer<AEAddressDesc>!, _ eventClass: AEEventClass,
                               _ eventID: AEEventID, _ prompt: Bool) -> OSStatus {
    var pid: pid_t = 0
    if target.pointee.descriptorType == typeKernelProcessID {
        _ = AEGetDescData(target,&pid,MemoryLayout<pid_t>.size)
    }
    queries.append(PermissionQuery(type:target.pointee.descriptorType,pid:pid,eventClass:eventClass,eventID:eventID,prompt:prompt))
    return permissionStatus
}
private struct CheckFailure: Error { let message: String }
private func require(_ value: Bool, _ message: String) throws {
    if !value { throw CheckFailure(message:message) }
}
@main struct AutomationTargetCheck {
    static func main() {
        do {
            let terminal = ScreenHost(bundleID:"com.apple.Terminal"), iterm = ScreenHost(bundleID:"com.googlecode.iterm2")
            FixtureRunningApplication.applications[terminal.bundleID] = [.init(processIdentifier:910001)]
            try require(liveAutomationPermission(terminal),"A running target with granted permission remains granted")
            try require(queries.count == 1 && queries[0].type == typeKernelProcessID && queries[0].pid == 910001,
                "Preflight must target the already-running PID, without bundle-name target resolution")
            FixtureRunningApplication.applications[terminal.bundleID] = []
            try require(!liveAutomationPermission(terminal) && queries.count == 1,"Do not query or launch an absent target")
            for pid: pid_t in [0,-1] {
                FixtureRunningApplication.applications[terminal.bundleID] = [.init(processIdentifier:pid)]
                try require(!liveAutomationPermission(terminal) && queries.count == 1,"Invalid process IDs never become permission targets")
            }
            FixtureRunningApplication.applications[terminal.bundleID] = [.init(processIdentifier:910002)]
            permissionStatus = OSStatus(errAEEventNotPermitted)
            try require(!liveAutomationPermission(terminal) && queries.last?.pid == 910002,"A replacement process and revoked permission are checked afresh")
            permissionStatus = OSStatus(errAEEventWouldRequireUserConsent)
            try require(!liveAutomationPermission(terminal),"Missing consent remains denied without requesting a prompt")
            FixtureRunningApplication.applications[iterm.bundleID] = [.init(processIdentifier:920001)]
            permissionStatus = noErr
            try require(liveAutomationPermission(iterm) && queries.last?.pid == 920001,"Resolve the actual requested host")
            try require(queries.allSatisfy { $0.eventClass == typeWildCard && $0.eventID == typeWildCard && !$0.prompt },
                "Preserve the existing permission scope and never prompt")
            try require(FixtureRunningApplication.lookedUp == Array(repeating:terminal.bundleID,count:6)+[iterm.bundleID],
                "Do not cache a previous process or permission result")
            print("PASS: running PID, absent app, invalid IDs, replaced PID, denied/revoked/missing consent, host and non-prompting scope; no live permissions or GUI touched")
        } catch let failure as CheckFailure { fputs("FAIL: \(failure.message)\n",stderr); exit(1) }
        catch { fputs("FAIL: fixture error\n",stderr); exit(1) }
    }
}
