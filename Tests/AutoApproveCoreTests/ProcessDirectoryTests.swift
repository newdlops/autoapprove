import Foundation
import AutoApproveCore

/// This mode belongs only to the check executable, not the app or user CLI.
enum WorkingDirectoryFixture {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.count == 4, args[1] == "--cwd-fixture" else { return false }
        guard FileManager.default.changeCurrentDirectoryPath(args[2]) else { return true }
        FileHandle.standardOutput.write(Data("ready\n".utf8))
        guard readLine() == "change", FileManager.default.changeCurrentDirectoryPath(args[3]) else { return true }
        FileHandle.standardOutput.write(Data("changed\n".utf8))
        _ = readLine()
        return true
    }
}

extension ApprovalTests {
    func testWorkingDirectoryFollowsUnicodeChildDirectoryChanges() throws {
        let root = URL(fileURLWithPath: "/private/tmp/aa-cwd-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("처음 폴더"), second = root.appendingPathComponent("다음 폴더 🧪")
        for directory in [first, second] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--cwd-fixture", first.path, second.path]
        child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.nullDevice
        try child.run()
        try output.fileHandleForWriting.close(); try input.fileHandleForReading.close()
        let timeout = DispatchWorkItem { if child.isRunning { child.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
        defer {
            timeout.cancel(); try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
            if child.isRunning { child.terminate() }; child.waitUntilExit()
        }
        func signal() throws -> String {
            var data = Data()
            while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, data.count < 32 {
                if byte[0] == 10 { return String(decoding: data, as: UTF8.self) }
                data.append(byte)
            }
            throw AppError.message("cwd fixture did not report its directory change")
        }
        try expectEqual(try signal(), "ready")
        try expectEqual(ProcessDiscovery.cwd(pid: child.processIdentifier), first.path)
        try input.fileHandleForWriting.write(contentsOf: Data("change\n".utf8))
        try expectEqual(try signal(), "changed")
        try expectEqual(ProcessDiscovery.cwd(pid: child.processIdentifier), second.path, "The same PID's current directory must be read again after chdir")
        try input.fileHandleForWriting.write(contentsOf: Data("stop\n".utf8))
        child.waitUntilExit()
    }
}
