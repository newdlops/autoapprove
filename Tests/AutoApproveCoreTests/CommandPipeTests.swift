import Foundation
import Darwin
import AutoApproveCore

private enum CommandPipeFixture {
    static let shared: Result<URL,Error> = Result {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-command-pipe-tests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let source=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/command-pipe-fixture.c")
        let binary=root.appendingPathComponent("fixture"),log=root.appendingPathComponent("compiler.log")
        _ = FileManager.default.createFile(atPath:log.path,contents:nil)
        let handle=try FileHandle(forWritingTo:log);defer {try? handle.close()}
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/xcrun")
        process.arguments=["clang","-O2","-Wall","-Wextra","-Werror",source.path,"-o",binary.path]
        process.standardOutput=handle;process.standardError=handle
        let done=DispatchSemaphore(value:0);process.terminationHandler={_ in done.signal()};try process.run()
        guard done.wait(timeout:.now()+30) == .success else {if process.isRunning {process.terminate()};throw AppError.message("Owned pipe fixture compile timeout")}
        guard process.terminationStatus==0 else {throw AppError.message(try String(contentsOf:log,encoding:.utf8))}
        return binary
    }
    static func root() throws -> URL {
        let root=try shared.get().deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);return root
    }
    static func run(_ arguments:[String],input:Data?=nil,timeout:Double=5,output:Int=CommandRunner.maximumOutputBytes,error:Int=CommandRunner.maximumErrorBytes) throws -> CommandResult {
        try CommandRunner.run(shared.get().path,arguments,timeout:timeout,input:input,outputLimit:output,errorLimit:error)
    }
    static func environmentBytes(_ value: String) throws -> [UInt8] {
        // Foundation may decompose environment strings just like arguments.
        // Compare its actual child bytes instead of imposing a new NFC policy.
        let process=Process(),pipe=Pipe();process.executableURL=try shared.get()
        process.arguments=["environment"];process.environment=["AUTOAPPROVE_PIPE_FIXTURE":value];process.standardOutput=pipe
        try process.run();let bytes=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
        guard process.terminationStatus==0 else {throw AppError.message("Owned environment oracle failed")}
        return Array(bytes)
    }
}

extension ApprovalTests {
    func testCommandPipesPreserveBytesStatusAndEnvironment() throws {
        let result=try CommandPipeFixture.run(["bytes","262144","131072","7"])
        try expectEqual(result.status,7);try expectEqual(result.output.utf8.count,262144);try expectEqual(result.error.utf8.count,131072)
        try expect(result.output.utf8.allSatisfy{$0==97}&&result.error.utf8.allSatisfy{$0==101})
        let helper=try CommandPipeFixture.shared.get().path
        let environment=try CommandRunner.run(helper,["environment"],environment:["AUTOAPPROVE_PIPE_FIXTURE":"한글 e\u{301} 🧪"],inheritEnvironment:false)
        try expectEqual(Array(environment.output.utf8),try CommandPipeFixture.environmentBytes("한글 e\u{301} 🧪"))
        let inherited=try CommandRunner.run(helper,["environment"],environment:["AUTOAPPROVE_PIPE_FIXTURE":"explicit-value"])
        try expectEqual(inherited.output,"explicit-value")
        let empty=try CommandPipeFixture.run(["empty"],input:Data());try expectEqual(empty.status,0)
        // A child may exit without consuming stdin. EPIPE must not kill the app.
        try expectEqual(try CommandPipeFixture.run(["empty"],input:Data(repeating:97,count:2_097_152)).status,0)
    }

    func testCommandPipesRepairUTF8AcrossBoundaries() throws {
        let patterns:[[UInt8]]=[[0xc2,0xa2],[0xe1,0x84,0x80],[0xf0,0x9f,0xa7,0xaa],
            [0x65,0xcc,0x81],[0xef,0xbb,0xbf],[0],[0xc0,0xaf],[0xed,0xa0,0x80],
            [0xf4,0x90,0x80,0x80],[0xff,0x80,0xc2],[0xe0,0x80],[0xf0,0x90,0x80]]
        var data=Data()
        for pattern in patterns {for offset in -4...4 {
            let boundary=((data.count/16384)+1)*16384+offset
            if boundary>data.count {data.append(Data(repeating:97,count:boundary-data.count))}
            data.append(contentsOf:pattern)
        }}
        data.append(contentsOf:[0xf0,0x90,0x80])
        let expected=Array(String(decoding:data,as:UTF8.self).utf8)
        for mode in ["echo","echo-error"] {
            let result=try CommandPipeFixture.run([mode],input:data)
            try expectEqual(Array((mode=="echo" ? result.output:result.error).utf8),expected,"Chunk decoding must match the independent complete standard decoder")
            try expectEqual(result.status,0)
        }
    }

