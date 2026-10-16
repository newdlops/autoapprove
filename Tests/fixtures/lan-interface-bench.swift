import Foundation
import Darwin
import AutoApproveCore

@main struct LANInterfaceBench {
    static func cpu() -> Double {
        var value = rusage(); precondition(getrusage(RUSAGE_SELF, &value) == 0)
        return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1e6
    }
    static func main() throws {
        _ = RemoteLAN.interfaces(refresh: true)
        var samples: [[String: Any]] = []
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 1.05)
            let before = cpu(), start = ProcessInfo.processInfo.systemUptime
            let value = RemoteLAN.interfaces()
            let wall = ProcessInfo.processInfo.systemUptime - start, used = cpu() - before
            // A forced inventory must still agree with the ordinary fresh IP
            // read. Do not log addresses, device names, MACs or interface IDs.
            let fresh = RemoteLAN.interfaces(refresh: true)
            precondition(value == fresh, "Network changed during the comparison")
            samples.append(["cpuSeconds": used, "wallSeconds": wall, "interfaces": value.count,
                "wifi": value.filter { $0.kind == .wifi }.count, "forcedReadMatches": true])
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["samples": samples,
            "scope": "Actual current physical interfaces; 12 reads past the 1s IP cache, each checked against a forced full refresh. No address logging, network configuration changes, requests or terminal input."], options: [.sortedKeys]), as: UTF8.self))
    }
}
