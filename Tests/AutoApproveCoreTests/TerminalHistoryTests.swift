import Foundation
import AutoApproveCore

private final class HistoryProbe:@unchecked Sendable {
    private let condition=NSCondition()
    var value:String
    private var count=0
    private var held=false
    init(_ value:String,held:Bool=false){self.value=value;self.held=held}
    func capture()->String {condition.lock();defer{condition.unlock()};count+=1;while held {condition.wait()};return value}
    var calls:Int {condition.lock();defer{condition.unlock()};return count}
    func release(){condition.lock();held=false;condition.broadcast();condition.unlock()}
}
private final class HistoryClock:@unchecked Sendable {
    private let lock=NSLock();private var date=Date(timeIntervalSince1970:1793170000)
    func now()->Date {lock.lock();defer{lock.unlock()};return date}
    func advance(_ seconds:Double){lock.lock();date.addTimeInterval(seconds);lock.unlock()}
}
private final class HistoryProcesses:@unchecked Sendable {
    private let lock=NSLock();private var rows:[ProcessRecord]
    init(_ rows:[ProcessRecord]){self.rows=rows}
    func read()->[ProcessRecord]{lock.lock();defer{lock.unlock()};return rows}
    func clear(){lock.lock();rows=[];lock.unlock()}
}
private func historyCode(_ value:String)->UInt32 {value.utf8.reduce(0){($0<<8)|UInt32($1)}}
private func historyRoot()->URL {FileManager.default.temporaryDirectory.appendingPathComponent("aa-history-"+UUID().uuidString,isDirectory:true)}

extension ApprovalTests {
    func testFullTerminalHistoryPagesKeepBeginningEndAndUnicode() async throws {
        let root=historyRoot();defer{try? FileManager.default.removeItem(at:root)}
        let store=TerminalHistoryStore(directory:root)
        let original="EARLIEST\n"+String(repeating:"한글 🙂 e\u{301} 합성 기록 <img onerror=alert(1)>\n",count:20_000)+"LATEST"
        try expect(original.utf16.count>160_000)
        let probe=HistoryProbe(original)
        let tail=try await store.page(sessionID:"one",source:"pid-start-tty",capture:{probe.capture()})
        try expect(tail.text.hasSuffix("LATEST"));try expect(tail.pageCount>1)
        var joined="",largest=0
        for index in 0..<tail.pageCount {
            let page=try await store.page(sessionID:"one",source:"pid-start-tty",snapshot:tail.snapshot,page:index,capture:{probe.capture()})
            joined+=page.text;largest=max(largest,page.text.utf8.count)
            try expect(page.text.utf16.count<=16_384);try expect(page.text.filter {$0=="\n"}.count<=512)
            try expect(try JSONEncoder().encode(page).count<200_000)
        }
        try expectEqual(joined,original);try expectEqual(probe.calls,1);try expectEqual(tail.totalBytes,original.utf8.count);try expectEqual(tail.totalLines,20_002)
        try expect(largest<=49_152)
        for file in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil) {
            try expectEqual((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        }
        await store.stop();try expectEqual(try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).count,0)
    }

    func testTerminalHistoryCoalescesCaptureWithoutBlockingActor() async throws {
        let root=historyRoot();defer{try? FileManager.default.removeItem(at:root)}
        let store=TerminalHistoryStore(directory:root),probe=HistoryProbe("shared history",held:true)
        defer{probe.release()}
        let first=Task {try await store.page(sessionID:"one",source:"same",capture:{probe.capture()})}
        for _ in 0..<100 where probe.calls==0 {try await Task.sleep(for:.milliseconds(5))}
        try expectEqual(probe.calls,1)
        let second=Task {try await store.page(sessionID:"one",source:"same",capture:{probe.capture()})}
        do {_ = try await store.page(sessionID:"two",source:"other",capture:{"never"});try expect(false)}
        catch let error as RemoteHTTPError {try expectEqual(error.status,503)}
        probe.release()
        let a=try await first.value,b=try await second.value
        try expectEqual(a.snapshot,b.snapshot);try expectEqual(probe.calls,1)
        let fresh=try await store.page(sessionID:"one",source:"same",refresh:true,capture:{probe.capture()})
        try expect(fresh.snapshot != a.snapshot);try expectEqual(probe.calls,2)
        await store.stop()
    }

