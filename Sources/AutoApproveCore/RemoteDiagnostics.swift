import Foundation
import CryptoKit

/// Only allowlisted operational fields enter this report. Never serialize a
/// session, transition, Goal, environment, authentication file or audit object.
public enum RemoteDiagnostics {
    public static func homeID(_ home:String)->String {String(SHA256.hash(data:Data(home.utf8)).map{String(format:"%02x",$0)}.joined().prefix(16))}
    public static func text(_ value:String,userHome:String=NSHomeDirectory(),limit:Int=500)->String {
        guard value.utf8.prefix(65_537).count<=65_536 else{return "[너무 긴 진단 항목 생략]"}
        var text=value.replacingOccurrences(of:userHome,with:"~")
        for (pattern,replacement) in [
            (#"/Users/[^/\s]+"#,"/Users/[user]"),
            (#"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,"[email]"),
            (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#,"Bearer [redacted]"),
            (#"\bsk-[A-Za-z0-9_-]{8,}"#,"[redacted]"),
            (#"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#,"[redacted]"),
            (#"(?i)(["']?(?:access_token|refresh_token|id_token|password|api_key|pin)["']?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;}\]]+)"#,"$1[redacted]"),
            (#"https?://[^\s]*[?][^\s]+"#,"[URL with query omitted]")
        ] {text=text.replacingOccurrences(of:pattern,with:replacement,options:.regularExpression)}
        return String(String(text.unicodeScalars.filter{!CharacterSet.controlCharacters.contains($0) || $0=="\n" || $0=="\t"}).prefix(max(0,limit)))
    }
    public static func currentReviews(_ states:[CodexSessionAttachment],records:[ProcessRecord])->[CodexSessionAttachment] {
        let live=Set(records.map(\.key))
        return states.filter{$0.phase == .review && live.contains($0.context.session.id)}
    }
    public static func isCurrent(_ state:CodexSessionAttachment,records:[ProcessRecord])->Bool {
        let live=Set(records.map(\.key))
        if live.contains(state.context.session.id) {return true}
        // The original Codex exits before the replacement launches. Its live
        // destination shell still witnesses an unfinished migration.
        return state.phase != .review && state.phase != .connected && live.contains(state.context.shell.key)
    }
    public static func report(nodeID:String,name:String,sessions:[AgentSession],records:[ProcessRecord]?,
                              targets:[CodexAccountTransitionTarget]?,servers:[String:CodexManagedServerStatus],
                              attachments:[CodexSessionAttachment],transitions:[String:CodexAccountTransitionState],
                              events:[AuditEvent],permissions:[JSONObject],errors:[String]=[],userHome:String=NSHomeDirectory()) -> JSONObject {
        func safe(_ text:String)->String {Self.text(text,userHome:userHome,limit:240)}
        let live=records.map{Set($0.map(\.key))},index=ProcessDiscovery.index(records ?? [])
        let active=Array(sessions.filter{$0.agent == .codex && $0.phase != .ended}.prefix(50))
        let permissionRows:[JSONObject]=permissions.prefix(8).map {row in ["id":safe(row["id"] as? String ?? "unknown"),"label":safe(row["label"] as? String ?? "권한"),"state":["ok","attention","unavailable"].contains(row["state"] as? String ?? "") ? row["state"] as! String:"unavailable","detail":safe(row["detail"] as? String ?? "")] }
        let sessionRows:[JSONObject]=active.map {session in
            let process=index[session.pid],same=process?.key==session.id && "/dev/"+(process?.tty ?? "")==session.tty
            let target=same ? targets?.first(where:{$0.witnesses.contains(where:{$0.pid==session.pid && $0.started==session.started && $0.tty==session.tty})}):nil
            let parents=process.map{ProcessDiscovery.ancestors(of:$0.parent,byPID:index)} ?? []
            let shell=parents.first(where:{$0.tty==process?.tty && SessionExitRecovery.isShell($0)})
            let login=parents.first(where:{$0.tty==process?.tty && ($0.executable as NSString).lastPathComponent=="login"})
            var row:JSONObject=["id":session.id,"project":Self.text(session.project,userHome:userHome,limit:100),"pid":Int(session.pid),"tty":safe(session.tty),"phase":session.phase.rawValue,
                "connection":target==nil ? "unverified":"managed","detail":target==nil ? "이 실행의 관리형 서버 연결 증거를 확인하지 못했습니다.":"원본 PID·시작·TTY와 서버 연결 증거를 확인했습니다.",
                "parentShell":shell.map{safe(($0.executable as NSString).lastPathComponent)} ?? (login==nil ? "확인 불가":"login 직접 실행"),
                "threadIdentified":target?.witnesses.first(where:{$0.pid==session.pid})?.threadID != nil || attachments.contains(where:{$0.context.session.id==session.id && $0.context.conversationID != nil})]
            if let target {row["serverID"]=homeID(target.home)}
            if same,let process {row["process"]=["parentPID":Int(process.parent),"processGroup":Int(process.processGroup),"foregroundGroup":Int(process.foregroundGroup),"foreground":process.isForeground,"started":safe(process.started),"independentChildWork":CodexSessionAttachment.hasIndependentChildWork(process:process,records:records ?? [])] as JSONObject}
            return row
        }
        let plans=Array(attachments.sorted{$0.context.session.pid<$1.context.session.pid}.prefix(50))
        let planRows:[JSONObject]=plans.map {plan in
            let current=records.map{Self.isCurrent(plan,records:$0)} ?? true
            return ["sessionID":plan.context.session.id,"pid":Int(plan.context.session.pid),"tty":safe(plan.context.session.tty),"project":Self.text(plan.context.session.project,userHome:userHome,limit:100),"stage":plan.phase.rawValue,
                    "detail":(live==nil ? "원본 실행 여부 확인 불가 · ":"")+safe(plan.detail),"current":current,
                    "pauseNotStarted":plan.pauseNotStarted==true,"pauseObserved":plan.pausedGoal != nil,"serverID":homeID(plan.home)]
        }
        let serverRows:[JSONObject]=servers.keys.sorted().prefix(8).map {home in
            let status=servers[home]!
            return ["id":homeID(home),"home":safe(home),"phase":status.phase.rawValue,"version":status.version as Any? ?? NSNull(),
                    "autoStartEnabled":status.autoStartEnabled as Any? ?? NSNull(),"connectedSessions":sessionRows.filter{$0["serverID"] as? String==homeID(home)}.count,"detail":safe(status.detail)]
        }
        let managed=sessionRows.filter{$0["connection"] as? String=="managed"}.count
        let historical=planRows.filter{$0["current"] as? Bool==false}.count
        let reviews=planRows.filter{$0["current"] as? Bool==true && $0["stage"] as? String=="review"}.count
        var checks:[JSONObject]=errors.prefix(12).map{["id":homeID($0),"label":"진단 자료 일부 확인 불가","state":"unavailable","detail":safe($0)]}
        if sessions.filter({$0.agent == .codex && $0.phase != .ended}).count>50 || attachments.count>50 {checks.append(["id":"bounded_report","label":"진단 표시 범위","state":"attention","detail":"세션과 연결 기록은 각각 처음 50개까지 표시합니다."])}
        checks.append(["id":"process_inventory","label":"원본 프로세스 조회","state":records==nil ? "unavailable":"ok","detail":records==nil ? "현재 실행을 확인하지 못했습니다. 과거 기록으로 단정하지 않습니다.":"PID·시작 시각·전경 그룹을 읽기 전용으로 확인했습니다."])
        checks.append(["id":"server_witnesses","label":"관리형 서버 연결","state":targets==nil ? "unavailable":managed<active.count ? "attention":"ok","detail":"Codex \(active.count)개 중 \(managed)개 연결 확인"+(reviews>0 ? " · 현재 보류 \(reviews)개":"")])
        if historical>0 {checks.append(["id":"historical_records","label":"과거 연결 기록","state":"ok","detail":"종료된 원본의 기록 \(historical)개를 현재 연결과 구분했습니다. 같은 종료·실행 입력을 다시 보내지 않습니다."])}
        let transitionRows:[JSONObject]=transitions.keys.sorted().prefix(8).map {home in
            let state=transitions[home]!
            return ["serverID":homeID(home),"phase":state.phase.rawValue,"held":state.held,"detail":safe(state.detail),"witnesses":state.witnesses.count,"threads":state.threads.count,"verified":state.verified]
        }
        let eventRows:[JSONObject]=events.filter{$0.summary=="Codex 세션 서버 연결"}.prefix(30).map {event in
            ["date":ISO8601DateFormatter().string(from:event.date),"sessionID":event.sessionID,"detail":safe(event.outcome)]
        }
        #if arch(arm64)
        let architecture="arm64"
        #else
        let architecture="x86_64"
        #endif
        var node:JSONObject=["id":nodeID,"name":safe(name),"pid":Int(ProcessInfo.processInfo.processIdentifier),"osVersion":ProcessInfo.processInfo.operatingSystemVersionString,"architecture":architecture]
        if let version=RemoteWebVersion.current,let data=try? JSONEncoder().encode(version),let value=try? JSONSerialization.jsonObject(with:data){node["release"]=value}
        return ["schemaVersion":1,"generatedAt":ISO8601DateFormatter().string(from:Date()),"node":node,
                "summary":["level":records==nil || targets==nil ? "unavailable":managed<active.count || reviews>0 || !errors.isEmpty ? "attention":"ok","title":"Codex \(active.count)개 · 관리형 연결 \(managed)개","managedSessions":managed,"standaloneSessions":0,"unverifiedSessions":active.count-managed,"historicalRecords":historical] as JSONObject,
                "permissions":permissionRows,"servers":serverRows,"sessions":sessionRows,"attachments":planRows,"transitions":transitionRows,"events":eventRows,"checks":checks]
    }
}
