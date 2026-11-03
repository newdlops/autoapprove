import Foundation
import AutoApproveCore
@MainActor final class PreparationGate {
    var entered=false,runs=0
    private var continuation:CheckedContinuation<Void,Never>?
    func wait()async {entered=true;await withCheckedContinuation{continuation=$0}}
    func release(){continuation?.resume();continuation=nil}
}
@main struct DiagnosticPreparationCheck {
    @MainActor static func main()async throws {
        let root=URL(fileURLWithPath:"/private/tmp/aa-diag-prep-"+UUID().uuidString),gate=PreparationGate()
        defer{try? FileManager.default.removeItem(at:root)}
        let services=CodexManagedServerServices(inspect:{_,_ in await gate.wait();return .init(phase:.running,version:"0.166.0",detail:"Owned",autoStartEnabled:true)},prepare:{_,_ in throw AppError.message("Unexpected mutation")})
        let runner=CodexDiagnosticServices(run:{_ in await MainActor.run{gate.runs+=1};return Data(#"{"summary":"Owned","findings":[],"limitations":[]}"#.utf8)})
        let engine=try ApprovalEngine(paths:.init(directory:root),processReader:{[]},codexAccountTargets:{_ in []},codexManagedServers:services,diagnosticServices:runner)
        defer{gate.release();engine.stop()}
        let id=UUID().uuidString,node=UUID().uuidString,start=Task{try await engine.diagnosticCodexAction(["action":"start","requestID":id,"question":"Read state"],nodeID:node,name:"Owned")}
        defer{start.cancel()}
        let deadline=Date().addingTimeInterval(3)
        while !gate.entered,Date()<deadline {try await Task.sleep(for:.milliseconds(10))}
        guard gate.entered else{throw AppError.message("Preparation did not start")}
        let observed=try engine.diagnosticCodexStatus(requestID:id)
        guard let job=observed["job"] as? JSONObject,job["phase"] as? String=="running" else{throw AppError.message("In-flight preparation is invisible after request response loss")}
        let cancelled=try await engine.diagnosticCodexAction(["action":"cancel","requestID":id],nodeID:node,name:"Owned")
        guard (cancelled["job"] as? JSONObject)?["phase"] as? String=="cancelled" else{throw AppError.message("Cannot cancel preparation")}
        gate.release();_ = try await start.value;try await Task.sleep(for:.milliseconds(200))
        guard gate.runs==0 else{throw AppError.message("Cancelled preparation launched a Codex")}
        let repeated=try await engine.diagnosticCodexAction(["action":"start","requestID":id,"question":"Read state"],nodeID:node,name:"Owned")
        guard (repeated["job"] as? JSONObject)?["phase"] as? String=="cancelled",gate.runs==0 else{throw AppError.message("Cancelled request was replayed")}
        print("{\"verified\":true,\"preparationObservable\":true,\"cancelledBeforeCodex\":true,\"replayed\":false}")
    }
}
