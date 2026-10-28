import Foundation
import IOKit.pwr_mgt
import AutoApproveCore

@main struct KeepAwakeActivityCheck {
    static func counts(_ pid:Int32) throws -> [String:Int] {
        var unmanaged:Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged)==kIOReturnSuccess,let value=unmanaged?.takeRetainedValue() as NSDictionary? else {throw AppError.message("IOPM assertions unavailable")}
        let rows=value[NSNumber(value:pid)] as? [[String:Any]] ?? []
        var result:[String:Int]=[:]
        for row in rows where (row[kIOPMAssertionLevelKey as String] as? NSNumber)?.intValue == Int(kIOPMAssertionLevelOn) {
            if let type=row[kIOPMAssertionTypeKey as String] as? String {result[type,default:0] += 1}
        }
        return result
    }
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--hold") {
            let activity=KeepAwakeActivityControl.live.begin()
            print("READY \(getpid())");fflush(stdout)
            try await Task.sleep(for:.seconds(30));KeepAwakeActivityControl.live.end(activity);return
        }
        if let at=CommandLine.arguments.firstIndex(of:"--pid"),CommandLine.arguments.indices.contains(at+1),let pid=Int32(CommandLine.arguments[at+1]) {
            print(String(decoding:try JSONEncoder().encode(counts(pid)),as:UTF8.self));return
        }
        let before=try counts(getpid()),activity=KeepAwakeActivityControl.live.begin()
        var held:[String:Int]=[:]
        for _ in 0..<100 {
            held=try counts(getpid())
            if held["PreventUserIdleDisplaySleep",default:0]>before["PreventUserIdleDisplaySleep",default:0],held["PreventUserIdleSystemSleep",default:0]>before["PreventUserIdleSystemSleep",default:0] {break}
            try await Task.sleep(for:.milliseconds(25))
        }
        KeepAwakeActivityControl.live.end(activity)
        guard held["PreventUserIdleDisplaySleep",default:0]>before["PreventUserIdleDisplaySleep",default:0],held["PreventUserIdleSystemSleep",default:0]>before["PreventUserIdleSystemSleep",default:0] else {throw AppError.message("Actual process display/system idle hold missing")}
        var after:[String:Int]=[:]
        for _ in 0..<100 {after=try counts(getpid());if after==before {break};try await Task.sleep(for:.milliseconds(25))}
        guard after==before else {throw AppError.message("Idle hold not released")}
        print("PASS real process display/system idle holds and explicit release; no pmset, input or lock setting changes")
    }
}
