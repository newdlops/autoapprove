import Foundation
import AutoApproveCore

@MainActor final class DiagnosticPreviewRun {
    let root:URL
    var calls=0
    init(_ root:URL){self.root=root}
    func run(_ request:CodexDiagnosticRequest) async throws -> Data {
        calls+=1;try String(calls).write(to:root.appendingPathComponent("runs.txt"),atomically:true,encoding:.utf8)
        while FileManager.default.fileExists(atPath:root.appendingPathComponent("hold").path){try Task.checkCancellation();try await Task.sleep(for:.milliseconds(20))}
        if FileManager.default.fileExists(atPath:root.appendingPathComponent("fail").path){throw AppError.message("PRIVATE_RAW_FAILURE sk-secret-no-export")}
        let snapshot=try JSONSerialization.jsonObject(with:request.snapshot) as! JSONObject,summary=snapshot["summary"] as! JSONObject
        return try JSONSerialization.data(withJSONObject:["summary":"원격 Mac의 실제 진단 자료를 분석했습니다.","findings":[["severity":"info","title":"현재 연결과 과거 기록 구분","evidence":"관리형 연결 \(summary["managedSessions"] ?? 0)개, 과거 기록 \(summary["historicalRecords"] ?? 0)개","recommendation":"현재 연결이 확인된 실행과 종료된 원본 기록을 구분해 확인하세요."]],"limitations":["합성 진단 서비스입니다. 사용자 터미널이나 인증을 조회하지 않았습니다."]])
    }
}
@main struct DiagnosticsNetworkPreview {
    @MainActor static func main()async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let nodeIDs=["AA111111-1111-4111-8111-111111111111","BB222222-2222-4222-8222-222222222222"]
        var engines:[ApprovalEngine]=[],networks:[RemoteNetworkService]=[],info:[JSONObject]=[]
        defer{for network in networks{network.stop()};for engine in engines{engine.stop()}}
        for i in 0..<2 {
            let directory=root.appendingPathComponent("node-\(i)"),paths=AppPaths(directory:directory);try paths.prepare()
            let store=try AuditStore(path:paths.database);try store.set("webNodeID",nodeIDs[i]);try store.set("lanUpdateEnabled","false")
            let rows=ProcessDiscovery.parse("880 1 ttys081 880 881 Wed Nov 4 00:00:00 2026 /bin/zsh\n881 880 ttys081 881 881 Wed Nov 4 00:00:01 2026 /fixture/bin/codex")
            var current=ProcessDiscovery.sessions(rows)[0];current.cwd="/fixture/긴 레포 이름 프로젝트 한글🙂"
            var old=current;old.pid=777;old.id="process:777:historical";old.started="historical"
            let home=try CodexAccountTransitionTarget.canonicalHome(NSHomeDirectory()+"/.codex")
            var plan=CodexSessionAttachment(context:.init(session:old,process:rows[1],shell:rows[0],conversationID:"00000000-0000-4000-8000-000000000061"),home:home)
            plan.phase = .review;plan.detail="자동 연결 확인 시간이 지났습니다. 같은 종료·실행 명령을 반복하지 않습니다."
            plan.goalBeforePause=CodexGoal(threadId:"00000000-0000-4000-8000-000000000061",objective:"NEVER_EXPORT_GOAL",status:.active,createdAt:1,updatedAt:1)
            try store.set("codexSessionAttachments",String(decoding:JSONEncoder().encode([old.id:plan]),as:UTF8.self))
            let target=CodexAccountTransitionTarget(home:home,executable:"/fixture/bin/codex",witnesses:[.init(pid:current.pid,started:current.started,tty:current.tty,threadID:nil)])
            let run=DiagnosticPreviewRun(directory)
            let setup=CodexManagedServerServices(inspect:{_,_ in .init(phase:.running,version:"0.166.0",detail:"합성 서버",autoStartEnabled:true)},prepare:{_,_ in throw AppError.message("Unexpected mutation")})
            let engine=try ApprovalEngine(paths:paths,processReader:{rows},codexAccountTargets:{_ in [target]},codexManagedServers:setup,diagnosticServices:.init(run:{try await run.run($0)}))
            engines.append(engine);try engine.start(poll:false);engine.updateDiscovery([current],records:rows);await engine.ensureCodexManagedServers()
            guard engine.codexSessionAttachmentNotice==nil else{throw AppError.message("Historical exited PID still shown as current blocker")}
            var status=RemoteNetworkStatus()
            let network=RemoteNetworkService(engine:engine,nodeID:nodeIDs[i],name:i==0 ? "QA Diagnostics Mac A":"QA Diagnostics Mac B",bonjourEnabled:false,discoveryAddresses:{["127.0.0.1"]}) {status=$0}
            networks.append(network);try network.start(port:0)
            let deadline=Date().addingTimeInterval(5)
            while status.port==nil,Date()<deadline{try await Task.sleep(for:.milliseconds(20))}
            guard let port=status.port else{throw AppError.message("Owned HTTP listener failed")}
            info.append(["url":"http://127.0.0.1:\(port)","nodeID":nodeIDs[i],"directory":directory.path,"socket":paths.socket])
        }
        let data=try JSONSerialization.data(withJSONObject:["first":info[0],"second":info[1],"realTerminalActions":0],options:.sortedKeys)
        try data.write(to:root.appendingPathComponent("info.json"),options:.atomic)
        while true{try await Task.sleep(for:.seconds(60))}
    }
}
