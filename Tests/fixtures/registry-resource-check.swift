import Foundation
import Darwin
import AutoApproveCore

/// Synthetic session/job files only; the real registry reader stays read-only.
@main struct RegistryResourceCheck {
    static func cpu() -> Double {
        var value = rusage(); getrusage(RUSAGE_SELF,&value)
        return Double(value.ru_utime.tv_sec+value.ru_stime.tv_sec)
            + Double(value.ru_utime.tv_usec+value.ru_stime.tv_usec)/1_000_000
    }
    static func main() throws {
        setenv("TZ","Asia/Seoul",1)
        let root = URL(fileURLWithPath:CommandLine.arguments[1])
        let files = FileManager.default
        try files.createDirectory(at:root.appendingPathComponent("sessions"),withIntermediateDirectories:true)
        let utc = DateFormatter(); utc.locale = Locale(identifier:"en_US_POSIX")
        utc.dateFormat = "EEE MMM d HH:mm:ss yyyy"; utc.timeZone = TimeZone(secondsFromGMT:0)
        let local = DateFormatter(); local.locale = Locale(identifier:"en_US_POSIX")
        local.dateFormat = utc.dateFormat; local.timeZone = TimeZone(identifier:"Asia/Seoul")
        let started = utc.date(from:"Sat Sep 19 07:55:12 2026")!
        let changed = started.addingTimeInterval(10)
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        let basic = ISO8601DateFormatter()
        var others: [ProcessRecord] = []
        for index in 0..<1000 { others += ProcessDiscovery.parse("\(index+100) 1 ?? 1 0 Sat Sep 19 07:55:12 2026 /fixture/worker-\(index)") }
        let agents: [ProcessRecord] = (0..<24).map { index in
            let pid = 7000+index
            return ProcessDiscovery.parse("\(pid) 1 ttys\(index+500) \(pid) \(pid) \(local.string(from:started)) /fixture/claude")[0]
        }
        func prepare(blocked: Bool) throws {
            for (index,process) in agents.enumerated() {
                let job = "fixture-\(index)"
                let row: JSONObject = ["pid":process.pid,"pidDomain":"darwin","procStart":utc.string(from:started),
                    "kind":blocked ? "bg" : "interactive","jobId":job,"sessionId":"fixture-session-\(index)",
                    "status":blocked ? "waiting" : "busy","waitingFor":blocked ? "input needed" : "",
                    "statusUpdatedAt":changed.timeIntervalSince1970*1000]
                try JSONSerialization.data(withJSONObject:row).write(to:root.appendingPathComponent("sessions/\(process.pid).json"))
                if blocked {
                    let directory = root.appendingPathComponent("jobs/"+job)
                    try files.createDirectory(at:directory,withIntermediateDirectories:true)
                    let block: JSONObject = ["questions":[["question":"Fixture question \(index)","options":[["label":"A"],["label":"B"]]]]]
                    let row: JSONObject = ["daemonShort":job,"backend":"daemon","state":"working","tempo":"blocked",
                        "resumeSessionId":"fixture-session-\(index)","updatedAt":index.isMultiple(of:2) ? fractional.string(from:changed) : basic.string(from:changed),
                        "block":block]
                    try JSONSerialization.data(withJSONObject:row).write(to:directory.appendingPathComponent("state.json"))
                }
            }
        }
        var workloads: [[String:Any]] = []
        for mode in ["empty","single","interactive","blocked"] {
            try prepare(blocked:mode == "blocked")
            let records = others + (mode == "empty" ? [] : mode == "single" ? [agents[0]] : agents)
            let expected = mode == "empty" ? 0 : mode == "single" ? 1 : 24
            let rounds = mode == "empty" || mode == "single" ? 120 : 60
            func read() -> Int {
                let values = ClaudeSessionRegistry.read(records:records,directory:root)
                precondition(values.count == expected)
                precondition(values.allSatisfy {$0.activity != nil})
                if mode == "blocked" { precondition(values.allSatisfy {$0.activity?.questionSummary?.contains("Fixture question") == true}) }
                return values.count
            }
            _ = read()
            let beforeCPU = cpu(), before = ProcessInfo.processInfo.systemUptime
            var checksum = 0
            for _ in 0..<rounds { checksum += autoreleasepool { read() } }
            workloads.append(["mode":mode,"rounds":rounds,"cpuSeconds":cpu()-beforeCPU,
                "wallSeconds":ProcessInfo.processInfo.systemUptime-before,"checksum":checksum])
        }
        print(String(decoding:try JSONSerialization.data(withJSONObject:["workloads":workloads,"sessions":24,
            "otherProcesses":1000,"inputPosts":0],options:[.sortedKeys]),as:UTF8.self))
    }
}
