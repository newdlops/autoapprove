import Foundation
import Darwin
import AutoApproveCore

@main struct ProcessResourceBench {
    static func usage(_ who: Int32) -> Double {
        var value = rusage(); precondition(getrusage(who,&value) == 0)
        return Double(value.ru_utime.tv_sec+value.ru_stime.tv_sec)+Double(value.ru_utime.tv_usec+value.ru_stime.tv_usec)/1e6
    }
    static func main() throws {
        let own = getpid()
        // The full table and recurring session-discovery path are exercised
        // through the real public readers. Warmup is outside timing; source
        // records are never emitted.
        let warm = try ProcessDiscovery.read()
        precondition(warm.contains { $0.pid == own })
        var phases: [[String: Any]] = []
        let workloads: [(String, Int, () throws -> [ProcessRecord])] = [
            ("full-process-table", 12, { try ProcessDiscovery.read() }),
            ("session-discovery", 12, { try ProcessDiscovery.readSessions() }),
            ("single-process", 32, { try ProcessDiscovery.read(pid: own) })
        ]
        for (name, iterations, read) in workloads {
            let selfBegin = usage(RUSAGE_SELF), childBegin = usage(RUSAGE_CHILDREN)
            let begin = ProcessInfo.processInfo.systemUptime
            var recordCount = 0, samples: [Double] = []
            for _ in 0..<iterations {
                let started = ProcessInfo.processInfo.systemUptime
                recordCount += try autoreleasepool {
                    let rows = try read()
                    if name == "full-process-table" || name == "single-process" {
                        precondition(rows.contains { $0.pid == own })
                    }
                    if name == "single-process" { precondition(rows.count == 1) }
                    if name == "session-discovery" {
                        precondition(rows.allSatisfy { $0.pid > 0 && !$0.tty.isEmpty })
                    }
                    return rows.count
                }
                samples.append((ProcessInfo.processInfo.systemUptime-started)*1000)
            }
            let elapsed = ProcessInfo.processInfo.systemUptime-begin
            let selfCPU = usage(RUSAGE_SELF)-selfBegin, childCPU = usage(RUSAGE_CHILDREN)-childBegin
            samples.sort()
            phases.append(["mode":name,"iterations":iterations,"recordCountSum":recordCount,
                "wallSeconds":elapsed,"selfCPUSeconds":selfCPU,"childCPUSeconds":childCPU,
                "combinedCPUSeconds":selfCPU+childCPU,"medianMS":samples[samples.count/2],
                "p95MS":samples[max(0,Int(ceil(Double(samples.count)*0.95))-1)]])
        }
        var resources = rusage(); getrusage(RUSAGE_SELF,&resources)
        let data = try JSONSerialization.data(withJSONObject:["phases":phases,"peakResidentBytes":resources.ru_maxrss],options:[.sortedKeys])
        print(String(decoding:data,as:UTF8.self))
    }
}
