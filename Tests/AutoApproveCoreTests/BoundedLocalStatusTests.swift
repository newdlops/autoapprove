import Foundation
import Darwin
import AutoApproveCore

private func statusFixtureDirectory() throws -> URL {
    let value=FileManager.default.temporaryDirectory.appendingPathComponent("aa-bounded-status-"+UUID().uuidString,isDirectory:true)
    try FileManager.default.createDirectory(at:value,withIntermediateDirectories:true)
    return value
}

extension ApprovalTests {
    func testBoundedLocalStatusPreservesTextAndUnicode() throws {
        let directory=try statusFixtureDirectory();defer{try? FileManager.default.removeItem(at:directory)}
        try expectEqual(LocalDashboardAddress.maximumStatusBytes,1_048_576)
        let file=directory.appendingPathComponent("한글 e\u{301} #+%.txt",isDirectory:false)
        let lines=["", "# 한글 e\u{301} 🙂", "127.0.0.1 localhost", "127.0.0.1 autoapprove", "::1 AUTOAPPROVE.",
            "192.168.0.4 autoapprove", "127.0.0.1 autoapprove-other .autoapprove", "127.0.0.1\tautoapprove # 설명",
            "\u{feff}127.0.0.1 autoapprove", "127.0.0.1 AUTOAPPROVE..", "127.0.0.1 \u{00a0}autoapprove"]
        for newline in ["\n","\r","\r\n","\u{0085}","\u{000b}","\u{000c}","\u{2028}","\u{2029}"] {
            for text in lines+[lines.joined(separator:newline)] {
                let bytes=Data((text+newline).utf8);try bytes.write(to:file)
                let result=LocalDashboardAddress.readStatus(file:file)
                try expectEqual(result.status,LocalDashboardAddress.status(in:String(data:bytes,encoding:.utf8)!),
                    "File decoding, including UTF-8 BOM, must retain the released text semantics")
                try expectEqual(result.bytesRead,bytes.count)
            }
        }
        try Data([0xff,0xfe,0x80]).write(to:file)
        let invalid=LocalDashboardAddress.readStatus(file:file)
        try expectEqual(invalid.status,.unavailable);try expectEqual(invalid.bytesRead,3)
    }

    func testBoundedLocalStatusRejectsBeforeReadingLargeFilesAndKeepsExactLimit() throws {
        let directory=try statusFixtureDirectory();defer{try? FileManager.default.removeItem(at:directory)}
        let file=directory.appendingPathComponent("sizes.txt",isDirectory:false)
        let limit=1_048_576
        for size in [0,limit-1,limit] {
            let bytes=Data((size==0 ? "" : "#"+String(repeating:"x",count:size-1)).utf8)
            try bytes.write(to:file)
            let result=LocalDashboardAddress.readStatus(file:file)
            try expectEqual(result.status,.missing);try expectEqual(result.bytesRead,size)
        }
        let fd=Darwin.open(file.path,O_WRONLY | O_CLOEXEC);try expect(fd>=0);defer{_ = Darwin.close(fd)}
        for size in [limit+1,33_554_432] {
            try expectEqual(ftruncate(fd,off_t(size)),0)
            let result=LocalDashboardAddress.readStatus(file:file)
            try expectEqual(result.status,.unavailable);try expectEqual(result.bytesRead,0,"Oversized files are rejected before allocating or reading their contents")
        }
    }

