import Foundation
import AutoApproveCore

extension ApprovalTests {
    func testRemoteDiagnosticsAllowlistPrivacyAndCurrentEvidence() throws {
        let rows=ProcessDiscovery.parse("""
        880 1 ttys081 880 881 Wed Nov 4 00:00:00 2026 /bin/zsh
        881 880 ttys081 881 881 Wed Nov 4 00:00:01 2026 /fixture/bin/codex
        882 880 ttys082 882 882 Wed Nov 4 00:00:02 2026 /fixture/bin/codex
        """)
        let user="/fixture/private-user",home=user+"/.codex"
        func session(_ row:ProcessRecord)->AgentSession {.init(id:row.key,agent:.codex,pid:row.pid,started:row.started,tty:"/dev/"+row.tty,cwd:user+"/repo",terminal:.terminal)}
        let a=session(rows[1]),b=session(rows[2])
        var old=a;old.pid=999;old.id="process:999:old";old.started="old"
        var plan=CodexSessionAttachment(context:.init(session:old,process:rows[1],shell:rows[0],conversationID:"00000000-0000-4000-8000-000000000061"),home:home)
        plan.phase = .review;plan.detail="Bearer secret-token-123 sk-abcdefghijk access_token=abc123 api_key=secret \(user) owner@example.test"
        plan.goalBeforePause=CodexGoal(threadId:"00000000-0000-4000-8000-000000000061",objective:"NEVER_EXPORT_PRIVATE_GOAL",status:.active,createdAt:1,updatedAt:1)
        let target=CodexAccountTransitionTarget(home:home,executable:"/fixture/bin/codex",witnesses:[.init(pid:a.pid,started:a.started,tty:a.tty,threadID:nil)])
        let privateEvent=AuditEvent(sessionID:a.id,summary:"PRIVATE_TERMINAL_TEXT",outcome:"SECRET_AUTH",source:"fixture")
        let report=RemoteDiagnostics.report(nodeID:"node",name:"Mac",sessions:[a,b],records:rows,targets:[target],servers:[home:.init(phase:.running,version:"0.166.0",detail:"Running",autoStartEnabled:true)],attachments:[plan],transitions:[:],events:[privateEvent],permissions:[["id":"AX","label":"Access","state":"ok","detail":"Ready","auth":"NEVER_EXPORT_AUTH"]],userHome:user)
        let text=String(decoding:try JSONSerialization.data(withJSONObject:report),as:UTF8.self)
        for secret in ["NEVER_EXPORT_PRIVATE_GOAL","PRIVATE_TERMINAL_TEXT","SECRET_AUTH","NEVER_EXPORT_AUTH","secret-token-123","sk-abcdefghijk","abc123","api_key=secret",user,"owner@example.test"] {try expectFalse(text.contains(secret),"Diagnostic export leaked "+secret)}
        let sessions=report["sessions"] as! [JSONObject]
        try expectEqual(sessions[0]["connection"] as? String,"managed");try expectEqual(sessions[1]["connection"] as? String,"unverified")
        let plans=report["attachments"] as! [JSONObject];try expectEqual(plans[0]["current"] as? Bool,false)
        try expectEqual((report["summary"] as! JSONObject)["historicalRecords"] as? Int,1)
        try expect(RemoteDiagnostics.currentReviews([plan],records:rows).isEmpty)
        plan.phase = .waitingShell
        try expect(RemoteDiagnostics.isCurrent(plan,records:rows),"Live destination shell witnesses an in-flight migration after original exit")
        plan.phase = .review
        try expectFalse(RemoteDiagnostics.isCurrent(plan,records:rows),"An old review cannot borrow its surviving shell as current evidence")
        plan.context.session=a;try expectEqual(RemoteDiagnostics.currentReviews([plan],records:rows).count,1)
        let unknown=RemoteDiagnostics.report(nodeID:"node",name:"Mac",sessions:[a],records:nil,targets:nil,servers:[:],attachments:[plan],transitions:[:],events:[],permissions:[],errors:["Unavailable"],userHome:user)
        try expectEqual((unknown["summary"] as! JSONObject)["level"] as? String,"unavailable")
        try expectEqual((unknown["attachments"] as! [JSONObject])[0]["current"] as? Bool,true,"Failed process query cannot declare a record historical")
    }
    func testRemoteDiagnosticsSecretRedactionAndBoundedText() throws {
        let text=RemoteDiagnostics.text("/Users/other/.codex bearer abcd.efgh refresh_token=private-value password=verysecret pin=123456 https://example.test/cb?code=secret eyJabc.abc.xyz",userHome:"/fixture/user")
        for value in ["/Users/other","abcd.efgh","private-value","verysecret","123456","code=secret","eyJabc.abc.xyz"] {try expectFalse(text.contains(value))}
        let longJWT="eyJ"+String(repeating:"A",count:350)+".payload.signature"
        try expectFalse(RemoteDiagnostics.text(longJWT,limit:40).contains("eyJ"),"Mask a full credential before applying display limits")
        try expectFalse(RemoteDiagnostics.text(#"{"access_token":"opaque-private-value"}"#).contains("opaque-private-value"))
        try expectFalse(RemoteDiagnostics.text(#"password="secret with spaces""#).contains("secret with spaces"))
        try expectEqual(RemoteDiagnostics.text(String(repeating:"🙂",count:1000),limit:40).count,40)
        try expectFalse(RemoteDiagnostics.text("before\u{0}after").contains("\u{0}"))
    }
}
