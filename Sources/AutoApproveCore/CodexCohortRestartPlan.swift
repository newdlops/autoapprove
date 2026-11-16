import Foundation

/// A restart may interrupt the whole source cohort, but only explicitly chosen
/// terminals change login homes. Portable group links follow those entries.
struct CodexCohortRestartPlan:Codable,Equatable,Sendable {
    struct Member:Codable,Equatable,Sendable {
        let runtimeID:String,pid:Int32,started:String,tty:String,entryID:UUID
    }
    let id:UUID
    let sourceHome:String,destinationHome:String
    let members:[Member]
    let movingEntryIDs:Set<UUID>
    let original:TerminalSessionProfile
    let restored:TerminalSessionProfile

    static func capture(sourceHome:String,destinationHome:String,candidates:[TerminalProfileCandidate],records:[ProcessRecord],
                        movingSessionIDs:Set<String>,groups:[SessionGroup])throws->Self {
        let source=try CodexAccountTransitionTarget.canonicalHome(sourceHome)
        let destination=try CodexAccountTransitionTarget.canonicalHome(destinationHome)
        guard !candidates.isEmpty,candidates.count<=128,!movingSessionIDs.isEmpty,
              Set(candidates.map(\.id)).count==candidates.count,
              movingSessionIDs.isSubset(of:Set(candidates.map(\.id))) else {
            throw AppError.message("재시작할 세션과 이동할 터미널을 다시 확인해주세요.")
        }
        var members:[Member]=[]
        for candidate in candidates {
            let entry=try candidate.entry.validated()
            guard entry.agent=="codex",entry.resumesConversation,
                  TerminalProfileGroup.normalizedHome(entry.providerHome,agent:"codex")==source,
                  let tty=candidate.tty,TerminalProfileLauncher.validTTY(tty),
                  let record=records.first(where:{$0.key==candidate.id && $0.agent == .codex && "/dev/"+$0.tty==tty}) else {
                throw AppError.message("종료하기 전에 모든 관련 터미널의 현재 Session ID와 실행 정보를 확인해야 합니다.")
            }
            members.append(.init(runtimeID:candidate.id,pid:record.pid,started:record.started,tty:tty,entryID:entry.id))
        }
        let snapshot=TerminalProfileGroup.capture(groups,candidates:candidates)
        let original=try TerminalSessionProfile(name:"Codex 재시작 전 복원 정보",entries:candidates.map(\.entry),groups:snapshot).validated()
        let moving=Set(candidates.filter{movingSessionIDs.contains($0.id)}.map{$0.entry.id})
        var restored=original
        restored.entries=original.entries.map {entry in
            var copy=entry
            if moving.contains(entry.id){copy.providerHome=destination}
            return copy
        }
        restored.groups=TerminalProfileGroup.selecting(snapshot,entries:restored.entries)
        return .init(id:UUID(),sourceHome:source,destinationHome:destination,members:members,movingEntryIDs:moving,
            original:original,restored:try restored.validated())
    }
}
