import Foundation
import AutoApproveCore
@main struct DiagnosticLiveCheck {
    @MainActor static func main()async throws {
        let home=CommandLine.arguments.count>1 ? CommandLine.arguments[1]:NSHomeDirectory()+"/.codex"
        let rows=try ProcessDiscovery.readSessions(),originals=Set(ProcessDiscovery.sessions(rows).map(\.id))
        let executable=rows.first(where:{$0.agent == .codex && $0.executable.hasPrefix("/") && FileManager.default.isExecutableFile(atPath:$0.executable)})?.executable
        let snapshot:JSONObject=["schemaVersion":1,"node":["name":"진단 시험 Mac","release":["version":"0.2.249","build":276]],"summary":["managedSessions":3,"unverifiedSessions":0,"historicalRecords":1],"servers":[["id":"owned-server","phase":"running","version":"0.166.0","connectedSessions":3]],"attachments":[["sessionID":"retired-original","pid":777,"stage":"review","current":false,"detail":"과거 원본의 연결 확인 시간이 지났습니다."]],"checks":[["id":"current","state":"ok","detail":"현재 원본 3개의 서버 연결 증거를 확인했습니다."]]]
        let data=try JSONSerialization.data(withJSONObject:snapshot)
        let manager=CodexDiagnostics(services:.live(timeout:120)),id=UUID().uuidString
        _ = try manager.start(requestID:id,home:home,executable:executable,snapshot:data,question:"현재 연결과 과거 실패 기록을 구분하고 확인한 사실과 추정을 구분해주세요. 어떤 작업도 실행하지 마세요.")
        let end=Date().addingTimeInterval(125)
        while manager.busy,Date()<end {try await Task.sleep(for:.milliseconds(100))}
        guard let job=manager.status(requestID:id),job.phase=="completed",let result=job.result,!result.summary.isEmpty else{throw AppError.message(manager.status(requestID:id)?.message ?? "No diagnostic result")}
        let current=Set(ProcessDiscovery.sessions(try ProcessDiscovery.readSessions()).map(\.id))
        guard originals.isSubset(of:current) else{throw AppError.message("Original sessions changed during live analysis")}
        let output=URL(fileURLWithPath:".runtime/diagnostics-249/live-codex-result.json");try JSONEncoder().encode(job).write(to:output,options:.atomic)
        print("{\"verified\":true,\"realCodexInference\":true,\"structuredResult\":true,\"originalSessions\":\(originals.count),\"preserved\":\(originals.count),\"machineToolsDisabled\":true,\"syntheticSnapshotOnly\":true,\"findings\":\(result.findings.count)}")
    }
}
