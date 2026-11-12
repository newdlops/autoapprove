import Foundation
import Darwin

/// Delivery reservations survive application restarts. Unknown exit/launch
/// outcomes require review rather than replaying terminal input.
public struct CodexSessionAttachment:Codable {
    public enum Phase:String,Codable {case needsPause,pauseReserved,waitingPause,needsTab,tabReserved,ready,exitReserved,waitingShell,launchReserved,verifying,connected,review}
    public var context:SessionExitRecovery
    public var home:String
    public var phase:Phase = .ready
    public var detail:String = "원래 대화의 관리형 서버 연결을 준비합니다."
    public var pauseNotStarted:Bool?
    public var exitNotStarted:Bool?
    public var goalBeforePause:CodexGoal?
    public var pausedGoal:CodexGoal?
    public var stoppedThread:CodexAccountTransitionThread?
    public var continuationLoginRequestID:String?
    public var originalLogin:ProcessRecord?
    public var preparationNotStarted:Bool?
    /// Only the exact cohort captured by an explicit reconnect may be stopped.
    public var authorizedToolHosts:[ProcessRecord]?
    /// Read-only shutdown barrier, not permission to send another signal.
    public var toolHostShutdownWitnesses:[ProcessRecord]?
    public init(context:SessionExitRecovery,home:String,originalLogin:ProcessRecord?=nil,authorizedToolHosts:[ProcessRecord]?=nil) {
        self.context=context;self.home=home;self.originalLogin=originalLogin;self.authorizedToolHosts=authorizedToolHosts
        if originalLogin != nil {phase = .needsTab;detail="원래 창에 복구용 탭을 먼저 준비합니다."}
    }
    public var canRetryUnsentGoalPause:Bool {
        phase == .review && goalBeforePause != nil && pausedGoal==nil && (pauseNotStarted == true || detail=="자동 연결 보류: Goal 중단 요청의 전달 결과를 확인하지 못했습니다." || detail=="자동 연결 보류: "+TerminalDeviceInput.unavailableBeforeInputMessage)
    }
    static func migrated(context:SessionExitRecovery,state:CodexSessionMigrationState)throws->Self {
        guard state.stage == .completed,state.destinationActivation != nil,
              let thread=context.conversationID,
              state.currentOwners[thread]==state.request.destination.home,
              state.request.clients.contains(where:{$0.identity.pid==context.session.pid
                  && $0.identity.started==context.session.started && $0.identity.tty==context.session.tty
                  && $0.threadIDs.contains(thread)}) else {
            throw AppError.message("완료된 그룹 이동과 원래 세션의 대화 연결을 확인하지 못했습니다.")
        }
        var destination=context
        destination.executable=state.request.destination.cliIdentity
        var attachment=Self(context:destination,home:state.request.destination.home)
        guard attachment.command != nil else{throw AppError.message("목적지 그룹에서 이어갈 대화의 실행 명령을 준비하지 못했습니다.")}
        attachment.detail="그룹 이동을 확인했습니다. 원래 터미널에서 같은 대화를 목적지 서버에 연결합니다."
        return attachment
    }
    public var replacesTab:Bool {originalLogin != nil}
    /// Separate jobs remain live work. Only an explicit reconnect's exact
    /// recorded tool-host cohort may be cleaned up by Codex's graceful exit.
    private static func isToolHost(_ child:ProcessRecord,of process:ProcessRecord)->Bool {
        let tool=URL(fileURLWithPath:child.executable)
        return child.tty==process.tty && ["node","node_repl"].contains(tool.lastPathComponent) && tool.deletingLastPathComponent().path.hasSuffix("/ChatGPT.app/Contents/Resources/cua_node/bin")
    }
    public static func toolHosts(process:ProcessRecord,records:[ProcessRecord])->[ProcessRecord] {
        let index=ProcessDiscovery.index(records)
        return records.filter {isToolHost($0,of:process) && ProcessDiscovery.ancestors(of:$0.parent,byPID:index).contains(where:{$0.key==process.key})}
    }
    public static func hasIndependentChildWork(process:ProcessRecord,records:[ProcessRecord],authorizedToolHosts:[ProcessRecord]=[])->Bool {
        let byPID=ProcessDiscovery.index(records)
        return records.contains {child in
            guard ProcessDiscovery.ancestors(of:child.parent,byPID:byPID).contains(where:{$0.key==process.key}) else{return false}
            if (child.executable as NSString).lastPathComponent=="codex-code-mode-host" {return false}
            if isToolHost(child,of:process),authorizedToolHosts.contains(where:{$0.key==child.key && $0.parent==child.parent && $0.executable==child.executable && $0.tty==child.tty && $0.processGroup==child.processGroup}) {return false}
            return child.agent != nil || child.processGroup != process.processGroup || (child.tty != "??" && child.tty != process.tty)
        }
    }
    public static func goalIfPresent(home:String,threadID:String)throws->CodexGoal? {
        guard UUID(uuidString:threadID) != nil else{throw AppError.message("원래 대화 ID를 확인해주세요.")}
        let path=URL(fileURLWithPath:home).appendingPathComponent("goals_1.sqlite").path
        var info=stat()
        if lstat(path,&info) != 0,errno==ENOENT {return nil}
        return try CodexGoalTransport.readDatabase(home:home,threadID:threadID)
    }
    public var command:String? {
        command(nativeRuntimeRoot:nil)
    }
    func command(nativeRuntimeRoot:String?) ->String? {
        guard let id=context.conversationID,UUID(uuidString:id) != nil,context.executable.hasPrefix("/"),home.hasPrefix("/"),context.session.cwd.hasPrefix("/"),
              [home,context.executable,context.session.cwd].allSatisfy({!$0.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains)}) else{return nil}
        var arguments=["env","CODEX_HOME="+home]
        if let root=nativeRuntimeRoot {
            guard CodexNativeRuntimeRoot.validPath(root) else{return nil}
            arguments.append("AUTOAPPROVE_NATIVE_RUNTIME_ROOT="+root)
        }
        arguments += [context.executable,"--remote","unix://","resume",id]
        return "cd -- "+HookInstaller.quote(context.session.cwd)+" && "+arguments.map(HookInstaller.quote).joined(separator:" ")
    }
}

