import Foundation
import JavaScriptCore
import AutoApproveCore

extension ApprovalTests {
    func testProfileLauncherDeliversToBackgroundShell() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-profile-shell-" + UUID().uuidString)
        let cwd = root.appendingPathComponent(String(repeating: "한글 '$PATH ", count: 9))
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("claude")
        try Data("#!/bin/sh\n/usr/bin/printf '%s\\n' \"$PWD\" \"$1\" \"$2\" >> delivered\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let entry = TerminalProfileEntry(title: "Fixture", agent: "claude", cwd: cwd.path, conversationID: UUID().uuidString.lowercased())
        let target = "/dev/ttys980"
        let tty = try await TerminalProfileLauncher.launch(entry, anchorTTY: "/dev/ttys979", openTab: { _, _ in target }, execute: { body, _ in
            try expect(!body.contains(entry.cwd) && !body.contains(entry.conversationID))
            let context = JSContext()!
            let shell: @convention(block) (String) -> Bool = { input in
                guard input.hasPrefix(". "), input.utf8.count < 512 else { return false }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-f", "-c", input]
                process.environment = ["PATH": root.path + ":/usr/bin:/bin"]
                do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 }
                catch { return false }
            }
            context.setObject(shell, forKeyedSubscript: "deliver" as NSString)
            context.evaluateScript("""
            const ObjC={import:()=>{}}, tty='/dev/ttys980';
            const tab={tty:()=>tty,processes:()=>['login','zsh'],busy:()=>false};
            let front=31;
            const windows={id:()=>front===31?[31,22]:[22,31],tabs:{tty:()=>windows.id().map(id=>[id===22?tty:'/dev/ttys931'])},
              byId:id=>({id:()=>id,exists:()=>[22,31].includes(id),set index(value){if(value===1)front=id;},
                         tabs:{whose:query=>()=>id===22&&query.tty===tty?[tab]:[]}})};
            function Application(){return {windows,frontmost:()=>true,doScript:(line,options)=>{
              if(options.in!==tab || !deliver(line))throw Error('Fixture shell failed');
              front=22;
            }};}
            """)
            guard let reply = context.evaluateScript(body)?.toString(), context.exception == nil else {
                throw AppError.message("Background delivery script failed")
            }
            try expectEqual(context.evaluateScript("front")?.toInt32(), 31)
            return reply
        })
        try expectEqual(tty, target)
        let lines = try String(contentsOf: cwd.appendingPathComponent("delivered"), encoding: .utf8).split(separator: "\n").map(String.init)
        try expectEqual(lines.count, 3)
        try expectEqual(URL(fileURLWithPath: lines[0]).resolvingSymlinksInPath().path, cwd.resolvingSymlinksInPath().path)
        try expectEqual(Array(lines.suffix(2)), ["--resume", entry.conversationID])
    }
}
