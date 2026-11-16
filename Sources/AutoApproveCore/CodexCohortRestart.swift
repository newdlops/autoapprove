import Foundation

struct CodexCohortRestartState:Codable,Equatable {
    enum Phase:String,Codable {case captured,stopping,restarting,transferring,restoring,groups,completed,cancelled}
    let plan:CodexCohortRestartPlan
    var phase:Phase = .captured
    var stopAttempts=Set<UUID>()
    var restoreAttempts=Set<UUID>()
    var restoredTTYs:[UUID:String]=[:]
}

/// All observations must attest current process/conversation identity. A launch
/// acknowledgement is deliberately insufficient evidence of restoration.
@MainActor struct CodexCohortRestartServices {
    var validate:() async throws ->Void
    var originalAlive:(CodexCohortRestartPlan.Member) async throws ->Bool
    var stop:(CodexCohortRestartPlan.Member) async throws ->Void
    var serverRestarted:() async throws ->Bool
    var restartServer:() async throws ->Void
    var transferComplete:() async throws ->Bool
    /// Advances a separately journaled, idempotent storage handoff.
    var advanceTransfer:() async throws ->Void
    var observeRestored:(TerminalProfileEntry,CodexCohortRestartPlan.Member) async throws ->String?
    var restore:(TerminalProfileEntry,CodexCohortRestartPlan.Member) async throws ->Void
    var restoreGroups:(TerminalSessionProfile,[UUID:String]) async throws ->Void
}

