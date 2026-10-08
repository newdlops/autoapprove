import Foundation
import AutoApproveCore
@main struct InterruptionRelayCheck {
    static func main() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),socket=CommandLine.arguments[2],tmux=CommandLine.arguments[3]
        func call(_ args:[String]) throws -> String { let r=try CommandRunner.run(tmux,["-S",socket]+args); precondition(r.status==0,r.error);return r.output }
        let manager=ManagedPTYManager();defer{manager.stop()}
        let ptyRecord=root.appendingPathComponent("pty-input.bin")
        let pty=try manager.create(cwd:root.path,program:"codex",command:[root.appendingPathComponent("codex").path,ptyRecord.path],columns:100,rows:25)
        var ptyTarget=ScreenTarget(tty:pty.tty)
        for _ in 0..<100 {
            let records=try ProcessDiscovery.read()
            if let process=records.first(where:{$0.agent == .codex && "/dev/"+$0.tty == pty.tty && $0.isForeground}) {ptyTarget.jobPIDs=[process.pid];ptyTarget.sourcePID=process.pid;ptyTarget.sourceStarted=process.started;break}
            try await Task.sleep(for:.milliseconds(20))
        }
        try await Task.sleep(for:.milliseconds(150))
        let before=try manager.terminal(pty.ptyID).screen(),stop=CodexCapacityStop.detect(before,agent:.codex)!
        let result=try manager.adapter.resume(ptyTarget,stop.region,CodexCapacityStop.resumeText)
        if result != .sent {
            let received=(try? String(contentsOf:ptyRecord,encoding:.utf8)) ?? "none",after=try manager.terminal(pty.ptyID).screen()
            fatalError("PTY result \(result.rawValue), received \(received), before \(before), after \(after)")
        }
        let ptyBytes=try Data(contentsOf:ptyRecord)
        precondition(ptyBytes==Data((CodexCapacityStop.resumeText+"\r").utf8))
        print("PASS actual owned PTY types exact UTF-8 then submits the verified draft once")
        let goalRecord=root.appendingPathComponent("goal-pty-input.bin")
        let goalPTY=try manager.create(cwd:root.path,program:"codex",command:[root.appendingPathComponent("codex").path,goalRecord.path,"goal"],columns:100,rows:25)
        var goalTarget=ScreenTarget(tty:goalPTY.tty)
        for _ in 0..<100 {
            let records=try ProcessDiscovery.read()
            if let process=records.first(where:{$0.agent == .codex && "/dev/"+$0.tty == goalPTY.tty && $0.isForeground}) {goalTarget.jobPIDs=[process.pid];goalTarget.sourcePID=process.pid;goalTarget.sourceStarted=process.started;break}
            try await Task.sleep(for:.milliseconds(20))
        }
        try await Task.sleep(for:.milliseconds(100))
        let goalBefore=try manager.terminal(goalPTY.ptyID).screen(),goalStop=CodexCapacityStop.detect(goalBefore,agent:.codex)!
        precondition(goalStop.continuationText == "/goal resume")
        let goalResult=try manager.adapter.resume(goalTarget,goalStop.region,goalStop.continuationText),goalBytes=try Data(contentsOf:goalRecord)
        precondition(goalResult == .sent);precondition(goalBytes == Data("/goal resume\r".utf8))
        print("PASS actual owned PTY acknowledges Goal reactivation without a user-message cell")
        let meta=try call(["list-panes","-F","#{pane_tty}|#{pane_pid}"]).trimmingCharacters(in:.newlines).components(separatedBy:"|")
        let tmuxRecord=root.appendingPathComponent("tmux-input.bin")
        _=try call(["send-keys","-l",HookInstaller.quote(root.appendingPathComponent("codex").path)+" "+HookInstaller.quote(tmuxRecord.path)])
        _=try call(["send-keys","Enter"])
        var session:AgentSession?
        for _ in 0..<100 {
            session=ProcessDiscovery.sessions(try ProcessDiscovery.read()).first(where:{$0.terminal == .tmux && $0.tty == meta[0]})
            if session != nil {break};try await Task.sleep(for:.milliseconds(20))
        }
        let original=session!,relay=TmuxRelay();defer{relay.stop()}
        let target=ScreenTarget(tty:original.tty,handle:original.tmuxHandle,jobPIDs:[original.pid],sourcePID:original.pid,sourceStarted:original.started)
        try await Task.sleep(for:.milliseconds(100))
        let frame=try relay.screen(target,fresh:true),stopped=CodexCapacityStop.detect(frame.contents,agent:.codex)!
        let sent=try relay.adapter.resume(target,stopped.region,CodexCapacityStop.resumeText)
        precondition(sent == .sent)
        let tmuxBytes=try Data(contentsOf:tmuxRecord)
        precondition(tmuxBytes==Data((CodexCapacityStop.resumeText+"\r").utf8))
        print("PASS actual original tmux pane sends the same continuation once without creating a PTY")
        for _ in 0..<100 {
            if try ProcessDiscovery.read().contains(where:{$0.pid == Int32(meta[1]) && $0.isForeground}) {break}
            try await Task.sleep(for:.milliseconds(20))
        }
        let goalTmuxRecord=root.appendingPathComponent("goal-tmux-input.bin")
        _=try call(["send-keys","-l",HookInstaller.quote(root.appendingPathComponent("codex").path)+" "+HookInstaller.quote(goalTmuxRecord.path)+" goal"])
        _=try call(["send-keys","Enter"])
        var goalSession:AgentSession?
        for _ in 0..<100 {
            goalSession=ProcessDiscovery.sessions(try ProcessDiscovery.read()).first(where:{$0.terminal == .tmux && $0.tty == meta[0]})
            if goalSession != nil {break};try await Task.sleep(for:.milliseconds(20))
        }
        let goalOriginal=goalSession!,goalTmuxTarget=ScreenTarget(tty:goalOriginal.tty,handle:goalOriginal.tmuxHandle,jobPIDs:[goalOriginal.pid],sourcePID:goalOriginal.pid,sourceStarted:goalOriginal.started)
        try await Task.sleep(for:.milliseconds(100))
        let goalScreen=try relay.screen(goalTmuxTarget,fresh:true),goalTmuxStop=CodexCapacityStop.detect(goalScreen.contents,agent:.codex)!
        precondition(goalTmuxStop.continuationText == "/goal resume")
        let goalTmuxResult=try relay.adapter.resume(goalTmuxTarget,goalTmuxStop.region,goalTmuxStop.continuationText),goalTmuxBytes=try Data(contentsOf:goalTmuxRecord)
        precondition(goalTmuxResult == .sent);precondition(goalTmuxBytes == Data("/goal resume\r".utf8))
        print("PASS actual original tmux pane reactivates a stalled Goal with exact command and Return")
        for _ in 0..<100 {
            if try ProcessDiscovery.read().contains(where:{$0.pid == Int32(meta[1]) && $0.isForeground}) {break}
            try await Task.sleep(for:.milliseconds(20))
        }
        let records=try ProcessDiscovery.read(),shell=records.first(where:{$0.pid == Int32(meta[1])})!
        precondition(SessionExitRecovery.isShell(shell) && shell.isForeground)
        let shellTarget=ScreenTarget(tty:original.tty,handle:original.tmuxHandle,jobPIDs:[shell.pid],sourcePID:shell.pid,sourceStarted:shell.started)
        let shellScreen=try relay.screen(shellTarget,fresh:true).contents
        precondition(SessionExitRecovery.emptyShellPrompt(shellScreen))
        let resumed=root.appendingPathComponent("resumed.txt"),conversation="00000000-0000-4000-8000-000000000061"
        let command=[root.appendingPathComponent("codex").path,"resume",conversation,CodexCapacityStop.resumeText,resumed.path].map(HookInstaller.quote).joined(separator:" ")
        let launched=try relay.adapter.restart!(shellTarget,shellScreen,command);precondition(launched == .sent)
        for _ in 0..<100 {if FileManager.default.fileExists(atPath:resumed.path){break};try await Task.sleep(for:.milliseconds(20))}
        let resumedText=try String(contentsOf:resumed,encoding:.utf8),panePID=try call(["display-message","-p","#{pane_pid}"]).trimmingCharacters(in:.newlines)
        precondition(resumedText==conversation+"\n"+CodexCapacityStop.resumeText)
        precondition(panePID==meta[1])
        print("PASS error-exited CLI recovery reaches the exact original tmux shell and quoted conversation arguments")
    }
}
