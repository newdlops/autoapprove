import Foundation
import Darwin
import AutoApproveCore

extension ApprovalTests {
    @MainActor func testCodexDiagnosticsDeduplicatesAndRejectsChangedPayload() async throws {
        let manager = CodexDiagnostics(services: .init(run: { _ in
            try await Task.sleep(nanoseconds: 80_000_000)
            return Data(#"{"summary":"Healthy","findings":[],"limitations":["Snapshot only"]}"#.utf8)
        }))
        let id = UUID().uuidString, snapshot = Data("{}".utf8)
        let first = try manager.start(requestID:id,home:"/tmp/home",executable:nil,snapshot:snapshot,question:"Check")
        try expectEqual(first.phase,"running"); try expect(manager.busy)
        try expectEqual(try manager.start(requestID:id,home:"/tmp/home",executable:nil,snapshot:snapshot,question:"Check").id,id)
        try expectThrows(manager.start(requestID:id,home:"/tmp/home",executable:nil,snapshot:snapshot,question:"Changed"))
        try expectThrows(manager.start(requestID:UUID().uuidString,home:"/tmp/home",executable:nil,snapshot:snapshot,question:"Check"))
        try await Task.sleep(nanoseconds:200_000_000)
        try expectEqual(manager.status()?.phase,"completed"); try expectEqual(manager.status()?.result?.summary,"Healthy")
        try expect(!manager.busy); try expectNil(manager.status(requestID:UUID().uuidString))
        try expectEqual(try manager.start(requestID:id,home:"/tmp/home",executable:nil,snapshot:snapshot,question:"Check").phase,"completed")
    }
    @MainActor func testCodexDiagnosticsCancellationAndMalformedResultsStayTerminal() async throws {
        let manager = CodexDiagnostics(services:.init(run:{ _ in
            try? await Task.sleep(nanoseconds:100_000_000)
            return Data(#"{"summary":"late","findings":[],"limitations":[]}"#.utf8)
        }))
        let id = UUID().uuidString
        _ = try manager.start(requestID:id,home:"/tmp/home",executable:nil,snapshot:Data("{}".utf8),question:"")
        try expectEqual(try manager.cancel(requestID:id).phase,"cancelled")
        try expectEqual(try manager.cancel(requestID:id).phase,"cancelled")
        try await Task.sleep(nanoseconds:180_000_000)
        try expectEqual(manager.status()?.phase,"cancelled"); try expectNil(manager.status()?.result)
        let invalid = CodexDiagnostics(services:.init(run:{ _ in Data(#"{"summary":"x","findings":[{"severity":"fatal","title":"t","evidence":"e","recommendation":"r"}],"limitations":[]}"#.utf8) }))
        _ = try invalid.start(requestID:UUID().uuidString,home:"/tmp/home",executable:nil,snapshot:Data("{}".utf8),question:"")
        try await Task.sleep(nanoseconds:80_000_000)
        try expectEqual(invalid.status()?.phase,"failed"); try expectNil(invalid.status()?.result)
    }
    @MainActor func testCodexDiagnosticsBoundsInputsAndSanitizesFailures() async throws {
        let manager = CodexDiagnostics(services:.init(run:{ _ in throw AppError.message("secret TOKEN raw stderr") }))
        try expectThrows(manager.start(requestID:"not-uuid",home:"/tmp/home",executable:nil,snapshot:Data("{}".utf8),question:""))
        try expectThrows(manager.start(requestID:UUID().uuidString,home:"/tmp/home",executable:nil,snapshot:Data("bad".utf8),question:""))
        try expectThrows(manager.start(requestID:UUID().uuidString,home:"/tmp/home",executable:nil,snapshot:Data("{}".utf8),question:String(repeating:"x",count:2001)))
        _ = try manager.start(requestID:UUID().uuidString,home:"/tmp/home",executable:nil,snapshot:Data("{}".utf8),question:"")
        try await Task.sleep(nanoseconds:80_000_000)
        try expectEqual(manager.status()?.phase,"failed")
        try expect(!(manager.status()?.message.contains("secret") ?? true))
    }
    @MainActor func testCodexDiagnosticsLiveLaunchIsIsolatedAndValidatesVersion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let executable = directory.appendingPathComponent("codex")
        let script = #"""
        #!/bin/sh
        if [ "$1" = "--version" ]; then printf 'codex-cli 0.166.0\n'; exit 0; fi
        printf '%s\n' "$@" > "$CODEX_HOME/arguments"
        pwd > "$CODEX_HOME/cwd"
        cat > "$CODEX_HOME/input"
        printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"{\"summary\":\"Synthetic success\",\"findings\":[],\"limitations\":[\"snapshot\"]}"}}'
        """#
        try Data(script.utf8).write(to:executable)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:executable.path)
        let manager = CodexDiagnostics(services:.live(timeout:10))
        _ = try manager.start(requestID:UUID().uuidString,home:directory.path,executable:executable.path,snapshot:Data(#"{"schemaVersion":1}"#.utf8),question:"Check safely")
        for _ in 0..<250 where manager.busy { try await Task.sleep(nanoseconds:20_000_000) }
        try expectEqual(manager.status()?.phase,"completed")
        try expectEqual(manager.status()?.result?.summary,"Synthetic success")
        let args = try String(contentsOf:directory.appendingPathComponent("arguments"),encoding:.utf8).split(separator:"\n").map(String.init)
        for flag in ["--ephemeral","--ignore-user-config","--ignore-rules","--json","read-only","--output-schema","web_search=\"disabled\""] { try expect(args.contains(flag),"Missing isolation option: \(flag)") }
        for feature in ["shell_tool","unified_exec","apps","plugins","hooks","multi_agent","computer_use","browser_use","browser_use_external","in_app_browser","image_generation","view_image","code_mode_host"] {
            try expect(args.indices.contains { $0 > 0 && args[$0] == feature && args[$0-1] == "--disable" })
        }
        let cwd = try String(contentsOf:directory.appendingPathComponent("cwd"),encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)
        try expect(cwd.contains("autoapprove-diagnostic-")); try expect(!FileManager.default.fileExists(atPath:cwd))
        let prompt = try String(contentsOf:directory.appendingPathComponent("input"),encoding:.utf8)
        try expect(prompt.contains("Check safely") && prompt.contains("schemaVersion"))
        try expect(!args.contains(where:{$0.contains("Check safely")}))
        try Data("#!/bin/sh\nprintf 'codex-cli 0.165.0\\n'\n".utf8).write(to:executable)
        let legacy = CodexDiagnostics(services:.live(timeout:10))
        _ = try legacy.start(requestID:UUID().uuidString,home:directory.path,executable:executable.path,snapshot:Data("{}".utf8),question:"")
        for _ in 0..<250 where legacy.busy { try await Task.sleep(nanoseconds:20_000_000) }
        try expectEqual(legacy.status()?.phase,"failed")
        try expect(legacy.status()?.message.contains("0.166.0") == true)
    }

    @MainActor func testCodexDiagnosticsLiveCancellationKillsOnlyOwnedChildAndDeadlineIsBounded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-cancel-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let executable = directory.appendingPathComponent("codex")
        let script = #"""
        #!/bin/sh
        if [ "$1" = "--version" ]; then printf 'codex-cli 0.166.0\n'; exit 0; fi
        echo $$ > "$CODEX_HOME/pid"
        trap '' TERM
        while :; do :; done
        """#
        try Data(script.utf8).write(to:executable)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:executable.path)
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath:"/bin/sleep"); unrelated.arguments = ["15"]
        try unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate() } }
        let manager = CodexDiagnostics(services:.live(timeout:10)), id = UUID().uuidString
        _ = try manager.start(requestID:id,home:directory.path,executable:executable.path,snapshot:Data("{}".utf8),question:"")
        let pidURL = directory.appendingPathComponent("pid")
        for _ in 0..<250 where !FileManager.default.fileExists(atPath:pidURL.path) { try await Task.sleep(nanoseconds:20_000_000) }
        let pid = Int32(try String(contentsOf:pidURL,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines))!
        _ = try manager.cancel(requestID:id)
        for _ in 0..<100 where manager.busy { try await Task.sleep(nanoseconds:20_000_000) }
        try expect(!manager.busy); try expectEqual(manager.status()?.phase,"cancelled")
        try expect(unrelated.isRunning,"Cancellation must preserve unrelated processes")
        try expect(Darwin.kill(pid,0) != 0,"The diagnostic child must be reaped after ignoring SIGTERM")
        let timed = CodexDiagnostics(services:.live(timeout:0.3))
        _ = try timed.start(requestID:UUID().uuidString,home:directory.path,executable:executable.path,snapshot:Data("{}".utf8),question:"")
        for _ in 0..<150 where timed.busy { try await Task.sleep(nanoseconds:20_000_000) }
        try expect(!timed.busy); try expectEqual(timed.status()?.phase,"failed")
        try expect(timed.status()?.message.contains("초과") == true)
    }

    @MainActor func testCodexDiagnosticsLiveOutputBoundAndEarlyExitAreSafe() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-output-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let executable = directory.appendingPathComponent("codex")
        let preamble = "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then printf 'codex-cli 0.166.0\\n'; exit 0; fi\n"
        for (index,body) in ["i=0; while [ $i -lt 1500 ]; do printf '%s' '"+String(repeating:"x",count:1024)+"'; i=$((i+1)); done\n", "printf 'SECRET-STDERR' >&2; exit 1\n"].enumerated() {
            try Data((preamble+body).utf8).write(to:executable)
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:executable.path)
            let manager = CodexDiagnostics(services:.live(timeout:10))
            let snapshot = try JSONSerialization.data(withJSONObject:["detail":String(repeating:"s",count:100_000)])
            _ = try manager.start(requestID:UUID().uuidString,home:directory.path,executable:executable.path,snapshot:snapshot,question:"")
            for _ in 0..<500 where manager.busy { try await Task.sleep(nanoseconds:20_000_000) }
            try expect(!manager.busy); try expectEqual(manager.status()?.phase,"failed")
            try expect(!(manager.status()?.message.contains("SECRET") ?? true)); try expectNil(manager.status()?.result)
            if index == 0 { try expect(manager.status()?.message.contains("크기") == true,"Flooded stdout must fail at the output bound, before result parsing") }
        }
    }

    @MainActor func testCodexDiagnosticsDiscoversInteractiveLoginPATHAmidStartupNoise() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-login-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let bin = directory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at:bin,withIntermediateDirectories:true)
        let executable = bin.appendingPathComponent("codex"), shell = directory.appendingPathComponent("login-shell")
        let response = #"""
        #!/bin/sh
        if [ "$1" = "--version" ]; then printf 'codex-cli 0.166.0\n'; exit 0; fi
        cat >/dev/null
        printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"{\"summary\":\"Found interactive CLI\",\"findings\":[],\"limitations\":[]}"}}'
        """#
        try Data(response.utf8).write(to:executable)
        // Wrapper selects a hermetic real zsh configuration; no process-global environment mutation.
        let quoted = "'"+directory.path.replacingOccurrences(of:"'",with:"'\\''")+"'"
        try Data(("#!/bin/sh\nexport ZDOTDIR="+quoted+"\nexec /bin/zsh \"$@\"\n").utf8).write(to:shell)
        let rc = "printf 'startup noise: /untrusted/path\\n'\nexport PATH="+quoted+"/bin:/usr/bin:/bin\n"
        try Data(rc.utf8).write(to:directory.appendingPathComponent(".zshrc"))
        for file in [executable,shell] { try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:file.path) }
        let manager = CodexDiagnostics(services:.live(timeout:10,shell:shell.path))
        _ = try manager.start(requestID:UUID().uuidString,home:directory.path,executable:nil,snapshot:Data("{}".utf8),question:"")
        for _ in 0..<500 where manager.busy { try await Task.sleep(nanoseconds:20_000_000) }
        try expectEqual(manager.status()?.phase,"completed","CLI available only in interactive login PATH must be found despite startup output")
        try expectEqual(manager.status()?.result?.summary,"Found interactive CLI")
    }

    @MainActor func testCodexDiagnosticsCancellationKillsOwnedWrapperDescendants() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-tree-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let executable = directory.appendingPathComponent("codex"), native = directory.appendingPathComponent("native")
        let wrapper = #"""
        #!/bin/sh
        if [ "$1" = "--version" ]; then printf 'codex-cli 0.166.0\n'; exit 0; fi
        trap '' TERM
        echo $$ > "$CODEX_HOME/wrapper-pid"
        "$CODEX_HOME/native" &
        wait
        """#
        let child = #"""
        #!/bin/sh
        trap '' TERM
        echo $$ > "$CODEX_HOME/native-pid"
        while :; do :; done
        """#
        try Data(wrapper.utf8).write(to:executable); try Data(child.utf8).write(to:native)
        for file in [executable,native] { try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:file.path) }
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath:"/bin/sleep"); unrelated.arguments = ["15"]
        try unrelated.run(); defer { if unrelated.isRunning { unrelated.terminate() } }
        let manager = CodexDiagnostics(services:.live(timeout:10)), id = UUID().uuidString
        _ = try manager.start(requestID:id,home:directory.path,executable:executable.path,snapshot:Data("{}".utf8),question:"")
        let pidURL = directory.appendingPathComponent("native-pid")
        for _ in 0..<250 where !FileManager.default.fileExists(atPath:pidURL.path) { try await Task.sleep(nanoseconds:20_000_000) }
        let pid = Int32(try String(contentsOf:pidURL,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines))!
        defer { _ = Darwin.kill(pid,SIGKILL) }
        try expect(Darwin.kill(pid,0) == 0)
        let wrapperPID = Int32(try String(contentsOf:directory.appendingPathComponent("wrapper-pid"),encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines))!
        try expectEqual(Darwin.getpgid(wrapperPID),wrapperPID)
        try expectEqual(Darwin.getpgid(pid),wrapperPID)
        try expectEqual(Darwin.getsid(pid),wrapperPID,"Diagnostic descendants must belong to the new detached session")
        _ = try manager.cancel(requestID:id)
        for _ in 0..<150 where manager.busy || Darwin.kill(pid,0) == 0 { try await Task.sleep(nanoseconds:20_000_000) }
        try expect(!manager.busy); try expectEqual(manager.status()?.phase,"cancelled")
        try expect(unrelated.isRunning,"Diagnostic cancellation must preserve unrelated process groups")
        try expect(Darwin.kill(pid,0) != 0,"Cancellation must kill the diagnostic wrapper's TERM-ignoring native descendant")
    }

}
