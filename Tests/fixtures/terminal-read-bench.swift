import Foundation
import Darwin
import AutoApproveCore

/// Explicit read-only benchmark. The caller provides enrolled TTYs privately;
/// terminal text is kept in memory and never written into the report.
@main struct TerminalReadBench {
    static func cpu(_ who: Int32) -> Double {
        var usage = rusage(); getrusage(who, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    static func main() throws {
        let ttys = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        guard !ttys.isEmpty else { throw AppError.message("No benchmark targets") }
        var samples: [[String: Any]] = []
        for _ in 0..<3 {
            let beforeSelf = cpu(RUSAGE_SELF), beforeChild = cpu(RUSAGE_CHILDREN)
            let before = ProcessInfo.processInfo.systemUptime
            let snapshot = try TerminalAdapter.screens(ttys: ttys, includeCursor: false)
            let elapsed = ProcessInfo.processInfo.systemUptime - before
            guard Set(snapshot.screens.map(\.tty)) == Set(ttys) else { throw AppError.message("A benchmark target disappeared") }
            samples.append(["seconds": elapsed, "selfCPUSeconds": cpu(RUSAGE_SELF) - beforeSelf,
                "childCPUSeconds": cpu(RUSAGE_CHILDREN) - beforeChild, "screens": snapshot.screens.count,
                "bytes": snapshot.screens.reduce(0) { $0 + $1.contents.utf8.count }, "failures": snapshot.failures.count])
        }
        let report: [String: Any] = ["samples": samples, "targets": ttys.count,
            "scope": "Three explicit read-only Terminal snapshots; no input, text logging or polling delay changes. Other live tasks can affect timing."]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }
}
