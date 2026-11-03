import Foundation
import Darwin

/// Delivery reservations survive application restarts. Unknown exit/launch
/// outcomes require review rather than replaying terminal input.
public struct CodexSessionAttachment:Codable {
    public enum Phase:String,Codable {case ready,exitReserved,waitingShell,launchReserved,verifying,connected,review}
    public var context:SessionExitRecovery
    public var home:String
    public var phase:Phase = .ready
    public var detail:String = "원래 대화의 관리형 서버 연결을 준비합니다."
    public init(context:SessionExitRecovery,home:String) {self.context=context;self.home=home}
    /// Idle tool hosts can share the CLI's job group. Separate jobs and nested
    /// agents remain live work and must not be terminated by a session exit.
    public static func hasIndependentChildWork(process:ProcessRecord,records:[ProcessRecord])->Bool {
        let byPID=ProcessDiscovery.index(records)
        return records.contains {child in
            guard ProcessDiscovery.ancestors(of:child.parent,byPID:byPID).contains(where:{$0.key==process.key}) else{return false}
            if (child.executable as NSString).lastPathComponent=="codex-code-mode-host" {return false}
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
        guard let id=context.conversationID,UUID(uuidString:id) != nil,context.executable.hasPrefix("/"),home.hasPrefix("/"),context.session.cwd.hasPrefix("/"),
              [home,context.executable,context.session.cwd].allSatisfy({!$0.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains)}) else{return nil}
        return "cd -- "+HookInstaller.quote(context.session.cwd)+" && "+["env","CODEX_HOME="+home,context.executable,"--remote","unix://","resume",id].map(HookInstaller.quote).joined(separator:" ")
    }
}

@MainActor public struct CodexSessionAttachmentServices {
    public var exit:() async throws ->Bool
    public var shellReady:() async throws ->Bool
    public var launch:() async throws ->Bool
    public var verify:() async throws ->Bool
    public init(exit:@escaping()async throws->Bool,shellReady:@escaping()async throws->Bool,launch:@escaping()async throws->Bool,verify:@escaping()async throws->Bool) {
        self.exit=exit;self.shellReady=shellReady;self.launch=launch;self.verify=verify
    }
    public func advance(_ original:CodexSessionAttachment,save:(CodexSessionAttachment)throws->Void) async throws ->CodexSessionAttachment {
        var state=original
        func persist(_ phase:CodexSessionAttachment.Phase,_ detail:String)throws {
            state.phase=phase;state.detail=detail
            if phase == .exitReserved {state.context.deadline=Date().addingTimeInterval(120)}
            try save(state)
        }
        do {
            try Task.checkCancellation()
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
            try persist(.review,"자동 연결 보류: "+String(error.localizedDescription.prefix(240)))
        }
        return state
    }
}
