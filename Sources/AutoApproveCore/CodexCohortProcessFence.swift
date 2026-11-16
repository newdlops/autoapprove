import Foundation
import Darwin

/// Preserve ancestry evidence before the parent exits. A reparented helper is
/// still ours only with its saved PID/start witness; a shared TTY is not proof.
enum CodexCohortProcessFence {
    static func capture(rootID:String,records:[ProcessRecord],previous:[ProcessRecord]=[])throws->[ProcessRecord] {
        var known=[String:ProcessRecord]()
        for record in previous {
            guard known[record.key]==nil else{throw AppError.message("보존한 하위 프로세스의 신원이 중복됩니다.")}
            known[record.key]=record
        }
        if let root=records.first(where:{$0.key==rootID}) {known[root.key]=root}
        var parents=Set(records.filter{known[$0.key] != nil}.map(\.pid))
        var changed=true
        while changed {
            changed=false
            for record in records where record.pid>1 && record.pid != getpid() && parents.contains(record.parent) && known[record.key]==nil {
                guard known.count<4096 else{throw AppError.message("종료할 하위 프로세스가 너무 많아 복원을 시작하지 않았습니다.")}
                known[record.key]=record;parents.insert(record.pid);changed=true
            }
        }
        return known.values.sorted{$0.key<$1.key}
    }
    static func live(_ captured:[ProcessRecord],records:[ProcessRecord])->[ProcessRecord] {
        let ids=Set(captured.map(\.key))
        return records.filter{ids.contains($0.key)}
    }
}
