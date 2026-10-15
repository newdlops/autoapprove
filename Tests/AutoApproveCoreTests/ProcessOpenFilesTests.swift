import Foundation
import Darwin
import AutoApproveCore

extension ApprovalTests {
    func testNativeOpenFilesFollowDescriptorChangesAndUnicode() throws {
        // libproc reports the kernel path (/private/...), while Foundation
        // deliberately shortens this machine's temporary /var alias.
        let root = URL(fileURLWithPath:"/private/tmp/aa-open-files-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let first = root.appendingPathComponent("처음 e\u{301} 🙂 with spaces.jsonl"), second = root.appendingPathComponent("다음 파일.jsonl")
        for url in [first,second] { try Data("unread fixture contents".utf8).write(to:url) }
        let start = try ProcessDiscovery.read(pid:getpid()).first!.started
        let opened = try FileHandle(forReadingFrom:first)
        defer { try? opened.close() }
        let paths = try ProcessOpenFiles.paths(pid:getpid(),expectedStart:start)
        try expect(paths.contains(first.path),"Missing synthetic file \(first.path); observed \(paths.filter {$0.contains(root.lastPathComponent)})")
        try expect(!paths.contains(second.path))
        try opened.close()
        let replacement = try FileHandle(forReadingFrom:second)
        defer { try? replacement.close() }
        let current = try ProcessOpenFiles.paths(pid:getpid(),expectedStart:start)
        try expect(!current.contains(first.path),"A closed/reused descriptor cannot retain its previous path")
        try expect(current.contains(second.path))
    }

    func testNativeOpenFilesRejectBoundsChangedIdentityAndCancellation() async throws {
        try expectThrows(try ProcessOpenFiles.paths(pid:0))
        try expectThrows(try ProcessOpenFiles.paths(pid:Int32.max))
        try expectThrows(try ProcessOpenFiles.paths(pid:getpid(),expectedStart:"wrong lifetime"))
        for limit in [0,1,4097] { try expectThrows(try ProcessOpenFiles.paths(pid:getpid(),limit:limit)) }
        for timeout in [0,-1,Double.infinity,4.1] { try expectThrows(try ProcessOpenFiles.paths(pid:getpid(),timeout:timeout)) }
        let cancelled = Task { try ProcessOpenFiles.paths(pid:getpid()) }
        cancelled.cancel()
        do { _ = try await cancelled.value;throw AppError.message("Cancelled file inspection must stop") }
        catch is CancellationError {}
    }
}
