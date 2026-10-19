import Foundation
import Darwin
import TerminalInputSupport
#if DEBUG
@testable import AutoApproveCore
#else
import AutoApproveCore
#endif

extension ApprovalTests {
#if DEBUG
    func testDescriptorPathReaderSkipsOnlyTransientFDPathErrors() throws {
        for code in [EBADF, ENOENT, ESTALE] {
            try expect(ProcessOpenFiles.isTransientDescriptorPathError(code), "A closed or stale network descriptor should not abort unrelated path reads")
        }
        for code in [EIO, EPERM, EACCES] {
            try expect(!ProcessOpenFiles.isTransientDescriptorPathError(code), "Unexpected/systematic descriptor errors must remain visible")
        }
    }
#endif

    func testNativeOpenFilesFollowDescriptorChangesAndUnicode() throws {
        // libproc reports the kernel path (/private/...), while Foundation
        // deliberately shortens this machine's temporary /var alias.
        let root = URL(fileURLWithPath:"/private/tmp/aa-open-files-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let first = root.appendingPathComponent("처음 e\u{301} 🙂 with spaces.jsonl"), second = root.appendingPathComponent("다음 파일.jsonl")
        for url in [first,second] { try Data("unread fixture contents".utf8).write(to:url) }
        let start = try TTYInputIdentity.capture(pid:getpid()).processStart
        let opened = try FileHandle(forReadingFrom:first)
        defer { try? opened.close() }
        let paths = try ProcessOpenFiles.paths(pid:getpid(),expectedStart:start)
        try expectEqual(paths.count, Set(paths).count, "Descriptor aliases are de-duplicated even though result order is unspecified")
        try expect(paths.contains(first.path),"Missing synthetic file \(first.path); observed \(paths.filter {$0.contains(root.lastPathComponent)})")
        try expect(!paths.contains(second.path))
        try opened.close()
        let replacement = try FileHandle(forReadingFrom:second)
        defer { try? replacement.close() }
        let current = try ProcessOpenFiles.paths(pid:getpid(),expectedStart:start)
        try expect(!current.contains(first.path),"A closed/reused descriptor cannot retain its previous path")
        try expect(current.contains(second.path))
    }

    func testCodexOpenFileReadersAllocateOnlyRequiredPaths() throws {
        let root = URL(fileURLWithPath:"/private/tmp/aa-open-codex-files-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let unrelated = root.appendingPathComponent("large-unrelated-log.txt")
        let rollout = root.appendingPathComponent("rollout-current.jsonl")
        let history = root.appendingPathComponent("thread_history_1.sqlite")
        for url in [unrelated, rollout, history] { try Data("synthetic".utf8).write(to:url) }
        let handles = try [unrelated, rollout, history].map { try FileHandle(forReadingFrom:$0) }
        defer { for handle in handles { try? handle.close() } }
        let start = try ProcessDiscovery.read(pid:getpid()).first!.started
        let rollouts = try ProcessOpenFiles.codexRolloutPaths(pid:getpid(),expectedStart:start)
        try expectEqual(rollouts, [rollout.path], "History polling keeps only open rollout logs")
        let metadata = try ProcessOpenFiles.codexMetadataPaths(pid:getpid(),expectedStart:start)
        try expectEqual(Set(metadata), Set([rollout.path,history.path]), "Codex reply routing keeps only rollout and known database paths")
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
