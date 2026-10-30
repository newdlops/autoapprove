import Foundation
import AutoApproveCore

private let conversationThread="00000000-0000-4000-8000-000000000219"
private func conversationRow(_ id:String,_ type:String,_ fields:JSONObject)->JSONObject {
    var item=fields;item["id"]=id;item["type"]=type
    return ["turnId":"turn-1","item":item]
}
extension ApprovalTests {
    func testCodexConversationProjectionShowsDisplayMessagesInOrder() throws {
        let literal="대화 🙂 e\u{301}\n```swift\nlet x = 1\n```\n<img src=x onerror=alert(1)>"
        let rows=[conversationRow("answer","agentMessage",["text":literal,"phase":"final_answer"]),
                  conversationRow("secret","reasoning",["content":["DO NOT SHOW REASONING"]]),
                  conversationRow("tool","commandExecution",["aggregatedOutput":"OS SHELL PROMPT"]),
                  conversationRow("progress","agentMessage",["text":"진행 안내","phase":"commentary"]),
                  conversationRow("user","userMessage",["content":[["type":"text","text":"사용자 요청"],["type":"image","url":"https://private.invalid/secret"]]])]
        let page=try CodexConversationProjection.page(["data":rows,"nextCursor":"older"],threadID:conversationThread)
        try expectEqual(page.messages.map(\.id),["user","progress","answer"])
        try expectEqual(page.messages.map(\.role),["user","assistant","assistant"])
        try expectEqual(page.messages[0].text,"사용자 요청\n[이미지 첨부]")
        try expectEqual(page.messages[2].text,literal);try expectEqual(page.nextCursor,"older")
        try expect(page.messages.allSatisfy {!$0.truncated})
        let encoded=String(decoding:try JSONEncoder().encode(page),as:UTF8.self)
        for hidden in ["OS SHELL PROMPT","DO NOT SHOW REASONING","private.invalid"] {try expect(!encoded.contains(hidden))}
        try expectEqual(try CodexConversationProjection.page(["data":[]],threadID:conversationThread).messages.count,0)
        let long=String(repeating:"🙂",count:70_000)
        let clipped=try CodexConversationProjection.page(["data":[conversationRow("long","agentMessage",["text":long])]],threadID:conversationThread)
        try expect(clipped.messages[0].truncated);try expectEqual(clipped.messages[0].text,String(long.prefix(65_536)))
    }
    func testCodexConversationMalformedPagesNeverBecomeTerminalText() throws {
        let good=conversationRow("message","agentMessage",["text":"reply"])
        for value:JSONObject in [
            ["data":"wrong"],["data":[good],"nextCursor":42],["data":[good],"nextCursor":""],
            ["data":[good],"nextCursor":String(repeating:"x",count:8193)],
            ["data":Array(repeating:good,count:33)],["data":[good,good]],
            ["data":[["item":["type":"agentMessage","id":"missing-text"]]]],
            ["data":[conversationRow("user","userMessage",["content":[["type":"text"]]])]],
            ["data":[conversationRow("user","userMessage",["content":"shell"])]],
            ["data":[["item":["text":"SHELL PROMPT"]]]]
        ] {try expectThrows(try CodexConversationProjection.page(value,threadID:conversationThread))}
    }
    @MainActor func testCodexConversationReadBindsNamedOriginalAndRejectsStaleProcess() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-conversation-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let records=ProcessDiscovery.parse("100219 1 ttys219 100219 100219 Fri Oct 30 12:00:00 2026 /fixture/codex")
        let target=CodexReplyTarget(executable:"",home:root.path,threadID:conversationThread)
        let state=ConversationFixture(records:records)
        let replies=CodexReplyTransport(prepare:{_,_ in target},send:{_,_ in throw AppError.message("NO WRITES")},prepareMessage:{_ in throw AppError.message("Daemon owns rollout")},queueHome:{_ in target},prepareQueue:{_,thread in var value=target;value.threadID=thread;return value})
        let queue=CodexQueueTransport(list:{_ in []},delete:{_,_ in throw AppError.message("NO DELETES")},conversations:{_,_ in state.names()})
        let history=CodexConversationTransport {target,cwd,cursor in
            try expectEqual(target.threadID,conversationThread);try expectEqual(cwd,root.path)
            if state.stale {state.exit()}
            return .init(threadID:state.wrongThread ? UUID().uuidString:target.threadID,messages:[.init(id:cursor ?? "new",role:"assistant",text:"Actual conversation")],nextCursor:cursor==nil ? "older":nil)
        }
        let engine=try ApprovalEngine(paths:.init(directory:root),questionTransport:replies,processReader:{state.processes()},codexQueue:queue,codexConversation:history)
        defer {engine.stop()}
        var session=ProcessDiscovery.sessions(records)[0];session.terminal = .terminal;session.cwd=root.path;session.terminalTitle="⠦ Exact conversation | "+root.lastPathComponent
        engine.updateDiscovery([session],records:records)
        let page=try await engine.remoteCodexHistory(sessionID:session.id)
        try expectEqual(page.sessionID,session.id);try expectEqual(page.threadID,conversationThread);try expectEqual(page.messages[0].text,"Actual conversation")
        let older=try await engine.remoteCodexHistory(sessionID:session.id,threadID:page.threadID,cursor:page.nextCursor)
        try expectEqual(older.messages[0].id,"older")
        state.ambiguous=true
        do {_ = try await engine.remoteCodexHistory(sessionID:session.id);try expect(false)} catch let error as RemoteHTTPError {try expectEqual(error.status,409)}
        state.ambiguous=false;state.wrongThread=true
        do {_ = try await engine.remoteCodexHistory(sessionID:session.id);try expect(false)} catch let error as RemoteHTTPError {try expectEqual(error.status,409)}
        state.wrongThread=false;state.stale=true
        do {_ = try await engine.remoteCodexHistory(sessionID:session.id);try expect(false)} catch let error as RemoteHTTPError {try expectEqual(error.status,409)}
        try expect(engine.managedPTY.inventory.isEmpty)
    }
}
private final class ConversationFixture:@unchecked Sendable {
    let records:[ProcessRecord]
    private let lock=NSLock()
    private var alive=true
    var ambiguous=false,wrongThread=false,stale=false
    init(records:[ProcessRecord]){self.records=records}
    func processes()->[ProcessRecord] {lock.lock();defer{lock.unlock()};return alive ? records:[]}
    func exit(){lock.lock();alive=false;lock.unlock()}
    func names()->[CodexQueueConversation] {
        let first=CodexQueueConversation(id:conversationThread,title:"Exact conversation",name:"Exact conversation")
        return ambiguous ? [first,.init(id:UUID().uuidString,title:"Exact conversation",name:"Exact conversation")]:[first]
    }
}
