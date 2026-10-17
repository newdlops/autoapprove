import Foundation
import AutoApproveCore

@main struct ProcessAncestryCheck {
    enum Failure: Error { case read }
    static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data("Ancestry check failed: \(error)\n".utf8)); exit(1) }
    }
    static func run() throws {
        var checked: [String] = []
        func check(_ name: String, _ condition: Bool) throws {
            guard condition else { throw AppError.message(name) }; checked.append(name)
        }
        func record(_ pid: Int32, _ parent: Int32, _ executable: String) -> ProcessRecord {
            ProcessDiscovery.parse("\(pid) \(parent) ttys099 500 500 Mon Sep 21 09:00:00 2026 \(executable)")[0]
        }
        let child = record(10, 20, "/fixture/node"), nearest = record(20, 30, "/fixture/claude"), outer = record(30, 0, "/fixture/codex")
        let graph: [Int32: ProcessRecord] = [10: child, 20: nearest, 30: outer]
        var calls: [Int32] = []
        let actual = try ProcessDiscovery.enclosingAgent(of: 10) { pid in calls.append(pid); return graph[pid].map { [$0] } ?? [] }
        let legacy = ProcessDiscovery.ancestors(of: 10, records: Array(graph.values)).first { $0.agent != nil }
        try check("nearest agrees with legacy", actual == legacy)
        try check("only selected chain and reverse verification", calls == [10,20,20,10])
        try check("starting CLI included", try ProcessDiscovery.enclosingAgent(of: 20) { graph[$0].map { [$0] } ?? [] } == nearest)
        var invalidCalls = 0
        for pid in [Int32(0),Int32(-1)] {
            try check("invalid PID \(pid)", try ProcessDiscovery.enclosingAgent(of: pid) { _ in invalidCalls += 1; return [] } == nil)
        }
        try check("invalid IDs never read", invalidCalls == 0)
        try check("missing process", try ProcessDiscovery.enclosingAgent(of: 10) { _ in [] } == nil)
        try check("ambiguous process", try ProcessDiscovery.enclosingAgent(of: 10) { _ in [child,child] } == nil)
        try check("wrong returned PID", try ProcessDiscovery.enclosingAgent(of: 10) { _ in [nearest] } == nil)
        for mutation in ["parent", "start", "exec", "TTY", "missing", "duplicate"] {
            var counts: [Int32: Int] = [:]
            let result = try ProcessDiscovery.enclosingAgent(of: 10) { pid in
                counts[pid,default:0] += 1
                guard var value = graph[pid] else { return [] }
                if counts[pid] == 2 {
                    if mutation == "parent" { value.parent += 1 }
                    if mutation == "start" { value.started += " changed" }
                    if mutation == "exec" { value.executable += "-changed" }
                    if mutation == "TTY" { value.tty = "ttys098" }
                    if mutation == "missing" { return [] }
                    if mutation == "duplicate" { return [value,value] }
                }
                return [value]
            }
            try check("changed \(mutation) rejected", result == nil)
        }
        var counts: [Int32: Int] = [:]
        let foreground = try ProcessDiscovery.enclosingAgent(of: 10) { pid in
            counts[pid,default:0] += 1; guard var value = graph[pid] else { return [] }
            if counts[pid] == 2 { value.foregroundGroup += 1 }; return [value]
        }
        try check("foreground change grants no new identity", foreground?.key == nearest.key)
        counts = [:]
        let changedChild = try ProcessDiscovery.enclosingAgent(of: 10) { pid in
            counts[pid,default:0] += 1; guard var value = graph[pid] else { return [] }
            if pid == 10 && counts[pid] == 2 { value.parent = 99 }; return [value]
        }
        try check("child reparented after parent verification rejected", changedChild == nil)
        let cycle = [Int32(10): record(10,20,"/fixture/node"),20:record(20,10,"/fixture/sh")]
        try check("cycle bounded", try ProcessDiscovery.enclosingAgent(of: 10) { cycle[$0].map { [$0] } ?? [] } == nil)
        var depthCalls = 0
        let deep = try ProcessDiscovery.enclosingAgent(of: 1) { pid in
            depthCalls += 1; return [record(pid,pid+1,pid == 61 ? "/fixture/codex" : "/fixture/sh")]
        }
        try check("sixty ancestors maximum", deep == nil && depthCalls == 60)
        var errorPropagated = false
        do { _ = try ProcessDiscovery.enclosingAgent(of: 10) { _ in throw Failure.read } }
        catch Failure.read { errorPropagated = true }
        try check("reader error propagated", errorPropagated)
        var replaced = graph
        replaced[20]?.started += " new lifetime"
        let fresh = try ProcessDiscovery.enclosingAgent(of: 10) { replaced[$0].map { [$0] } ?? [] }
        try check("no identity cache across calls", fresh?.key == replaced[20]?.key && fresh?.key != nearest.key)
        let chatGPT = [Int32(10):child,20:record(20,30,"/Applications/ChatGPT.app/Contents/MacOS/codex"),30:outer]
        try check("ChatGPT process exclusion preserved", try ProcessDiscovery.enclosingAgent(of: 10) { chatGPT[$0].map { [$0] } ?? [] }?.pid == 30)
        var report: [String: Any] = ["passed":checked.count,"checked":checked,"inputPosts":0,
            "scope":"Synthetic parent graph and fresh-reader changes; no original input"]
        if let option = CommandLine.arguments.first(where: { $0.hasPrefix("--parent=") }), let pid = Int32(option.dropFirst(9)), pid > 0 {
            let reference = try ProcessDiscovery.ancestors(of: pid, records: ProcessDiscovery.read()).first { $0.agent != nil }
            let current = try ProcessDiscovery.enclosingAgent(of: pid)
            guard current?.key == reference?.key else { throw AppError.message("Live parent differs from the full-table reference") }
            report["liveParentVerified"] = true
            report["referenceSessionID"] = reference.map { $0.key as Any } ?? NSNull()
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: report,options:[.sortedKeys]),as:UTF8.self))
    }
}
