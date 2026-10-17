import Foundation
import Darwin
import AutoApproveCore

/// Synthetic path labels only; no original processes, engine or terminal input.
@main struct ProjectLabelBench {
    @inline(never) static func old(_ path: String) -> String {
        path.isEmpty ? "프로젝트 확인 중" : URL(fileURLWithPath: path).lastPathComponent
    }
    @inline(never) static func hinted(_ path: String) -> String {
        path.isEmpty ? "프로젝트 확인 중" : URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
    }
    @inline(never) static func lexical(_ path: String) -> String {
        if path.isEmpty { return "프로젝트 확인 중" }
        let leaf: String? = path.utf8.withContiguousStorageIfAvailable { bytes -> String? in
            guard bytes.first == 47, bytes.allSatisfy({ $0 > 0 && $0 < 128 }) else { return nil }
            var end = bytes.count
            while end > 0 && bytes[end - 1] == 47 { end -= 1 }
            if end == 0 { return "/" }
            var start = end
            while start > 0 && bytes[start - 1] != 47 { start -= 1 }
            let name = String(decoding: bytes[start..<end], as: UTF8.self)
            return name == "." || name == ".." ? nil : name
        } ?? nil
        if let leaf { return leaf }
        return URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
    }
    static func cpu() -> Double {
        var r = rusage(); getrusage(RUSAGE_SELF, &r)
        return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1_000_000
    }
    static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data("Project label check failed: \(error)\n".utf8)); exit(1) }
    }
    static func run() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fm = FileManager.default
        let directory = root.appendingPathComponent("한글 project 🚀", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("ordinary-file.txt")
        try Data("fixture".utf8).write(to: file)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("directory-link").path, withDestinationPath: directory.path)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("file-link").path, withDestinationPath: file.path)
        var paths: [String] = ["", "/", "//", "///", ".", "..", "./", "../", "relative", "relative/child/", "~/project",
            "/a//b/", "/a/./b", "/a/../b", "/tmp/percent%20name", "/tmp/한글🚀", "/tmp/cafe\u{301}",
            directory.path, directory.path + "/", file.path, root.appendingPathComponent("directory-link").path,
            root.appendingPathComponent("file-link").path, root.appendingPathComponent("missing").path,
            directory.path + "/.", directory.path + "/..", "/tmp/trailing ", "/tmp/#?%", "/tmp/back\\slash"]
        for i in 0..<24 { paths.append(root.appendingPathComponent("missing-project-\(i)", isDirectory: true).path) }
        var session = AgentSession(id: "synthetic", agent: .codex, pid: 900_000, started: "synthetic", tty: "/dev/ttys099", cwd: "", terminal: .terminal)
        var parityPaths = paths
        parityPaths += [file.path + "/.", file.path + "/..", root.appendingPathComponent("file-link").path + "/.",
            root.appendingPathComponent("file-link").path + "/..", directory.path + "/./", directory.path + "/../"]
        let components = ["", ".", "..", "ordinary", "한글🚀", "cafe\u{301}", "#?%20", "back\\slash", "line\nfeed", "null\0byte"]
        for left in components { for right in components { for ending in ["", "/", "//"] {
            parityPaths.append("/fixture/" + left + "/" + right + ending)
        } } }
        for path in parityPaths {
            guard old(path).utf8.elementsEqual(hinted(path).utf8) else { throw AppError.message("Directory hint changed a synthetic label") }
            guard old(path).utf8.elementsEqual(lexical(path).utf8) else { throw AppError.message("Lexical label differs at synthetic path: \(String(reflecting: path))") }
            session.cwd = path
            guard session.project.utf8.elementsEqual(old(path).utf8), AuditContext(session: session).project.utf8.elementsEqual((path.isEmpty ? "프로젝트 미확인" : old(path)).utf8) else {
                throw AppError.message("Production project label changed")
            }
        }
        let rounds = 20_000
        var reports: [[String: Any]] = []
        func measure(_ name: String, _ operation: (String) -> String) {
            let startCPU = cpu(), began = ProcessInfo.processInfo.systemUptime
            var checksum = 0
            for i in 0..<rounds { checksum &+= operation(paths[i % paths.count]).utf8.count }
            reports.append(["name": name, "rounds": rounds, "cpuSeconds": cpu() - startCPU,
                "wallSeconds": ProcessInfo.processInfo.systemUptime - began, "checksum": checksum])
        }
        measure("legacy", old); measure("directory-hint", hinted); measure("lexical", lexical)
        measure("production-session") { value in session.cwd = value; return session.project }
        measure("production-audit") { value in session.cwd = value; return AuditContext(session: session).project }
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["pathsChecked": parityPaths.count,
            "workloads": reports, "inputPosts": 0], options: [.sortedKeys]), as: UTF8.self))
    }
}
