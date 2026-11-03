import Foundation
import CoreGraphics
import Darwin
import TerminalInputSupport

/// Only the explicit account-reconnect Goal pause may use this fallback.
/// Never switch transports after an attempted submission.
public enum TerminalGoalInterrupt {
    public struct Environment: Sendable {
        public var directAvailable: @Sendable () -> Bool
        public var keyboardAvailable: @Sendable () -> Bool
        public var direct: @Sendable (ScreenTarget,String) throws -> TerminalDelivery
        public var keyboard: @Sendable (ScreenTarget,String) throws -> TerminalDelivery
        public var requestPermission: @Sendable () -> Void
        public init(directAvailable: @escaping @Sendable () -> Bool, keyboardAvailable: @escaping @Sendable () -> Bool,
                    direct: @escaping @Sendable (ScreenTarget,String) throws -> TerminalDelivery,
                    keyboard: @escaping @Sendable (ScreenTarget,String) throws -> TerminalDelivery,
                    requestPermission: @escaping @Sendable () -> Void) {
            self.directAvailable=directAvailable;self.keyboardAvailable=keyboardAvailable
            self.direct=direct;self.keyboard=keyboard;self.requestPermission=requestPermission
        }
        public static var live: Self {
            .init(directAvailable:{TerminalInputClient.shared.isAvailable},
                  keyboardAvailable:{TerminalKeyboard.isAvailable && CGPreflightPostEventAccess()},
                  direct:{try TerminalDeviceInput.deliver(target:$0,agent:.codex,input:.init(kind:.escape),screen:$1)},
                  keyboard:{try TerminalGoalInterrupt.keyboard(target:$0,expected:$1)},
                  requestPermission:{Task {@MainActor in
                      _=TerminalKeyboard.requestPermission()
                      if !CGPreflightPostEventAccess() {_=CGRequestPostEventAccess()}
                  }})
        }
    }
    public static func deliver(target:ScreenTarget,expected:String,environment:Environment = .live)throws->TerminalDelivery {
        guard CodexGoalScreen.workingReady(expected),target.sourceIdentity != nil else{return .screenChanged}
        // Explicit Goal interruption can use the already-authorized keyboard
        // without relying on an asynchronously cached helper status.
        if environment.keyboardAvailable() {return try environment.keyboard(target,expected)}
        if environment.directAvailable() {return try environment.direct(target,expected)}
        environment.requestPermission()
        throw RemoteHTTPError(409,"Goal 중단 입력 전입니다. macOS 손쉬운 사용에서 실행 중인 AutoApprove를 허용한 뒤 ‘현재 로그인으로 세션 재연결’을 다시 눌러주세요.",diagnostics:["delivery":"not_started"])
    }
    private final class Submission: @unchecked Sendable {
        private let lock=NSLock();private var started=false
        func begin(){lock.lock();started=true;lock.unlock()}
        var didStart:Bool {lock.lock();defer{lock.unlock()};return started}
    }
    public static func keyboard(target:ScreenTarget,expected:String,environment:TerminalKeyboard.Environment = .live,
                                capture:@escaping @Sendable (Int32)throws->TTYInputIdentity = {try TTYInputIdentity.capture(pid:$0)},
                                userHasPriority:@escaping @Sendable ()->Bool = {NativeKeyboardActivity.live.hasPriority(terminal:.terminal)})throws->TerminalDelivery {
        let submission=Submission()
        func validate() throws {
            guard !userHasPriority(),let pid=target.sourcePID,let frozen=target.sourceIdentity,
                  target.jobPIDs.contains(pid),let started=target.sourceStarted else{throw AppError.message("원본 Codex 신원 또는 사용자 입력을 확인해주세요.")}
            let now=try capture(pid)
            guard now.pid==pid,now.processStart==started,now.sameProcess(as:frozen),now.uid==getuid(),now.effectiveUID==geteuid(),
                  now.processGroup==now.foregroundGroup else{throw AppError.message("원본 Codex의 전경 프로세스가 바뀌었습니다.")}
        }
        do {
            guard CodexGoalScreen.workingReady(expected) else{return .screenChanged}
            try validate()
            var keyboard=environment
            keyboard.postPair={pid,down,up in
                try validate()
                submission.begin()
                try environment.postPair(pid,down,up)
            }
            return try TerminalKeyboard.deliver(target:target,expected:expected,agent:.codex,input:.init(kind:.escape),environment:keyboard,goalWorkingComparison:true)
        } catch {
            if submission.didStart {throw error}
            throw RemoteHTTPError(409,"Goal 중단 키를 보내지 않았습니다. "+error.localizedDescription,diagnostics:["delivery":"not_started"])
        }
    }
}
