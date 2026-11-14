import Foundation

/// Provision before exiting a CLI whose interactive shell was replaced by exec.
/// The existing opener proves the new tab belongs to the original native bar.
public enum CodexReplacementTab {
    public static func prepare(_ target:ScreenTarget)throws->ProcessRecord {
        guard !NativeKeyboardActivity.live.hasPriority(terminal:.terminal) else{throw RemoteHTTPError(409,"터미널에서 입력 중이어서 복구 탭을 열지 않았습니다.",diagnostics:["delivery":"not_started"])}
        guard let pid=target.sourcePID,let started=target.sourceStarted,
              let process=try ProcessDiscovery.read(pid:pid).first(where:{$0.started==started && "/dev/"+$0.tty==target.tty && ($0.agent == .codex || $0.agent == .claude) && $0.isForeground}) else{throw AppError.message("원래 CLI 실행을 확인하지 못했습니다.")}
        let tty=try TerminalProfileTabOpener.open(anchorTTY:target.tty)
        return try TerminalProfileReadiness.wait(timeout:4,message:"같은 창의 빈 복구 셸을 확인하지 못했습니다. 원래 Codex는 유지합니다.") {
            let rows=try ProcessDiscovery.read()
            guard let shell=SessionExitRecovery.foregroundShell(in:rows,tty:String(tty.dropFirst("/dev/".count))),shell.pid != process.pid else{return nil}
            let screens=try TerminalAdapter.screens(ttys:[tty],includeCursor:false,includeTitles:false,purpose:.validation)
            guard screens.failures.isEmpty,screens.screens.count==1,let raw=screens.screens.first?.contents,SessionExitRecovery.emptyShellPrompt(raw) else{return nil}
            return shell
        }
    }
    public static func sameWindow(_ target:ScreenTarget,shell:ProcessRecord)throws->Bool {
        let tty="/dev/"+shell.tty
        guard let live=try ProcessDiscovery.read(pid:shell.pid).first,live==shell,live.isForeground,SessionExitRecovery.isShell(live) else{return false}
        let rows=try TerminalProfileTopology.read(ttys:[target.tty,tty])
        guard rows.count==2,let original=rows.first(where:{$0.tty==target.tty}),let replacement=rows.first(where:{$0.tty==tty}) else{return false}
        return original.windowID==replacement.windowID
    }
}
