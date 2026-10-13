import Foundation
import Darwin
import AutoApproveCore
@main struct InterruptionRelayCheck {
    static func main() async throws {
        setbuf(stdout, nil)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),socket=CommandLine.arguments[2],tmux=CommandLine.arguments[3]
        func call(_ args:[String]) throws -> String { let r=try CommandRunner.run(tmux,["-S",socket]+args); precondition(r.status==0,r.error);return r.output }
        func stopped(_ read: () throws -> String) async throws -> (String, CodexCapacityStop) {
            let deadline=Date().addingTimeInterval(3);var screen=""
            repeat {
                screen=try read()
                if let stop=CodexCapacityStop.detect(screen,agent:.codex){return(screen,stop)}
                try await Task.sleep(for:.milliseconds(20))
            } while Date()<deadline
            throw AppError.message("Test terminal did not draw a stopped composer: \(screen)")
        }
        func choice(_ read: () throws -> String, expected: String? = nil) async throws -> (String, TerminalChoiceQuestion) {
            let deadline=Date().addingTimeInterval(3)
            repeat { let screen=try read(); if let menu=TerminalChoiceQuestion.detect(screen,agent:.codex), expected == nil || menu.question.contains(expected!) {return(screen,menu)};try await Task.sleep(for:.milliseconds(20)) } while Date()<deadline
            throw AppError.message("Test terminal did not draw a choice menu")
        }
        func foreground(_ tty:String) async throws -> ScreenTarget {
            for _ in 0..<100 {
                if let process=try ProcessDiscovery.read().first(where:{$0.agent == .codex && "/dev/"+$0.tty == tty && $0.isForeground}) {return ScreenTarget(tty:tty,jobPIDs:[process.pid],sourcePID:process.pid,sourceStarted:process.started)}
                try await Task.sleep(for:.milliseconds(20))
            }
            throw AppError.message("Test CLI did not enter its foreground TTY")
        }
        func received(_ file:URL, _ expected:String) async throws {
            let bytes=Data(expected.utf8),deadline=Date().addingTimeInterval(3)
            repeat {
                let actual=(try? Data(contentsOf:file)) ?? Data()
                if actual==bytes{return}
                guard actual.count<=bytes.count else{throw AppError.message("Test received extra input bytes")}
                try await Task.sleep(for:.milliseconds(20))
            }while Date()<deadline
            throw AppError.message("Test did not receive the expected input bytes")
        }
        let manager=ManagedPTYManager();defer{manager.stop()}
        let ptyRecord=root.appendingPathComponent("pty-input.bin")
        let pty=try manager.create(cwd:root.path,program:"codex",command:[root.appendingPathComponent("codex").path,ptyRecord.path,"capacity"],columns:100,rows:25)
        var ptyTarget=ScreenTarget(tty:pty.tty)
        for _ in 0..<100 {
            let records=try ProcessDiscovery.read()
            if let process=records.first(where:{$0.agent == .codex && "/dev/"+$0.tty == pty.tty && $0.isForeground}) {ptyTarget.jobPIDs=[process.pid];ptyTarget.sourcePID=process.pid;ptyTarget.sourceStarted=process.started;break}
            try await Task.sleep(for:.milliseconds(20))
        }
        try await Task.sleep(for:.milliseconds(150))
        let (before,stop)=try await stopped {try manager.terminal(pty.ptyID).screen()}
        precondition(stop.kind == .capacity)
        let result=try manager.adapter.resume(ptyTarget,stop.region,CodexCapacityStop.resumeText)
        if result != .sent {
            let received=(try? String(contentsOf:ptyRecord,encoding:.utf8)) ?? "none",after=try manager.terminal(pty.ptyID).screen()
            fatalError("PTY result \(result.rawValue), received \(received), before \(before), after \(after)")
        }
        let ptyBytes=try Data(contentsOf:ptyRecord)
        precondition(ptyBytes==Data((CodexCapacityStop.resumeText+"\r").utf8))
        print("PASS actual owned PTY resumes capacity failure with exact UTF-8 and one verified Return")
        for mode in ["blocked", "capacity-goal"] {
        let goalRecord=root.appendingPathComponent("\(mode)-pty-input.bin")
        let goalPTY=try manager.create(cwd:root.path,program:"codex",command:[root.appendingPathComponent("codex").path,goalRecord.path,mode],columns:100,rows:25)
        var goalTarget=ScreenTarget(tty:goalPTY.tty)
        for _ in 0..<100 {
            let records=try ProcessDiscovery.read()
            if let process=records.first(where:{$0.agent == .codex && "/dev/"+$0.tty == goalPTY.tty && $0.isForeground}) {goalTarget.jobPIDs=[process.pid];goalTarget.sourcePID=process.pid;goalTarget.sourceStarted=process.started;break}
            try await Task.sleep(for:.milliseconds(20))
        }
        try await Task.sleep(for:.milliseconds(100))
        let (_,goalStop)=try await stopped {try manager.terminal(goalPTY.ptyID).screen()}
        precondition(goalStop.continuationText == "/goal resume")
        precondition(goalStop.kind == (mode == "blocked" ? .goalBlocked : .capacity))
        let goalResult=try manager.adapter.resume(goalTarget,goalStop.region,goalStop.continuationText),goalBytes=try Data(contentsOf:goalRecord)
        precondition(goalResult == .sent);precondition(goalBytes == Data("/goal resume\r".utf8))
        print("PASS actual owned PTY reactivates \(mode) with exact /goal resume and one verified Return")
        }
        for (mode, kind) in [("processing", SessionInterruption.Kind.transport), ("processing-goal", .transport), ("unknown", .api), ("authentication", .authentication)] {
            let record=root.appendingPathComponent("\(mode)-pty-input.bin")
            let terminal=try manager.create(cwd:root.path,program:"codex",command:[root.appendingPathComponent("codex").path,record.path,mode],columns:100,rows:25)
            let target=try await foreground(terminal.tty)
            let (_,failure)=try await stopped {try manager.terminal(terminal.ptyID).screen()}
            precondition(failure.kind == kind)
            let text=mode == "processing-goal" ? "/goal resume" : CodexCapacityStop.resumeText
            precondition(failure.continuationText == text)
            let delivered=try manager.adapter.resume(target,failure.region,text)
            precondition(delivered == .sent); try await received(record,text+"\r")
            print("PASS actual owned PTY recovers \(mode) in its original composer with exact text and one verified Return")
        }
        for mode in ["newline-first", "newline-goal"] {
            let record = root.appendingPathComponent("\(mode)-pty-input.bin")
            let terminal = try manager.create(cwd: root.path, program: "codex", command: [root.appendingPathComponent("codex").path, record.path, mode], columns: 100, rows: 25)
            let target = try await foreground(terminal.tty)
            let (_, failure) = try await stopped { try manager.terminal(terminal.ptyID).screen() }
            let first = try manager.adapter.resume(target, failure.region, failure.continuationText)
            precondition(first == .draft)
            try await received(record, failure.continuationText + "\r")
            let submitted = try manager.adapter.completeResume!(target, failure)
            precondition(submitted == .sent)
            try await received(record, failure.continuationText + "\r\r")
            print("PASS actual owned PTY \(mode) retries Return alone after a newline, without retyping text")
        }
        for mode in ["choice", "request-choice"] {
            let record=root.appendingPathComponent("\(mode)-pty-input.bin")
            let terminal=try manager.create(cwd:root.path,program:"codex",command:[root.appendingPathComponent("codex").path,record.path,mode],columns:100,rows:25)
            let target=try await foreground(terminal.tty)
            let (before,menu)=try await choice {try manager.terminal(terminal.ptyID).screen()}
            let index=mode == "choice" ? 2:1, input=RemoteTerminalInput(kind:.choice,text:menu.command(for:index))
            let selected=try manager.adapter.input(target,before,.codex,input)
            guard selected == .sent else { throw AppError.message("Test \(mode) input refused: \(selected.rawValue)") }
            if mode == "request-choice" {
                let (next,current)=try await choice({try manager.terminal(terminal.ptyID).screen()},expected:"Question 2/2")
                precondition(current.question.contains("Question 2/2"));try await received(record,"2")
                let answered=try manager.adapter.input(target,next,.codex,RemoteTerminalInput(kind:.choice,text:current.command(for:0)));precondition(answered == .sent)
                try await received(record,"21")
                print("PASS actual owned PTY answers two Codex question tabs with two explicit digits and zero extra Return")
            } else {
                try await received(record,"\u{1b}[B\r")
                print("PASS actual owned PTY selects the requested menu position with one move and one Return")
            }
        }
        let meta=try call(["list-panes","-F","#{pane_tty}|#{pane_pid}"]).trimmingCharacters(in:.newlines).components(separatedBy:"|")
        let tmuxRecord=root.appendingPathComponent("tmux-input.bin")
        _=try call(["send-keys","-l",HookInstaller.quote(root.appendingPathComponent("codex").path)+" "+HookInstaller.quote(tmuxRecord.path)+" capacity"])
        _=try call(["send-keys","Enter"])
        var session:AgentSession?
        for _ in 0..<100 {
            session=ProcessDiscovery.sessions(try ProcessDiscovery.read()).first(where:{$0.terminal == .tmux && $0.tty == meta[0]})
            if session != nil {break};try await Task.sleep(for:.milliseconds(20))
        }
        let original=session!,relay=TmuxRelay();defer{relay.stop()}
        let target=ScreenTarget(tty:original.tty,handle:original.tmuxHandle,jobPIDs:[original.pid],sourcePID:original.pid,sourceStarted:original.started)
        try await Task.sleep(for:.milliseconds(100))
        let (_,tmuxStop)=try await stopped {try relay.screen(target,fresh:true).contents}
        precondition(tmuxStop.kind == .capacity)
        let sent=try relay.adapter.resume(target,tmuxStop.region,CodexCapacityStop.resumeText)
        precondition(sent == .sent)
        let tmuxBytes=try Data(contentsOf:tmuxRecord)
        precondition(tmuxBytes==Data((CodexCapacityStop.resumeText+"\r").utf8))
        print("PASS actual original tmux pane resumes capacity failure once without creating a PTY")
        for _ in 0..<100 {
            if try ProcessDiscovery.read().contains(where:{$0.pid == Int32(meta[1]) && $0.isForeground}) {break}
            try await Task.sleep(for:.milliseconds(20))
        }
        let goalTmuxRecord=root.appendingPathComponent("goal-tmux-input.bin")
        _=try call(["send-keys","-l",HookInstaller.quote(root.appendingPathComponent("codex").path)+" "+HookInstaller.quote(goalTmuxRecord.path)+" blocked"])
        _=try call(["send-keys","Enter"])
        var goalSession:AgentSession?
        for _ in 0..<100 {
            goalSession=ProcessDiscovery.sessions(try ProcessDiscovery.read()).first(where:{$0.terminal == .tmux && $0.tty == meta[0]})
            if goalSession != nil {break};try await Task.sleep(for:.milliseconds(20))
        }
        let goalOriginal=goalSession!,goalTmuxTarget=ScreenTarget(tty:goalOriginal.tty,handle:goalOriginal.tmuxHandle,jobPIDs:[goalOriginal.pid],sourcePID:goalOriginal.pid,sourceStarted:goalOriginal.started)
        try await Task.sleep(for:.milliseconds(100))
        let (_,goalTmuxStop)=try await stopped {try relay.screen(goalTmuxTarget,fresh:true).contents}
        precondition(goalTmuxStop.continuationText == "/goal resume")
        precondition(goalTmuxStop.kind == .goalBlocked)
        let goalTmuxResult=try relay.adapter.resume(goalTmuxTarget,goalTmuxStop.region,goalTmuxStop.continuationText),goalTmuxBytes=try Data(contentsOf:goalTmuxRecord)
        precondition(goalTmuxResult == .sent);precondition(goalTmuxBytes == Data("/goal resume\r".utf8))
        print("PASS actual original tmux pane reactivates a blocked Goal without an API error, using exact command and Return")
        for _ in 0..<100 {
            if try ProcessDiscovery.read().contains(where:{$0.pid == Int32(meta[1]) && $0.isForeground}) {break}
            try await Task.sleep(for:.milliseconds(20))
        }
        let processingRecord=root.appendingPathComponent("processing-tmux-input.bin")
        _=try call(["send-keys","-l",HookInstaller.quote(root.appendingPathComponent("codex").path)+" "+HookInstaller.quote(processingRecord.path)+" processing"])
        _=try call(["send-keys","Enter"])
        var processingTarget=try await foreground(meta[0]);processingTarget.handle=original.tmuxHandle
        let (_,processingStop)=try await stopped {try relay.screen(processingTarget,fresh:true).contents}
        precondition(processingStop.kind == .transport)
        let processingDelivery=try relay.adapter.resume(processingTarget,processingStop.region,processingStop.continuationText)
        precondition(processingDelivery == .sent);try await received(processingRecord,CodexCapacityStop.resumeText+"\r")
        print("PASS actual original tmux pane recovers the wrapped request-processing error with exact text and one Return")
        for _ in 0..<100 {if try ProcessDiscovery.read().contains(where:{$0.pid == Int32(meta[1]) && $0.isForeground}){break};try await Task.sleep(for:.milliseconds(20))}
        let choiceRecord=root.appendingPathComponent("choice-tmux-input.bin")
        _=try call(["send-keys","-l",HookInstaller.quote(root.appendingPathComponent("codex").path)+" "+HookInstaller.quote(choiceRecord.path)+" choice"]);_=try call(["send-keys","Enter"])
        var choiceTarget=try await foreground(meta[0]);choiceTarget.handle=original.tmuxHandle
        let (choiceScreen,choiceMenu)=try await choice {try relay.screen(choiceTarget,fresh:true).contents}
        let choiceResult=try relay.adapter.input(choiceTarget,choiceScreen,.codex,RemoteTerminalInput(kind:.choice,text:choiceMenu.command(for:2)));precondition(choiceResult == .sent)
        try await received(choiceRecord,"\u{1b}[B\r")
        print("PASS actual original tmux pane selects a generic question in the same pane with one Return")
        for _ in 0..<100 {if try ProcessDiscovery.read().contains(where:{$0.pid == Int32(meta[1]) && $0.isForeground}){break};try await Task.sleep(for:.milliseconds(20))}
        for mode in ["newline-first", "newline-goal"] {
            let record = root.appendingPathComponent("\(mode)-tmux-input.bin")
            _ = try call(["send-keys", "-l", HookInstaller.quote(root.appendingPathComponent("codex").path) + " " + HookInstaller.quote(record.path) + " " + mode])
            _ = try call(["send-keys", "Enter"])
            var target = try await foreground(meta[0]); target.handle = original.tmuxHandle
            let (_, failure) = try await stopped { try relay.screen(target, fresh: true).contents }
            let first = try relay.adapter.resume(target, failure.region, failure.continuationText)
            precondition(first == .draft)
            try await received(record, failure.continuationText + "\r")
            let submitted = try relay.adapter.completeResume!(target, failure)
            precondition(submitted == .sent)
            try await received(record, failure.continuationText + "\r\r")
            print("PASS actual original tmux pane \(mode) retries Return alone without a replacement PTY or duplicate text")
            for _ in 0..<100 { if try ProcessDiscovery.read().contains(where: { $0.pid == Int32(meta[1]) && $0.isForeground }) { break }; try await Task.sleep(for: .milliseconds(20)) }
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
