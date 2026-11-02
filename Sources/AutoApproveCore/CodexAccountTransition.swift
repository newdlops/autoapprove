import Foundation

public struct CodexAccountTransitionTarget: Equatable, Sendable {
    public var home: String
    public var executable: String
    public var witnesses: [CodexAccountTransitionWitness]
    public init(home: String, executable: String, witnesses: [CodexAccountTransitionWitness] = []) {
        self.home = home; self.executable = executable; self.witnesses = witnesses
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
    public var active: Bool
    public var blocker: String?
    public init(id: String, turnID: String? = nil, active: Bool = false, blocker: String? = nil) {
        self.id = id; self.turnID = turnID; self.active = active; self.blocker = blocker
    }
}
public struct CodexAccountTransitionObservation: Sendable {
    public var savedAccount: String?
    public var serverAccount: String
    public var serverID: String
    public var threads: [CodexAccountTransitionThread]
    public init(savedAccount: String?, serverAccount: String, serverID: String, threads: [CodexAccountTransitionThread]) {
        self.savedAccount = savedAccount; self.serverAccount = serverAccount; self.serverID = serverID; self.threads = threads
    }
}
@MainActor public struct CodexAccountTransitionServices {
    public var observe: (CodexAccountTransitionTarget) async throws -> CodexAccountTransitionObservation
    public var interrupt: (CodexAccountTransitionTarget, String, String, String) async throws -> Void
    public var restart: (CodexAccountTransitionTarget, CodexAccountTransitionObservation) async throws -> Void
    public var verify: (CodexAccountTransitionTarget, [CodexAccountTransitionWitness]) async throws -> Int
    public init(observe: @escaping (CodexAccountTransitionTarget) async throws -> CodexAccountTransitionObservation,
                interrupt: @escaping (CodexAccountTransitionTarget, String, String, String) async throws -> Void,
                restart: @escaping (CodexAccountTransitionTarget, CodexAccountTransitionObservation) async throws -> Void,
                verify: @escaping (CodexAccountTransitionTarget, [CodexAccountTransitionWitness]) async throws -> Int) {
        self.observe = observe; self.interrupt = interrupt; self.restart = restart; self.verify = verify
    }
}
public struct CodexAccountTransitionState: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case ready, stopping, waiting, restarting, reconnecting, complete, review, cancelled, unsupported }
    public var phase: Phase = .ready
    public var detail = "계정 변경을 기다립니다."
    public var account = ""
    public var serverID = ""
    public var originalAccount = ""
    public var threads: [CodexAccountTransitionThread] = []
    public var witnesses: [CodexAccountTransitionWitness] = []
    public var reservations: [String: String] = [:]
    public var waitingThread: String?
    public var restartReserved = false
    public var since = Date()
    public var verified = 0
    public var held: Bool { [.stopping, .waiting, .restarting, .reconnecting, .review].contains(phase) }
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
    public func check(now: Date = Date()) async {
        guard !checking, state.phase != .review else { return }
        checking = true; defer { checking = false }
        do {
            let observed = try await services.observe(target)
            try Task.checkCancellation()
            if state.restartReserved, state.phase == .reconnecting {
                guard observed.savedAccount == state.account else {
                    throw AppError.message("전환 중 로그인이 다시 바뀌었습니다. 현재 계정과 연결을 확인해주세요.")
                }
                if observed.serverID != state.serverID, observed.serverAccount == state.account {
                    let verified = try await services.verify(target, state.witnesses)
                    state.verified = verified
                    if verified == state.witnesses.count {
                        state.phase = .complete
                        state.detail = "새 로그인으로 서버 전환 · 기존 창 \(verified)개 재연결을 확인했습니다. 중단한 작업은 대기 상태입니다."
                        try persist(); return
                    }
                }
                guard now.timeIntervalSince(state.since) < 120 else {
                    throw AppError.message("서버 전환 뒤 기존 창 \(state.verified)/\(state.witnesses.count)개의 연결만 확인했습니다. Mac에서 나머지 대화를 확인해주세요.")
                }
                state.detail = "새 계정과 기존 대화 재연결 확인 중 · \(state.verified)/\(state.witnesses.count)개"
                changed(state); return
            }
            if !state.held {
                if state.phase == .cancelled, observed.savedAccount == nil || observed.savedAccount == state.account { return }
                guard let account = observed.savedAccount, account != observed.serverAccount else {
                    // Preserve the completion summary until a later account
                    // change. Token refresh/session-id rotation is not a change.
                    if state.phase != .complete {
                        state = .init()
                        state.detail = observed.savedAccount == nil ? "로그인 완료를 기다립니다. 실행 중인 작업은 유지합니다." : "현재 로그인과 서버 계정이 같습니다."
                        changed(state)
                    }
                    return
                }
                let missing = target.witnesses.filter { $0.threadID == nil }.count
                guard missing == 0 else {
                    state.phase = .unsupported
                    state.detail = "대화 ID를 확인할 수 없는 Codex 창 \(missing)개가 있습니다. 빈 대화 창을 닫거나 대화 기록의 연결을 확인한 뒤 ‘현재 로그인 확인’을 눌러주세요. 작업·서버는 변경하지 않았습니다."
                    changed(state); return
                }
                var next = CodexAccountTransitionState()
                next.phase = .stopping; next.account = account; next.serverID = observed.serverID
                next.originalAccount = observed.serverAccount
                next.threads = observed.threads.sorted { $0.id < $1.id }; next.witnesses = target.witnesses; next.since = now
                next.detail = "계정 변경 감지 · \(next.threads.count)개 대화를 순차 중단할 준비 중"
                state = next
                // Publishing the hold comes before any side effect. The next
                // check gives the engine time to drain its pending input jobs.
                changed(state); try persist(); return
            }
            try validate(observed)
            if let waiting = state.waitingThread {
                guard let thread = observed.threads.first(where: { $0.id == waiting }) else {
                    throw AppError.message("중단 중 대화 연결이 바뀌었습니다.")
                }
                guard now.timeIntervalSince(state.since) < 120 else {
                    throw AppError.message("작업의 정상 중단을 확인하지 못했습니다. 다음 작업과 서버 전환은 보류했습니다.")
                }
                if thread.active {
                    state.detail = "현재 작업의 정상 종료를 기다립니다. 다음 대화는 아직 중단하지 않았습니다."
                    changed(state); return
                }
                state.waitingThread = nil; state.phase = .stopping; state.since = now
                state.detail = "작업 대기 확인 · 다음 대화 확인 중"
                try persist(); return
            }
            if let thread = observed.threads.sorted(by: { $0.id < $1.id }).first(where: \.active) {
                guard let turn = thread.turnID, !turn.isEmpty, state.reservations[thread.id] == nil else {
                    throw AppError.message("중단 뒤 새 작업이 시작됐거나 실행 차례를 확인하지 못했습니다. 자동 전환을 멈췄습니다.")
                }
                state.waitingThread = thread.id; state.reservations[thread.id] = turn
                state.phase = .waiting; state.since = now
                state.detail = "작업 \(state.reservations.count)/\(state.threads.filter(\.active).count)개 순차 중단 · 정상 종료 확인 중"
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
            let fresh = try await services.observe(target)
            try Task.checkCancellation(); try validate(fresh)
            guard fresh.threads == observed.threads else {
                throw AppError.message("전환 직전 대화 상태가 바뀌었습니다. 서버를 전환하지 않았습니다.")
            }
            state.restartReserved = true; state.phase = .restarting; state.since = now
            state.detail = "모든 작업 대기 확인 · 공통 서버를 새 로그인으로 전환 중"
            try persist()
            try await services.restart(target, fresh)
            state.phase = .reconnecting
            state.detail = "서버 전환 요청 완료 · 원래 창과 대화의 재연결을 확인합니다."
            try persist()
        } catch {
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
    private func persist() throws { try save(state); changed(state) }
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
