import Foundation
import Darwin
import AutoApproveCore

@main struct OpenFilesBench {
    static func cpu(_ who: Int32) -> Double {
        var usage = rusage();getrusage(who,&usage)
        return Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)+Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1_000_000
    }
    static func legacy(_ pids: [Int32]) throws -> [Int32:[String]] {
        let result = try CommandRunner.run("/usr/sbin/lsof",["-nP","-a","-p",pids.map(String.init).joined(separator:","),"-Fpn"],timeout:4)
        guard result.status == 0 || !result.output.isEmpty else { throw AppError.message("Legacy file query failed") }
        return CodexThreadLocation.openFiles(result.output)
    }
    static func main() throws {
        if CommandLine.arguments.contains("--live") { try live();return }
        let root = URL(fileURLWithPath:"/private/tmp/aa-open-files-bench-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        var handles = [FileHandle](),expected = Set<String>()
        defer { for handle in handles { try? handle.close() } }
        for index in 0..<100 {
            let url = root.appendingPathComponent("fixture-\(index).txt")
            try Data("Synthetic unconsumed contents".utf8).write(to:url)
            handles.append(try FileHandle(forReadingFrom:url));expected.insert(url.path)
        }
        let day = root.appendingPathComponent("sessions/2026/10/15")
        try FileManager.default.createDirectory(at:day,withIntermediateDirectories:true)
        let rollout = day.appendingPathComponent("rollout-fixture.jsonl")
        var header = try JSONSerialization.data(withJSONObject:["type":"session_meta","payload":["source":"cli","id":"fixture-root"]]);header.append(10)
        try header.write(to:rollout);handles.append(try FileHandle(forReadingFrom:rollout));expected.insert(rollout.path)
        let expectedLocation = CodexThreadLocation(threadID:"fixture-root",database:root.appendingPathComponent("thread_history_1.sqlite").path)
        let start = try ProcessDiscovery.read(pid:getpid()).first!.started
        var samples = [[String:Any]]()
        for round in 0..<6 {
            for native in round.isMultiple(of:2) ? [false,true] : [true,false] {
                let own = cpu(RUSAGE_SELF),children = cpu(RUSAGE_CHILDREN),started = ProcessInfo.processInfo.systemUptime
                let paths = native ? try ProcessOpenFiles.paths(pid:getpid(),expectedStart:start) : try legacy([getpid()])[getpid()] ?? []
                let wall = ProcessInfo.processInfo.systemUptime-started,ownCPU = cpu(RUSAGE_SELF)-own,childCPU = cpu(RUSAGE_CHILDREN)-children
                guard expected.isSubset(of:Set(paths)),try CodexThreadLocation.locate(paths:paths) == expectedLocation else { throw AppError.message("Live descriptor/root rollout mismatch") }
                samples.append(["mode":native ? "native" : "legacy","round":round,"wallMS":wall*1000,"selfCPUSeconds":ownCPU,"childCPUSeconds":childCPU,"commandLaunches":native ? 0 : 1])
            }
        }
        print(String(decoding:try JSONSerialization.data(withJSONObject:["files":expected.count,"samples":samples,"scope":"Same isolated process with 101 open synthetic files; six alternating reads per path; no file contents consumed by the metadata reader and no user terminal"],options:[.sortedKeys]),as:UTF8.self))
    }
    static func live() throws {
        let targets = ProcessDiscovery.sessions(try ProcessDiscovery.read()).filter {$0.agent == .codex}
        let previous = try legacy(targets.map(\.pid))
        var nativeOK = 0,bothBound = 0,bothUnbound = 0,mismatches = 0,failures = 0
        for target in targets {
            do {
                let paths = try ProcessOpenFiles.paths(pid:target.pid,expectedStart:target.started)
                nativeOK += 1
                let old = try? CodexThreadLocation.locate(paths:previous[target.pid] ?? []),new = try? CodexThreadLocation.locate(paths:paths)
                if old == new { if old == nil {bothUnbound += 1}else{bothBound += 1} }
                else {mismatches += 1}
            } catch {failures += 1}
        }
        guard mismatches == 0,failures == 0 else { throw AppError.message("Live metadata mismatch count \(mismatches), read failure count \(failures)") }
        print(String(decoding:try JSONSerialization.data(withJSONObject:["liveProcesses":targets.count,"nativeReads":nativeOK,"sameBoundConversation":bothBound,"sameUnavailableConversation":bothUnbound,"mismatches":mismatches,"failures":failures,"scope":"Read-only live metadata and root header comparison; no paths, PID, thread IDs, questions or terminal text recorded"],options:[.sortedKeys]),as:UTF8.self))
    }
}
