import Foundation
import AutoApproveCore
@main struct DiagnosticMultiHomeCheck {
 @MainActor static func main()async throws {
  let root=URL(fileURLWithPath:"/private/tmp/aa-diag-homes-"+UUID().uuidString),paths=AppPaths(directory:root)
  try paths.prepare();defer{try? FileManager.default.removeItem(at:root)}
  let homeA=try CodexAccountTransitionTarget.canonicalHome(NSHomeDirectory()+"/.codex"),directory=root.appendingPathComponent("second-home")
  try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);let homeB=try CodexAccountTransitionTarget.canonicalHome(directory.path)
  guard homeA<homeB else{throw AppError.message("Owned test needs default home first")}
  let rows=ProcessDiscovery.parse("880 1 ttys081 880 881 Wed Nov 4 00:00:00 2026 /bin/zsh\n881 880 ttys081 881 881 Wed Nov 4 00:00:01 2026 /fixture/bin/codex\n882 880 ttys082 882 882 Wed Nov 4 00:00:02 2026 /fixture/bin/codex")
  let sessions=ProcessDiscovery.sessions(rows)
  var plan=CodexSessionAttachment(context:.init(session:sessions[0],process:rows[1],shell:rows[0],conversationID:nil),home:homeA)
  plan.phase = .review;plan.detail="LIVE_REVIEW_MUST_REMAIN"
  let store=try AuditStore(path:paths.database);try store.set("codexSessionAttachments",String(decoding:JSONEncoder().encode([sessions[0].id:plan]),as:UTF8.self))
  let target=CodexAccountTransitionTarget(home:homeB,executable:"/fixture/bin/codex",witnesses:[.init(pid:sessions[1].pid,started:sessions[1].started,tty:sessions[1].tty,threadID:nil)])
  let services=CodexManagedServerServices(inspect:{_,_ in .init(phase:.running,version:"0.166.0",detail:"Owned",autoStartEnabled:true)},prepare:{_,_ in .init(phase:.running,version:"0.166.0",detail:"Owned",autoStartEnabled:true)})
  let engine=try ApprovalEngine(paths:paths,processReader:{rows},codexAccountTargets:{_ in [target]},codexManagedServers:services);defer{engine.stop()}
  engine.updateDiscovery([sessions[1]],records:rows)
  _ = try await engine.prepareCodexManagedServer(home:homeB)
  await engine.ensureCodexManagedServers()
  guard engine.codexSessionAttachmentNotice?.contains("LIVE_REVIEW_MUST_REMAIN")==true else{throw AppError.message("Healthy later home cleared another home's live review")}
  print("{\"verified\":true,\"healthyHomePreservesOtherLiveReview\":true}")
 }
}
