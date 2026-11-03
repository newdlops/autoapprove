import Foundation
import AutoApproveCore
@main struct AccountInspectionEngineCheck {
    @MainActor static func main() async throws {
        let args=CommandLine.arguments
        guard args.count==2 else{throw AppError.message("Owned CLI required")}
        let root=URL(fileURLWithPath:"/private/tmp/aa-account-cli-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let rows=ProcessDiscovery.parse("424242 1 ttys142 424242 424242 Wed Nov 4 00:00:01 2026 /fixture/bin/codex"),row=rows[0]
        let target=CodexAccountTransitionTarget(home:root.appendingPathComponent("codex-home").path,executable:"/fixture/bin/codex",witnesses:[.init(pid:row.pid,started:row.started,tty:"/dev/"+row.tty,threadID:nil)])
        var reads=0
        let service=CodexAccountInspectionServices(read:{t in
            await MainActor.run{reads+=1}
            return .init(home:t.home,identity:.init(provider:"ChatGPT",email:"owned@example.test",plan:"pro"),comparison:.same,connectedSessions:1)
        })
        let engine=try ApprovalEngine(paths:.init(directory:root),processReader:{rows},codexAccountTargets:{_ in [target]},codexAccountInspections:service)
        try engine.start();defer{engine.stop()}
        let cli=args[1],home=target.home,profile=root.path
        let output=try await Task.detached{
            try CommandRunner.run(cli,["doctor","--codex-account","--codex-home",home,"--home",profile],timeout:25)
        }.value
        guard output.status==0,let data=output.output.data(using:.utf8),
              let object=try JSONSerialization.jsonObject(with:data) as? JSONObject,
              let check=object["codexAccount"] as? JSONObject,check["comparison"] as? String=="same",
              (check["identity"] as? JSONObject)?["email"] as? String=="owned@example.test",reads==1 else{throw AppError.message("Private CLI account result missing")}
        guard engine.codexAccountTransitionStates.isEmpty,!engine.codexAccountTransitionEnabled,!engine.codexAccountTransitionBusy else{throw AppError.message("CLI read changed transition state")}
        print("{\"verified\":true,\"localSocketOnly\":true,\"accountReads\":1,\"transitionEffects\":0}")
    }
}

