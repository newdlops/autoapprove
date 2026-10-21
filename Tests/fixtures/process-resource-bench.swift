import Foundation
import Darwin
import AutoApproveCore

@main struct ProcessResourceBench {
    static func usage(_ who: Int32) -> Double {
        var value = rusage(); precondition(getrusage(who,&value) == 0)
        return Double(value.ru_utime.tv_sec+value.ru_stime.tv_sec)+Double(value.ru_utime.tv_usec+value.ru_stime.tv_usec)/1e6
    }
    static func checkedCount(_ read: () throws -> [ProcessRecord], mode: String, own: pid_t) throws -> Int {
        try autoreleasepool {
            let rows = try read()
            if mode == "full-process-table" || mode == "single-process" { precondition(rows.contains { $0.pid == own }) }
            if mode == "single-process" { precondition(rows.count == 1) }
            if mode == "session-discovery" { precondition(rows.allSatisfy { $0.pid > 0 && !$0.tty.isEmpty }) }
            return rows.count
        }
    }
    static func main() async throws {
        let own = getpid()
        // The full table and recurring session-discovery path are exercised
        // through the real public readers. Warmup is outside timing; source
        // records are never emitted.
        let warm = try ProcessDiscovery.read()
        precondition(warm.contains { $0.pid == own })
        var phases: [[String: Any]] = []
        let workloads: [(String, Int, @Sendable () throws -> [ProcessRecord])] = [
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
                recordCount += try checkedCount(read,mode:name,own:own)
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
        if CommandLine.arguments.contains("--parallel") {
            for (name, _, read) in workloads {
                let workers = 4, perWorker = 8
                let selfBegin = usage(RUSAGE_SELF), childBegin = usage(RUSAGE_CHILDREN)
                let begin = ProcessInfo.processInfo.systemUptime
                let results = try await withThrowingTaskGroup(of:(Int,[Double]).self) { group in
                    for _ in 0..<workers {
                        group.addTask {
                            var count = 0, samples: [Double] = []
                            for _ in 0..<perWorker {
                                let start = ProcessInfo.processInfo.systemUptime
                                count += try checkedCount(read,mode:name,own:own)
                                samples.append((ProcessInfo.processInfo.systemUptime-start)*1000)
                            }
                            return (count,samples)
                        }
                    }
                    var results: [(Int,[Double])] = []
                    for try await result in group { results.append(result) }
                    return results
                }
                let elapsed = ProcessInfo.processInfo.systemUptime-begin
                let selfCPU = usage(RUSAGE_SELF)-selfBegin, childCPU = usage(RUSAGE_CHILDREN)-childBegin
                let samples = results.flatMap { $0.1 }.sorted()
                phases.append(["mode":"parallel-"+name,"iterations":workers*perWorker,"workers":workers,
                    "recordCountSum":results.reduce(0) { $0+$1.0 },"wallSeconds":elapsed,
                    "selfCPUSeconds":selfCPU,"childCPUSeconds":childCPU,"combinedCPUSeconds":selfCPU+childCPU,
                    "medianMS":samples[samples.count/2],"p95MS":samples[max(0,Int(ceil(Double(samples.count)*0.95))-1)]])
            }
        }
        var resources = rusage(); getrusage(RUSAGE_SELF,&resources)
        let data = try JSONSerialization.data(withJSONObject:["phases":phases,"peakResidentBytes":resources.ru_maxrss,
            "scope":"Real public native readers on the current process table. --parallel adds four workers with eight reads each. No source records, arguments, environment or terminal contents emitted. Not installed-app CPU/memory."],options:[.sortedKeys])
        print(String(decoding:data,as:UTF8.self))
    }
}
