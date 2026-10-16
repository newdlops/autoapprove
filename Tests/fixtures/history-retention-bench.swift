import Foundation
import Darwin
import AutoApproveCore

/// A synthetic, read-only history database; no Codex daemon or user transcript.
@main struct HistoryRetentionBench {
    static func metrics() throws -> JSONObject {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw AppError.message("Cannot measure own footprint: \(result)") }
        return ["footprintBytes": info.phys_footprint, "peakResidentBytes": usage.ru_maxrss,
            "cpuSeconds": Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000]
    }
    static func main() throws {
        let reader = CodexHistoryReader(), location = CodexThreadLocation(threadID: "fixture", database: CommandLine.arguments[1])
        let before = try metrics(), start = ProcessInfo.processInfo.systemUptime
        func read() throws {
            let questions = try autoreleasepool { try reader.read(location) }
            guard questions.map(\.id) == ["codex:fixture:main:0", "codex:fixture:late:0"],
                  questions[0].hasLaterUserMessage == true, questions[1].hasLaterUserMessage == nil,
                  questions[0].options == ["예", "아니오"] else { throw AppError.message("Synthetic history projection changed") }
        }
        try read()
        let first = try withExtendedLifetime(reader) { try metrics() }
        let firstWall = ProcessInfo.processInfo.systemUptime - start
        for _ in 0..<32 { try read() }
        var report = try withExtendedLifetime(reader) { try metrics() }
        report["firstReadCPUSeconds"] = (first["cpuSeconds"] as! Double) - (before["cpuSeconds"] as! Double)
        report["warmReadsCPUSeconds"] = (report["cpuSeconds"] as! Double) - (first["cpuSeconds"] as! Double)
        report["firstReadWallSeconds"] = firstWall
        report["retainedFootprintBytes"] = Int64(report["footprintBytes"] as! UInt64) - Int64(before["footprintBytes"] as! UInt64)
        report["warmReads"] = 32; report["pendingQuestions"] = 2
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }
}