/// One durable record is committed before any stop or launch. A lost launch
/// result is observed after restart rather than issued a second time.
@MainActor final class CodexCohortRestart {
    private let store:AuditStore
    private var running=Set<UUID>()
    private static let index="codexCohortRestartIDs"
    init(store:AuditStore){self.store=store}
    private func key(_ id:UUID)->String {"codexCohortRestart:"+id.uuidString.lowercased()}
    func state(_ id:UUID)throws->CodexCohortRestartState? {
        guard let text=store.value(key(id)) else{return nil}
        let value=try JSONDecoder().decode(CodexCohortRestartState.self,from:Data(text.utf8))
        guard value.plan.id==id,value.plan.members.count==value.plan.original.entries.count,
              Set(value.plan.members.map(\.entryID))==Set(value.plan.restored.entries.map(\.id)),
              value.stopAttempts.isSubset(of:Set(value.plan.members.map(\.entryID))),
              value.restoreAttempts.isSubset(of:value.stopAttempts),
              Set(value.restoredTTYs.keys).isSubset(of:value.restoreAttempts),
              value.restoredTTYs.values.allSatisfy(TerminalProfileLauncher.validTTY) else {
            throw AppError.message("세션 재시작 복원 기록이 일치하지 않습니다.")
        }
        _=try value.plan.original.validated();_=try value.plan.restored.validated()
        return value
    }
    private func save(_ value:CodexCohortRestartState)throws {
        try store.set(key(value.plan.id),String(decoding:JSONEncoder().encode(value),as:UTF8.self))
    }
    func active()throws->[CodexCohortRestartState] {
        let ids=try store.value(Self.index).map{try JSONDecoder().decode([UUID].self,from:Data($0.utf8))} ?? []
        return try ids.compactMap{try state($0)}.filter{$0.phase != .completed && $0.phase != .cancelled}
    }
    func cancel(_ id:UUID)throws {
        guard var value=try state(id),value.phase == .captured,!running.contains(id) else{throw AppError.message("종료·이전이 시작된 요청은 준비 취소할 수 없습니다. 저장된 단계에서 복원을 계속해주세요.")}
        value.phase = .cancelled;try save(value)
    }
    func prepare(_ plan:CodexCohortRestartPlan,context:CodexCohortRestartContext?=nil)throws->CodexCohortRestartState {
        guard try state(plan.id)==nil else{throw AppError.message("이미 저장된 재시작 요청입니다.")}
        let pending=try active()
        guard !pending.contains(where:{$0.plan.sourceHome==plan.sourceHome || $0.plan.destinationHome==plan.sourceHome || $0.plan.sourceHome==plan.destinationHome || $0.plan.destinationHome==plan.destinationHome}) else {
            throw AppError.message("이 로그인 홈의 이전 재시작·복원을 먼저 마쳐주세요.")
        }
        let value=CodexCohortRestartState(plan:plan)
        // Poll pending work only; completed records remain addressable by UUID.
        var ids=pending.map{$0.plan.id}
        ids.append(plan.id)
        // AuditStore commits both values in one SQLite transaction.
        var values=[key(plan.id):String(decoding:try JSONEncoder().encode(value),as:UTF8.self),Self.index:String(decoding:try JSONEncoder().encode(ids),as:UTF8.self)]
        if let context {
            guard context.planID==plan.id else{throw AppError.message("재시작 대상과 복원 정보가 다릅니다.")}
            values[CodexCohortRestartContext.key(plan.id)]=String(decoding:try JSONEncoder().encode(context),as:UTF8.self)
        }
        try store.setValues(values)
        return value
    }
    func advance(_ id:UUID,services:CodexCohortRestartServices) async throws ->CodexCohortRestartState {
        guard running.insert(id).inserted else{throw AppError.message("이 세션 재시작을 처리 중입니다.")}
        defer{running.remove(id)}
        guard var value=try state(id) else{throw AppError.message("저장된 재시작 복원 정보가 없습니다.")}
        guard value.phase != .cancelled else{throw AppError.message("취소된 세션 이동 준비입니다.")}
        if value.phase == .completed{return value}
        try Task.checkCancellation();try await services.validate()
        if value.phase == .captured {value.phase = .stopping;try save(value)}
        if value.phase == .stopping {
            for member in value.plan.members {
                if try await services.originalAlive(member) {
                    if !value.stopAttempts.contains(member.entryID) {
                        value.stopAttempts.insert(member.entryID);try save(value)
                    }
                    // A stop is a desired process state. Repeating it is safe
                    // only while the same PID/start witness is still alive.
                    try Task.checkCancellation();try await services.validate();try await services.stop(member)
                    if try await services.originalAlive(member){return value}
                }else if !value.stopAttempts.contains(member.entryID) {
                    value.stopAttempts.insert(member.entryID);try save(value)
                }
            }
            value.phase = .restarting;try save(value)
        }
        if value.phase == .restarting {
            if try await !services.serverRestarted() {
                try Task.checkCancellation();try await services.validate();try await services.restartServer()
                guard try await services.serverRestarted() else{return value}
            }
            value.phase = .transferring;try save(value)
        }
        if value.phase == .transferring {
            if try await !services.transferComplete() {
                try Task.checkCancellation();try await services.validate();try await services.advanceTransfer()
                guard try await services.transferComplete() else{return value}
            }
            value.phase = .restoring;try save(value)
        }
        if value.phase == .restoring {
            for entry in value.plan.restored.entries {
                guard let member=value.plan.members.first(where:{$0.entryID==entry.id}) else{throw AppError.message("원래 터미널의 복원 정보를 찾지 못했습니다.")}
                var tty=try await services.observeRestored(entry,member)
                if tty==nil,!value.restoreAttempts.contains(entry.id) {
                    value.restoreAttempts.insert(entry.id);try save(value)
                    try Task.checkCancellation();try await services.validate()
                    do {try await services.restore(entry,member)}
                    catch let error as RemoteHTTPError where error.diagnostics?["delivery"]=="not_started" || error.diagnostics?["command_delivery"]=="not_started" {
                        value.restoreAttempts.remove(entry.id);try save(value);throw error
                    }
                    tty=try await services.observeRestored(entry,member)
                }
                guard let tty,TerminalProfileLauncher.validTTY(tty) else{return value}
                value.restoreAttempts.insert(entry.id);value.restoredTTYs[entry.id]=tty;try save(value)
            }
            value.phase = .groups;try save(value)
        }
        if value.phase == .groups {
            try Task.checkCancellation();try await services.validate()
            try await services.restoreGroups(value.plan.restored,value.restoredTTYs)
            value.phase = .completed;try save(value)
        }
        return value
    }
}