    func testBoundedLocalStatusFreshRewritesSymlinksAndFailures() throws {
        let directory=try statusFixtureDirectory();defer{try? FileManager.default.removeItem(at:directory)}
        let file=directory.appendingPathComponent("current.txt",isDirectory:false),link=directory.appendingPathComponent("linked.txt",isDirectory:false)
        try Data("127.0.0.1 autoapprove\n".utf8).write(to:file)
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:file)
        for text in ["127.0.0.1 autoapprove\n","10.0.0.9 autoapprove\n","127.0.0.1 localhost\n","::1 AUTOAPPROVE.\n"] {
            try Data(text.utf8).write(to:file,options:.atomic)
            let result=LocalDashboardAddress.readStatus(file:link)
            try expectEqual(result.status,LocalDashboardAddress.status(in:text));try expectEqual(result.bytesRead,text.utf8.count)
        }
        try FileManager.default.removeItem(at:file)
        try expectEqual(LocalDashboardAddress.readStatus(file:link).status,.unavailable)
        try expectEqual(LocalDashboardAddress.readStatus(file:directory).bytesRead,0)
        try expectEqual(LocalDashboardAddress.readStatus(file:directory).status,.unavailable)
        let fifo=directory.appendingPathComponent("pipe",isDirectory:false)
        try expectEqual(mkfifo(fifo.path,0o600),0)
        let started=ProcessInfo.processInfo.systemUptime,result=LocalDashboardAddress.readStatus(file:fifo)
        try expectEqual(result.status,.unavailable);try expectEqual(result.bytesRead,0)
        try expect(ProcessInfo.processInfo.systemUptime-started<1,"A substituted FIFO must not wait for another process")
        let remote=LocalDashboardAddress.readStatus(file:URL(string:"https://127.0.0.1:9/no-network-request")!)
        try expectEqual(remote.status,.unavailable);try expectEqual(remote.bytesRead,0)
    }

    func testBoundedLocalStatusConcurrentGrowthKeepsReadBudgetAndNoCache() async throws {
        let directory=try statusFixtureDirectory();defer{try? FileManager.default.removeItem(at:directory)}
        let file=directory.appendingPathComponent("growing.txt",isDirectory:false)
        try Data("127.0.0.1 autoapprove\n".utf8).write(to:file)
        let writer=Task.detached {
            let fd=Darwin.open(file.path,O_WRONLY | O_CLOEXEC)
            guard fd>=0 else {throw AppError.message("Owned status writer failed to open")};defer{_ = Darwin.close(fd)}
            let text=Data("127.0.0.1 autoapprove\n".utf8)
            for _ in 0..<64 {
                try Task.checkCancellation()
                guard ftruncate(fd,0)==0,lseek(fd,0,SEEK_SET)==0 else {throw AppError.message("Owned status writer failed to truncate")}
                let count=text.withUnsafeBytes { Darwin.write(fd,$0.baseAddress,$0.count) }
                guard count==text.count,ftruncate(fd,33_554_432)==0 else {throw AppError.message("Owned status writer failed to grow")}
                try await Task.sleep(for:.milliseconds(1))
            }
        }
        do {
            for _ in 0..<256 {
                let result=LocalDashboardAddress.readStatus(file:file)
                try expect((0...1_048_577).contains(result.bytesRead),"Even a changing file shares one fixed byte allowance")
                await Task.yield()
            }
            try await writer.value
        } catch {writer.cancel();_ = try? await writer.value;throw error}
        let oversized=LocalDashboardAddress.readStatus(file:file)
        try expectEqual(oversized.status,.unavailable);try expectEqual(oversized.bytesRead,0)
        try Data("::1 autoapprove\n".utf8).write(to:file,options:.atomic)
        try expectEqual(LocalDashboardAddress.readStatus(file:file).status,.ready,"A later valid file is read afresh")
    }

    func testBoundedLocalStatusClosesDescriptorsOnEveryExit() throws {
        let directory=try statusFixtureDirectory();defer{try? FileManager.default.removeItem(at:directory)}
        let valid=directory.appendingPathComponent("valid.txt"),invalid=directory.appendingPathComponent("invalid.txt"),large=directory.appendingPathComponent("large.txt")
        try Data("127.0.0.1 autoapprove\n".utf8).write(to:valid);try Data([0xff]).write(to:invalid)
        try Data().write(to:large)
        let fd=Darwin.open(large.path,O_WRONLY | O_CLOEXEC);try expect(fd>=0)
        let truncated=ftruncate(fd,33_554_432);_ = Darwin.close(fd);try expectEqual(truncated,0)
        let before=try FileManager.default.contentsOfDirectory(atPath:"/dev/fd").count
        for _ in 0..<128 {for file in [valid,invalid,large,directory] {_ = LocalDashboardAddress.readStatus(file:file)}}
        let after=try FileManager.default.contentsOfDirectory(atPath:"/dev/fd").count
        try expect(after<=before+1,"Repeated success and failure must close every owned descriptor")
    }
}
