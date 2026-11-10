import Foundation

public struct CodexAccountTransitionTarget: Equatable, Sendable {
    public var home: String
    public var executable: String
    public var witnesses: [CodexAccountTransitionWitness]
    public init(home: String, executable: String, witnesses: [CodexAccountTransitionWitness] = []) {
        self.home = home; self.executable = executable; self.witnesses = witnesses
    }
    public static func canonicalHome(_ home:String) throws -> String {
        guard home.hasPrefix("/"),home.utf8.count<=4096,!home.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else {throw AppError.message("Codex 설정 폴더의 전체 경로를 확인해주세요.")}
        return URL(fileURLWithPath:home).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
public struct CodexAccountTransitionWitness: Codable, Equatable, Sendable {
    public var pid: Int32
    public var started: String
    public var tty: String
    public var threadID: String?
    public init(pid: Int32, started: String, tty: String, threadID: String?) {
        self.pid = pid; self.started = started; self.tty = tty; self.threadID = threadID
    }
}
public struct CodexAccountTransitionThread: Codable, Equatable, Sendable {
    public var id: String
    public var turnID: String?
    public var turnStatus:String?
    public var active: Bool
    public var blocker: String?
    public var continuable:Bool?
    public var cwd:String?
    public var modelProvider:String?
    public var goal:CodexGoal?
    var needsQuiescence:Bool {active || blocker == "활성 Goal" || blocker == "백그라운드 작업"}
    var stopToken:String {turnID ?? "__autoapprove_idle__"}
    public init(id: String, turnID: String? = nil, active: Bool = false, blocker: String? = nil,continuable:Bool?=nil,cwd:String?=nil,modelProvider:String?=nil,goal:CodexGoal?=nil,turnStatus:String?=nil) {
        self.id = id; self.turnID = turnID; self.active = active; self.blocker = blocker
        self.continuable=continuable;self.cwd=cwd;self.modelProvider=modelProvider;self.goal=goal
        self.turnStatus=turnStatus
    }
    public static func ==(lhs:Self,rhs:Self)->Bool {
        // Usage can flush after a Goal pauses. Its identity/lifecycle/budget
        // revision remains the authority for the restart barrier.
        lhs.id==rhs.id && lhs.turnID==rhs.turnID && lhs.turnStatus==rhs.turnStatus && lhs.active==rhs.active && lhs.blocker==rhs.blocker &&
        lhs.continuable==rhs.continuable && lhs.cwd==rhs.cwd && lhs.modelProvider==rhs.modelProvider && lhs.goal?.revision==rhs.goal?.revision
    }
}
public struct CodexAccountTransitionObservation: Sendable {
    public var savedAccount: String?
    public var serverAccount: String?
    public var serverID: String
    public var threads: [CodexAccountTransitionThread]
    public var loginRefreshRequested = false
    public init(savedAccount: String?, serverAccount: String?, serverID: String, threads: [CodexAccountTransitionThread]) {
        self.savedAccount = savedAccount; self.serverAccount = serverAccount; self.serverID = serverID; self.threads = threads
    }
}
@MainActor public struct CodexAccountTransitionServices {
    public var observe: (CodexAccountTransitionTarget) async throws -> CodexAccountTransitionObservation
    public var interrupt: (CodexAccountTransitionTarget, String, String, String) async throws -> Void
    public var restart: (CodexAccountTransitionTarget, CodexAccountTransitionObservation) async throws -> Void
    public var verify: (CodexAccountTransitionTarget, [CodexAccountTransitionWitness], [CodexAccountTransitionThread]) async throws -> Int
    public var resume:((CodexAccountTransitionTarget,CodexAccountTransitionObservation,CodexAccountTransitionThread,String) async throws -> CodexAccountContinuationResult)?
    public init(observe: @escaping (CodexAccountTransitionTarget) async throws -> CodexAccountTransitionObservation,
                interrupt: @escaping (CodexAccountTransitionTarget, String, String, String) async throws -> Void,
                restart: @escaping (CodexAccountTransitionTarget, CodexAccountTransitionObservation) async throws -> Void,
                verify: @escaping (CodexAccountTransitionTarget, [CodexAccountTransitionWitness], [CodexAccountTransitionThread]) async throws -> Int,
                resume:((CodexAccountTransitionTarget,CodexAccountTransitionObservation,CodexAccountTransitionThread,String) async throws -> CodexAccountContinuationResult)?=nil) {
        self.observe = observe; self.interrupt = interrupt; self.restart = restart; self.verify = verify
        self.resume=resume
    }
}
public struct CodexAccountTransitionState: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case ready, stopping, waiting, restarting, reconnecting, resuming, complete, review, cancelled, unsupported }
    public var phase: Phase = .ready
    public var detail = "계정 변경을 기다립니다."
    public var account = ""
    public var serverID = ""
    public var originalAccount: String? = ""
    public var threads: [CodexAccountTransitionThread] = []
    public var witnesses: [CodexAccountTransitionWitness] = []
    public var reservations: [String: String] = [:]
    public var waitingThread: String?
    public var restartReserved = false
    public var since = Date()
    public var verified = 0
    public var loginRequestID: String?
    public var continuationHolds: [String:String]?
    public var resumeEnabled:Bool?
    public var resumeServerID:String?
    public var resumeReservations:[String:String]?
    public var resumeResults:[String:CodexAccountContinuationResult]?
    public var held: Bool { [.stopping, .waiting, .restarting, .reconnecting, .resuming, .review].contains(phase) }
    public var canCancel: Bool { held && ![.restarting, .reconnecting].contains(phase) }
    public init() {}
}
@MainActor public final class CodexAccountTransitionCoordinator {
    public private(set) var state: CodexAccountTransitionState
    public let target: CodexAccountTransitionTarget
    private let services: CodexAccountTransitionServices
    private let save: (CodexAccountTransitionState) throws -> Void
    private let changed: (CodexAccountTransitionState) -> Void
    private var checking = false
    public init(target: CodexAccountTransitionTarget, state: CodexAccountTransitionState? = nil,
                services: CodexAccountTransitionServices, save: @escaping (CodexAccountTransitionState) throws -> Void,
                changed: @escaping (CodexAccountTransitionState) -> Void = { _ in }) {
        self.target = target; self.state = state ?? .init(); self.services = services; self.save = save; self.changed = changed
        if self.state.held {
            // A previous process may have written a reservation and crashed at
            // any point around its side effect. Never infer that it was unsent.
            self.state.phase = .review
            self.state.detail = "이전 전환 결과를 확인해주세요. 중단·서버 전환 명령을 다시 보내지 않았습니다."
        }
    }
    public func check(now: Date = Date(), loginRequestID: String? = nil,preStoppedGoals:[CodexAccountTransitionThread]=[]) async {
        guard !checking else { return }
        checking = true; defer { checking = false }
        do {
            let observed = try await services.observe(target)
            try Task.checkCancellation()
            if state.phase == .review,!state.restartReserved,state.resumeServerID==nil {
                // A missing acknowledgement is not proof that the interrupt
                // failed. Inspect the exact reserved turns; never send again.
                try validate(observed)
                for (id,turn) in state.reservations {
                    guard let thread=observed.threads.first(where:{$0.id==id}),thread.stopToken==turn,!thread.needsQuiescence else {
                        state.detail="이전 중단 요청의 결과 확인 중입니다. 해당 작업·Goal·백그라운드 작업이 대기 상태가 되면 기존 전환을 이어갑니다. 중단 요청은 반복하지 않습니다."
                        changed(state);return
                    }
                }
                state.waitingThread=nil;state.phase = .stopping;state.since=now
                state.detail="이전 중단 결과를 현재 대화에서 확인했습니다. 기존 전환을 이어서 확인합니다."
                try persist();return
            }
            if state.resumeServerID != nil,[.resuming,.review].contains(state.phase) {
                try await continueInterruptedWork(observed);return
            }
            if state.restartReserved, [.reconnecting,.review].contains(state.phase) {
                guard observed.savedAccount == state.account else {
                    throw AppError.message("전환 중 로그인이 다시 바뀌었습니다. 현재 계정과 연결을 확인해주세요.")
                }
                if observed.serverID != state.serverID, observed.serverAccount == state.account, reconnectedThreads(observed) {
                    let verified = try await services.verify(target, state.witnesses, state.threads)
                    state.verified = verified
                    if verified == state.witnesses.count {
                        let fresh = try await services.observe(target)
                        try Task.checkCancellation()
                        guard fresh.serverID == observed.serverID, fresh.serverAccount == state.account,
                              fresh.savedAccount == state.account, reconnectedThreads(fresh) else {
                            throw AppError.message("재연결 확인 중 계정·서버·원래 대화 상태가 바뀌었습니다. 전환 명령은 반복하지 않았습니다.")
                        }
                        if state.resumeEnabled==true,!continuations.isEmpty {
                            state.phase = .resuming;state.resumeServerID=fresh.serverID
                            state.resumeReservations=[:];state.resumeResults=[:]
                            state.detail="기존 창 \(verified)개 연결 확인 · 전환으로 중단한 작업 \(continuations.count)개를 이어갑니다."
                        } else {
                            state.phase = .complete
                            state.detail = "새 로그인으로 서버 전환 · 기존 창 \(verified)개 재연결을 확인했습니다. 원래 대기 중이던 대화는 유지합니다."
                        }
                        try persist(); return
                    }
                }
                if state.phase == .review {
                    // A reserved restart is never retransmitted. New server,
                    // account, retained history and original process proof may
                    // still resolve its result without a manual cancellation.
                    changed(state);return
                }
                guard now.timeIntervalSince(state.since) < 120 else {
                    throw AppError.message("서버 전환 뒤 기존 창 \(state.verified)/\(state.witnesses.count)개의 연결만 확인했습니다. Mac에서 나머지 대화를 확인해주세요.")
                }
                state.detail = "새 계정과 기존 대화 재연결 확인 중 · \(state.verified)/\(state.witnesses.count)개"
                changed(state); return
            }
            if !state.held {
                let explicitLogin = loginRequestID != nil && loginRequestID != state.loginRequestID
                if state.phase == .cancelled, !explicitLogin, observed.savedAccount == nil || observed.savedAccount == state.account { return }
                guard let account = observed.savedAccount, account != observed.serverAccount || explicitLogin else {
                    // Preserve the completion summary until a later account
                    // change. Token refresh/session-id rotation is not a change.
                    if state.phase != .complete {
                        state = .init()
                        state.detail = observed.savedAccount == nil ? "로그인 완료를 기다립니다. 실행 중인 작업은 유지합니다." : "현재 로그인과 서버 계정이 같습니다."
                        changed(state)
                    }
                    return
                }
                var next = CodexAccountTransitionState()
                next.phase = .stopping; next.account = account; next.serverID = observed.serverID
                next.originalAccount = observed.serverAccount; next.loginRequestID = loginRequestID
                next.resumeEnabled=services.resume != nil
                next.threads = observed.threads.sorted { $0.id < $1.id }
                for original in preStoppedGoals {
                    guard let i=next.threads.firstIndex(where:{$0.id==original.id}),let prior=original.goal,prior.status == .active,
                          !next.threads[i].active,next.threads[i].blocker==nil,next.threads[i].turnID==original.turnID,
                          let goal=next.threads[i].goal,goal.status == .paused,goal.threadId==prior.threadId,goal.createdAt==prior.createdAt,goal.objective==prior.objective,goal.tokenBudget==prior.tokenBudget,
                          prior.instanceID==nil || goal.instanceID==prior.instanceID else{continue}
                    next.threads[i]=original;next.reservations[original.id]=original.stopToken
                }
                next.witnesses = target.witnesses; next.since = now
                next.continuationHolds=observed.threads.filter{!$0.active}.reduce(into:[:]){$0[$1.id]=$1.stopToken}
                next.detail = "계정 변경 감지 · \(next.threads.count)개 대화를 순차 중단할 준비 중"
                state = next
                // Publishing the hold comes before any side effect. The next
                // check gives the engine time to drain its pending input jobs.
                changed(state); try persist(); return
            }
            try validate(observed)
            var continuationHolds=state.continuationHolds ?? [:]
            for thread in observed.threads where !thread.active {continuationHolds[thread.id]=thread.stopToken}
            if continuationHolds != state.continuationHolds {state.continuationHolds=continuationHolds;try persist()}
            if let waiting = state.waitingThread {
                guard let thread = observed.threads.first(where: { $0.id == waiting }) else {
                    throw AppError.message("중단 중 대화 연결이 바뀌었습니다.")
                }
                guard now.timeIntervalSince(state.since) < 120 else {
                    throw AppError.message("작업의 정상 중단을 확인하지 못했습니다. 다음 작업과 서버 전환은 보류했습니다.")
                }
                if thread.needsQuiescence {
                    state.detail = "현재 작업의 정상 종료를 기다립니다. 다음 대화는 아직 중단하지 않았습니다."
                    changed(state); return
                }
                state.waitingThread = nil; state.phase = .stopping; state.since = now
                state.detail = "작업 대기 확인 · 다음 대화 확인 중"
                try persist(); return
            }
            if let thread = observed.threads.sorted(by: { $0.id < $1.id }).first(where: \.needsQuiescence) {
                let turn=thread.stopToken
                guard !turn.isEmpty, state.reservations[thread.id] == nil else {
                    throw AppError.message("중단 뒤 새 작업이 시작됐거나 실행 차례를 확인하지 못했습니다. 자동 전환을 멈췄습니다.")
                }
                state.waitingThread = thread.id; state.reservations[thread.id] = turn
                state.phase = .waiting; state.since = now
                state.detail = "작업 \(state.reservations.count)/\(state.threads.filter(\.needsQuiescence).count)개 순차 대기 전환 · 정상 종료 확인 중"
                try persist()
                try await services.interrupt(target, state.serverID, thread.id, turn)
                return
            }
            if let blocker = observed.threads.compactMap(\.blocker).first {
                state.phase = .waiting
                state.detail = "모든 작업 중단 확인 · \(blocker)이 남아 서버 전환을 기다립니다."
                changed(state); return
            }
            // The RPC walk is not an atomic server maintenance lock. A second
            // complete barrier catches changes during the first inspection;
            // the adapter repeats it on its own connection before lifecycle.
            var fresh = try await services.observe(target)
            try Task.checkCancellation(); try validate(fresh)
            guard fresh.threads == observed.threads else {
                throw AppError.message("전환 직전 대화 상태가 바뀌었습니다. 서버를 전환하지 않았습니다.")
            }
            state.restartReserved = true; state.phase = .restarting; state.since = now
            state.detail = "모든 작업 대기 확인 · 공통 서버를 새 로그인으로 전환 중"
            try persist()
            fresh.loginRefreshRequested = state.loginRequestID != nil
            let lifecycleStarted=Date()
            try await services.restart(target, fresh)
            state.phase = .reconnecting
            state.since=now.addingTimeInterval(max(0,Date().timeIntervalSince(lifecycleStarted)))
            state.detail = "서버 전환 요청 완료 · 원래 창과 대화의 재연결을 확인합니다."
            try persist()
        } catch {
            if state.phase == .complete {
                // A later read-only poll cannot make a completed restart
                // uncertain again or re-arm its already consumed login.
                changed(state); return
            }
            if state.phase == .cancelled {
                // A logout or transient inspection failure is not a new login.
                // Keep the cancellation identity and all effect reservations.
                changed(state); return
            }
            state.phase = state.held || state.restartReserved || !state.reservations.isEmpty ? .review : .unsupported
            state.detail = error is CancellationError ? "전환 확인이 중단됐습니다. 명령을 반복하지 않고 현재 연결을 확인해주세요." : error.localizedDescription
            // A failed journal write must itself hold automation. In-memory
            // state remains conservative even when the disk cannot be updated.
            try? save(state); changed(state)
        }
    }
    public func cancel() throws {
        guard state.canCancel, !checking else { throw AppError.message("진행 중인 서버 전환 결과를 먼저 기다려주세요.") }
        var next = state
        next.phase = .cancelled
        next.detail = "나머지 자동 전환을 중지했습니다. 이미 중단한 작업은 대기 상태로 유지합니다."
        try save(next); state = next; changed(state)
    }
    func requireReview(_ detail: String) throws {
        state.phase = .review; state.detail = detail
        // The coordinator, published controls and restored journal must agree.
        // A vanished target cannot remain reconnecting behind a review button.
        try persist()
    }
    func targetUnavailable(now:Date=Date()) throws {
        if state.restartReserved,state.phase == .reconnecting,now.timeIntervalSince(state.since)<120 {
            state.detail="서버 재시작 뒤 기존 창의 연결을 기다립니다. 전환 명령은 반복하지 않습니다."
            changed(state);return
        }
        try requireReview("원래 Codex 서버·창을 찾지 못했습니다. 자동 명령을 반복하지 않고 대기합니다.")
    }
    private func persist() throws { try save(state); changed(state) }
    private var continuations:[CodexAccountTransitionThread] {
        state.threads.filter{$0.continuable==true && ($0.active || $0.goal?.status == .active) && state.reservations[$0.id]==$0.stopToken}.sorted{$0.id<$1.id}
    }
    private func continueInterruptedWork(_ observed:CodexAccountTransitionObservation) async throws {
        guard state.resumeEnabled==true,let resume=services.resume,
              observed.savedAccount==state.account,observed.serverAccount==state.account,observed.serverID==state.resumeServerID else {
            throw AppError.message("작업을 이어가기 전 계정·서버 연결이 바뀌었습니다. 요청을 반복하지 않고 대기합니다.")
        }
        let reservations=state.resumeReservations ?? [:],results=state.resumeResults ?? [:]
        guard reservations.keys.allSatisfy({results[$0] != nil}) else {
            throw AppError.message("이어서 진행 요청의 전달 결과를 확인하지 못했습니다. 같은 요청을 자동으로 다시 보내지 않습니다.")
        }
        guard let original=continuations.first(where:{results[$0.id]==nil}) else {
            state.phase = .complete
            let resumed=results.values.filter{$0 != .skipped}.count,skipped=results.count-resumed
            state.detail="새 로그인으로 기존 창 \(state.verified)개 연결 · 중단 작업 \(resumed)개 이어가기 완료"+(skipped>0 ? " · 상태가 바뀐 \(skipped)개는 유지했습니다.":". 원래 대기 중이던 대화는 유지합니다.")
            try persist();return
        }
        let receipt=UUID().uuidString
        state.phase = .resuming
        state.resumeReservations=reservations.merging([original.id:receipt]){_,new in new}
        state.detail="전환으로 중단한 작업 이어가기 · \(results.count)/\(continuations.count)개"
        try persist();try Task.checkCancellation()
        var originalTarget=target;originalTarget.witnesses=state.witnesses
        let result=try await resume(originalTarget,observed,original,receipt)
        state.resumeResults=results.merging([original.id:result]){_,new in new}
        try persist()
    }
    private func reconnectedThreads(_ observed: CodexAccountTransitionObservation) -> Bool {
        // Official TUIs resume their own in-memory thread IDs. The shared
        // server owns rollout files, so a per-TUI rollout FD is not required.
        // Require every original conversation and every original process,
        // then repeat the full account/server/membership barrier before done.
        (state.threads.isEmpty || !observed.threads.isEmpty) &&
            Set(observed.threads.map(\.id)).isSubset(of:Set(state.threads.map(\.id))) &&
            observed.threads.allSatisfy { !$0.active && $0.blocker == nil }
    }
    private func validate(_ observed: CodexAccountTransitionObservation) throws {
        guard observed.savedAccount == state.account, observed.serverID == state.serverID, observed.serverAccount == state.originalAccount,
              Set(observed.threads.map(\.id)) == Set(state.threads.map(\.id)),
              observed.threads.count == state.threads.count else {
            throw AppError.message("로그인·서버·대화 목록이 전환 준비 중 바뀌었습니다. 현재 연결을 확인해주세요.")
        }
        for thread in observed.threads {
            guard thread.turnID == state.threads.first(where: { $0.id == thread.id })?.turnID else {
                throw AppError.message("중단 중 새 작업이 시작됐습니다. 새 작업을 임의로 중단하지 않았습니다.")
            }
        }
    }
}
