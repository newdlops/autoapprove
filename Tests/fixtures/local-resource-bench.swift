import Foundation
import Darwin
import AutoApproveCore

/// Only synthetic local peers and Git metadata; never reads a user's terminal.
@main struct LocalResourceBench {
    static func metrics() -> JSONObject {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        if task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads {
            for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, threads[index]) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        return ["cpuSeconds": Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000,
            "peakResidentBytes": usage.ru_maxrss, "threads": count]
    }
    static func main() throws {
        let directory = CommandLine.arguments[1]
        if CommandLine.arguments.contains("--git") {
            let repository = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: repository.appendingPathComponent(".git/refs/heads"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: repository.appendingPathComponent(".git/objects"), withIntermediateDirectories: true)
            try Data("ref: refs/heads/main\n".utf8).write(to: repository.appendingPathComponent(".git/HEAD"))
            try Data("[core]\nrepositoryformatversion = 0\n".utf8).write(to: repository.appendingPathComponent(".git/config"))
            try Data((String(repeating: "a", count: 40) + "\n").utf8).write(to: repository.appendingPathComponent(".git/refs/heads/main"))
            var launches = 0
            func read() -> GitBranchState {
                GitBranchReader.read(directory: directory) { arguments, environment in
                    launches += 1
                    return try CommandRunner.run("/usr/bin/git", arguments, environment: environment, inheritEnvironment: false)
                }
            }
            guard read().name == "main" else { throw AppError.message("Fixture branch failed") }
            let before = metrics(), start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<2_000 {
                guard read().name == "main" else { throw AppError.message("Fixture cache failed") }
            }
            var report = metrics()
            report["cpuSeconds"] = (report["cpuSeconds"] as! Double) - (before["cpuSeconds"] as! Double)
            report["wallSeconds"] = ProcessInfo.processInfo.systemUptime - start
            report["reads"] = 2_000; report["gitLaunches"] = launches
            print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
            return
        }
        let server = SocketServer(path: directory + "/bridge.sock", handler: { message, peer in
            if message["method"] as? String == "metrics" { peer.send(["id": message["id"] ?? "", "result": metrics()]) }
            else { peer.send(message) }
        }, disconnected: { _ in })
        try server.start(); defer { server.stop() }
        print("READY"); fflush(stdout)
        _ = readLine()
    }
}