    func testCommandPipesLimitsNeverReturnPartialSuccess() throws {
        let exact=try CommandPipeFixture.run(["bytes","8192","4096","7"],output:8192,error:4096)
        try expectEqual(exact.status,7);try expectEqual(exact.output.utf8.count,8192);try expectEqual(exact.error.utf8.count,4096)
        try expectEqual(try CommandPipeFixture.run(["empty"],output:0,error:0).status,0)
        try expectThrows(try CommandPipeFixture.run(["bytes","1","0"],output:0))
        try expectThrows(try CommandPipeFixture.run(["bytes","0","8193"],error:8192))
        try expectThrows(try CommandPipeFixture.run(["echo"],input:Data(repeating:0xff,count:128),output:383))
        let root=try CommandPipeFixture.root();defer {try? FileManager.default.removeItem(at:root)}
        let receipt=root.appendingPathComponent("once")
        try expectThrows(try CommandPipeFixture.run(["once",receipt.path,"262144"],output:4096))
        try expectEqual(try String(contentsOf:receipt,encoding:.utf8).split(separator:"\n").count,1,"A failed/unknown write is never replayed by the runner")
        let absent=root.appendingPathComponent("invalid")
        try expectThrows(try CommandPipeFixture.run(["once",absent.path,"1"],output:CommandRunner.maximumOutputBytes+1))
        try expectFalse(FileManager.default.fileExists(atPath:absent.path),"Invalid budgets fail before launching a helper")
    }

    func testCommandPipesDeadlineIncludesInheritedDescriptors() throws {
        let root=try CommandPipeFixture.root();defer {try? FileManager.default.removeItem(at:root)}
        for mode in ["hold","hold-input"] {
            let file=root.appendingPathComponent(mode+".pid"),start=ProcessInfo.processInfo.systemUptime
            try expectThrows(try CommandPipeFixture.run([mode,file.path],input:mode=="hold-input" ? Data(repeating:97,count:2_097_152):nil,timeout:1))
            try expect(ProcessInfo.processInfo.systemUptime-start<1.5,"Inherited stdin/stdout cannot outlive the command budget")
            let pid=try String(contentsOf:file,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)
            try expect(Int32(pid) != nil,"The owned parent really ran and forked the bounded descendant")
        }
    }

    func testCommandPipesTimeoutRetiresOnlyOwnedHelper() throws {
        let root=try CommandPipeFixture.root();defer {try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("helper.pid"),start=ProcessInfo.processInfo.systemUptime
        try expectThrows(try CommandPipeFixture.run(["sleep","2400","ignore-term",file.path],timeout:1))
        try expect(ProcessInfo.processInfo.systemUptime-start<1.7,"An owned TERM-ignoring helper still has bounded cleanup")
        let pid=Int32(try String(contentsOf:file,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines))!
        let deadline=ProcessInfo.processInfo.systemUptime+1
        while Darwin.kill(pid,0)==0,ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.02)}
        try expect(Darwin.kill(pid,0) != 0,"Only the fixture's direct helper must retire")
    }

    func testCommandPipesRepeatedCallsReleaseDescriptors() throws {
        for _ in 0..<3 {_ = try CommandPipeFixture.run(["empty"])}
        let before=try FileManager.default.contentsOfDirectory(atPath:"/dev/fd").count
        for index in 0..<12 {
            if index.isMultiple(of:2) {_ = try CommandPipeFixture.run(["bytes","4096","1024"])}
            else {try expectThrows(try CommandPipeFixture.run(["bytes","65536","0"],output:1024))}
        }
        let after=try FileManager.default.contentsOfDirectory(atPath:"/dev/fd").count
        try expect(after<=before+2,"Repeated EOF/overflow paths must release their owned descriptors")
    }
}