@MainActor public struct CodexSessionAttachmentServices {
    public var exit:() async throws ->Bool
    public var shellReady:() async throws ->Bool
    public var launch:() async throws ->Bool
    public var verify:() async throws ->Bool
    public var pause:(() async throws ->Bool)?
    public var pauseReady:(() async throws ->CodexGoal?)?
    public var prepareReplacement:(() async throws ->ProcessRecord)?
    public init(exit:@escaping()async throws->Bool,shellReady:@escaping()async throws->Bool,launch:@escaping()async throws->Bool,verify:@escaping()async throws->Bool,prepareReplacement:(()async throws->ProcessRecord)?=nil,pause:(()async throws->Bool)?=nil,pauseReady:(()async throws->CodexGoal?)?=nil) {
        self.exit=exit;self.shellReady=shellReady;self.launch=launch;self.verify=verify;self.prepareReplacement=prepareReplacement;self.pause=pause;self.pauseReady=pauseReady
    }
    public func advance(_ original:CodexSessionAttachment,save:(CodexSessionAttachment)throws->Void) async throws ->CodexSessionAttachment {
        var state=original
        func persist(_ phase:CodexSessionAttachment.Phase,_ detail:String)throws {
            state.phase=phase;state.detail=detail
            if phase == .review || phase == .connected {state.authorizedToolHosts=nil}
            if phase == .connected {state.toolHostShutdownWitnesses=nil}
            if phase == .exitReserved {
                state.context.deadline=Date().addingTimeInterval(120)
                state.toolHostShutdownWitnesses=state.authorizedToolHosts
            }
            try save(state)
        }
        do {
            try Task.checkCancellation()
            if state.phase == .pauseReserved {throw AppError.message("이전 Goal 중단 요청의 결과를 확인해주세요. 중단 입력을 반복하지 않습니다.")}
            if state.phase == .needsPause {
                guard state.goalBeforePause?.status == .active,let pause else{throw AppError.message("원래 Goal 중단 대상을 확인하지 못했습니다.")}
                state.pauseNotStarted=nil;state.context.deadline=Date().addingTimeInterval(120)
                try persist(.pauseReserved,"원래 Goal 일시정지·작업 중단 요청을 예약했습니다.")
                guard try await pause() else{throw RemoteHTTPError(409,"Goal 중단 요청의 전달 결과를 확인하지 못했습니다.",diagnostics:["delivery":"not_started"])}
                try persist(.waitingPause,"Goal 일시정지와 원래 작업의 실제 대기 상태를 확인합니다.")
            }
            if state.phase == .waitingPause {
                guard let deadline=state.context.deadline,Date()<deadline else{throw AppError.message("Goal 중단 확인 시간이 지났습니다. 요청을 반복하지 않습니다.")}
                guard let paused=try await pauseReady?() else{return state}
                state.pausedGoal=paused;state.context.deadline=Date().addingTimeInterval(120)
                try persist(state.replacesTab ? .needsTab:.ready,"원래 Goal 일시정지·작업 대기를 확인했습니다. 같은 대화를 서버에 연결합니다.")
                return state
            }
            if state.phase == .tabReserved {
                state.authorizedToolHosts=nil
                try persist(.review,"이전 복구 탭 준비의 결과를 확인하지 못했습니다. 새 탭을 반복해서 열거나 원래 Codex를 종료하지 않습니다.");return state
            }
            if state.phase == .needsTab {
                guard state.replacesTab,state.command != nil,let prepareReplacement else{throw AppError.message("같은 창의 복구 탭 준비를 지원하지 않습니다.")}
                state.preparationNotStarted=nil
                try persist(.tabReserved,"원래 Codex를 유지한 채 같은 창의 빈 복구 탭을 준비합니다.")
                let shell=try await prepareReplacement()
                guard SessionExitRecovery.isShell(shell),shell.isForeground,shell.pid>0,"/dev/"+shell.tty != state.context.session.tty else{throw AppError.message("복구 탭의 빈 원본 셸을 확인하지 못했습니다.")}
                state.context.shell=shell;state.context.deadline=Date().addingTimeInterval(120)
                try persist(.ready,"같은 창의 빈 복구 탭을 확인했습니다. 원래 대화를 연결할 준비가 됐습니다.")
                return state
            }
            if state.phase == .ready,state.replacesTab,let deadline=state.context.deadline,Date()>deadline {throw AppError.message("복구 탭 준비 뒤 확인 시간이 지났습니다. 원래 Codex를 종료하지 않습니다.")}
            if [.waitingShell,.verifying].contains(state.phase),let deadline=state.context.deadline,Date()>deadline {
                if state.phase == .verifying,try await verify() {try persist(.connected,"같은 대화의 서버 연결을 새 조회로 확인했습니다.")}
                else {try persist(.review,"자동 연결 확인 시간이 지났습니다. 같은 종료·실행 명령을 반복하지 않습니다.")}
                return state
            }
            if state.phase == .exitReserved {
                if let deadline=state.context.deadline,Date()<=deadline,try await shellReady() {
                    try persist(.waitingShell,"종료 요청은 반복하지 않고 원본 빈 셸이 돌아온 것을 확인했습니다.")
                } else {try persist(.review,"이전 종료 입력의 결과를 확인하지 못했습니다. 같은 입력을 반복하지 않습니다.");return state}
            }
            if state.phase == .launchReserved {
                if try await verify() {try persist(.connected,"실행 명령은 반복하지 않고 같은 대화의 서버 연결을 확인했습니다.")}
                else {try persist(.review,"이전 실행 입력의 결과를 확인하지 못했습니다. 같은 입력을 반복하지 않습니다.")}
                return state
            }
            if state.phase == .ready {
                guard state.command != nil else {throw AppError.message("원래 대화·실행 경로를 확인하지 못했습니다.")}
                try persist(.exitReserved,"원래 Codex 종료 요청을 예약했습니다.")
                guard try await exit() else {throw AppError.message("종료 요청 전달을 확인하지 못했습니다.")}
                state.authorizedToolHosts=nil
                try persist(.waitingShell,"원래 창에서 Codex가 종료되고 빈 셸이 돌아오기를 기다립니다.")
            }
            try Task.checkCancellation()
            if state.phase == .waitingShell {
                guard try await shellReady() else{return state}
                try persist(.launchReserved,"같은 창·홈·대화의 서버 연결 명령을 예약했습니다.")
                guard try await launch() else {throw AppError.message("같은 대화 실행 명령의 전달 결과를 확인하지 못했습니다.")}
                try persist(.verifying,"같은 대화와 원본 셸의 서버 연결을 확인합니다. 명령을 반복하지 않습니다.")
            }
            try Task.checkCancellation()
            if state.phase == .verifying,try await verify() {try persist(.connected,"기존 창·같은 대화의 관리형 서버 연결을 확인했습니다.")}
        } catch {
            state.authorizedToolHosts=nil
            if state.phase == .pauseReserved,(error as? RemoteHTTPError)?.diagnostics?["delivery"]=="not_started" {
                state.pauseNotStarted=true
                try persist(.review,"Goal 중단 입력이 시작되지 않았습니다. 아래 권한·원본 창 상태를 확인한 뒤 현재 로그인으로 세션 재연결을 다시 시도해주세요. "+String(error.localizedDescription.prefix(160)))
            } else if state.phase == .tabReserved,(error as? RemoteHTTPError)?.diagnostics?["delivery"]=="not_started" {
                state.preparationNotStarted=true
                try persist(.review,"복구 탭 준비가 시작되지 않았습니다. 권한·창 상태를 확인한 뒤 ‘현재 로그인으로 세션 재연결’로 다시 시도할 수 있습니다. "+String(error.localizedDescription.prefix(160)))
            } else {
                try persist(.review,"자동 연결 보류: "+String(error.localizedDescription.prefix(240)))
            }
        }
        return state
    }
}