    func testTerminalHistoryBoundsExpiryWrongSourceAndCacheCleanup() async throws {
        let root=historyRoot();defer{try? FileManager.default.removeItem(at:root)}
        let clock=HistoryClock(),store=TerminalHistoryStore(directory:root,lifetime:10,maximumBytes:1024,clock:{clock.now()})
        let first=try await store.page(sessionID:"one",source:"one",capture:{"first"})
        do {_ = try await store.page(sessionID:"one",source:"other",snapshot:first.snapshot,capture:{"wrong"});try expect(false)}
        catch let error as RemoteHTTPError {try expectEqual(error.status,410)}
        do {_ = try await store.page(sessionID:"one",source:"one",snapshot:first.snapshot,page:99,capture:{"wrong"});try expect(false)}
        catch let error as RemoteHTTPError {try expectEqual(error.status,400)}
        clock.advance(11)
        do {_ = try await store.page(sessionID:"one",source:"one",snapshot:first.snapshot,capture:{"wrong"});try expect(false)}
        catch let error as RemoteHTTPError {try expectEqual(error.status,410)}
        do {_ = try await store.page(sessionID:"large",source:"large",capture:{String(repeating:"가",count:1000)});try expect(false)}
        catch let error as RemoteHTTPError {try expectEqual(error.status,413)}
        var oldest:String=""
        for i in 0..<5 {
            clock.advance(1)
            let page=try await store.page(sessionID:"\(i)",source:"\(i)",capture:{"record"})
            if i==0 {oldest=page.snapshot}
        }
        try expectEqual(try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).count,4)
        do {_ = try await store.page(sessionID:"0",source:"0",snapshot:oldest,capture:{"wrong"});try expect(false)}
        catch let error as RemoteHTTPError {try expectEqual(error.status,410)}
        await store.stop()
    }

    func testTerminalHistoryEmptyLongLinesAndScalarBoundary() async throws {
        let root=historyRoot();defer{try? FileManager.default.removeItem(at:root)}
        let store=TerminalHistoryStore(directory:root)
        let empty=try await store.page(sessionID:"empty",source:"empty",capture:{""})
        try expectEqual(empty.text,"");try expectEqual(empty.pageCount,1);try expectEqual(empty.totalLines,0)
        let original=String(repeating:"x",count:16_383)+"🙂"+String(repeating:"\0\n",count:4000)+String(repeating:"e\u{301}",count:10000)
        let first=try await store.page(sessionID:"unicode",source:"unicode",page:0,capture:{original})
        var joined=""
        for page in 0..<first.pageCount {joined+=try await store.page(sessionID:"unicode",source:"unicode",snapshot:first.snapshot,page:page,capture:{"wrong"}).text}
        try expectEqual(joined,original)
        await store.stop()
    }

    func testTerminalHistoryAppleEventsReadOnlyExactTTYAndFullProperty() throws {
        let original=String(repeating:"HISTORY\n",count:30_000),tty="/dev/ttys333"
        var fields:[UInt32]=[]
        let reader=TerminalAppleEventReader {subject,_ in
            let field=subject.forKeyword(historyCode("seld"))!.typeCodeValue;fields.append(field)
            let target=subject.forKeyword(historyCode("from"))!,predicate=target.forKeyword(historyCode("seld"))!
            try expectEqual(predicate.forKeyword(historyCode("obj2"))?.stringValue,tty)
            let reply=NSAppleEventDescriptor.list();reply.insert(.init(string:field==historyCode("hist") ? original:tty),at:1);return reply
        }
        try expectEqual(try reader.history(tty:tty),original)
        try expectEqual(fields,[historyCode("ttty"),historyCode("hist"),historyCode("ttty")])
        let wrong=TerminalAppleEventReader {_,_ in let reply=NSAppleEventDescriptor.list();reply.insert(.init(string:"/dev/other"),at:1);return reply}
        try expectThrows(try wrong.history(tty:tty))
    }

    func testTerminalHistoryDoesNotAnalyzeOldApprovalsOrChangeLiveRevision() async throws {
        let root=historyRoot();defer{try? FileManager.default.removeItem(at:root)}
        let rows=ProcessDiscovery.parse("100701 1 history1 100701 100701 Wed Oct 28 17:00:00 2026 /fixture/codex"),processes=HistoryProcesses(rows)
        var session=AgentSession(id:rows[0].key,agent:.codex,pid:rows[0].pid,started:rows[0].started,tty:"/dev/history1",cwd:"/tmp",terminal:.terminal)
        session.channel = .terminalScreen
        let oldPrompt="Would you like to run the following command?\n$ echo old\n› 1. Yes, proceed (y)\n 2. No, and tell Codex what to do differently (esc)\nPress enter to confirm or esc to cancel"
        let adapter=ScreenHostAdapter(screens:{targets in .init(screens:targets.map {.init(tty:$0.tty,contents:"Working\nesc to interrupt")})},approve:{_,_,_ in throw AppError.message("History must never approve")},reveal:{_ in nil},history:{_ in oldPrompt})
        let engine=try ApprovalEngine(paths:.init(directory:root),processReader:{processes.read()},screenAdapters:[.terminal:adapter])
        defer{engine.stop()};engine.updateDiscovery([session],records:rows);await engine.connectTerminal();try engine.setAutomatic(session.id,enabled:true)
        let before=try await engine.remoteTerminal(sessionID:session.id)
        let page=try await engine.remoteTerminalHistory(sessionID:session.id)
        try expectEqual(page.text,oldPrompt)
        let after=try await engine.remoteTerminal(sessionID:session.id)
        try expectEqual(before.revision,after.revision);try expectEqual(after.screen,before.screen)
        try expectEqual(engine.snapshot.sessions.first?.phase,.working)
        processes.clear()
        do {_ = try await engine.remoteTerminalHistory(sessionID:session.id,snapshot:page.snapshot);try expect(false)}
        catch let error as RemoteHTTPError {try expectEqual(error.status,409)}
    }
}
