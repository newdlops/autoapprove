import Foundation
import Darwin
import JavaScriptCore
import AutoApproveCore

private func profileEntry(_ agent:String="codex",cwd:String="/tmp/profile-project",host:TerminalProfileEntry.Host = .terminal) -> TerminalProfileEntry {
    .init(title:"프로필 창 · "+agent,agent:agent,cwd:cwd,conversationID:UUID().uuidString.lowercased(),host:host)
}
private func unwrap<T>(_ value:T?) throws -> T {guard let value else {throw AppError.message("Expected profile test value")};return value}
private actor ProfileLaunchRecorder {
    var keys:[String]=[]
    func add(_ key:String) {keys.append(key)}
}
private actor FreshProfileLaunchRecorder {
    var anchors:[String?]=[]
    var commands:[String]=[]
    func launch(_ entry:TerminalProfileEntry,_ anchor:String?) throws -> String {
        commands.append(try entry.resumeCommand());anchors.append(anchor)
        return "/dev/ttys\(980+commands.count-1)"
    }
}
private final class ProfileReadFixture: @unchecked Sendable {
    let records:[ProcessRecord]
    private let lock=NSLock()
    private var reads=0
    init(_ records:[ProcessRecord]) {self.records=records}
    func read() -> [ProcessRecord] {lock.lock();defer {lock.unlock()};reads += 1;return reads == 1 ? records:[]}
}

extension ApprovalTests {
    func testTerminalProfilesMultiplePrivateFilesAndRestart() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("aa-profiles-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let store=TerminalProfileStore(directory:directory)
        try expectEqual(try store.list().profiles.count,0)
        let first=try store.save(.init(name:"  업무 개발  ",entries:[profileEntry(),profileEntry("claude",host:.iterm)]))
        let second=try store.save(.init(name:"개인 작업",entries:[profileEntry()]))
        try expectEqual(first.name,"업무 개발")
        let restored=TerminalProfileStore(directory:directory),listed=try restored.list()
        try expectEqual(Set(listed.profiles.map(\.id)),Set([first.id,second.id]));try expect(listed.warnings.isEmpty)
        var renamed=first;renamed.name="변경한 프로필";renamed.savedAt=Date().addingTimeInterval(1)
        _ = try store.save(renamed)
        try expectEqual(try restored.list().profiles.count,2)
        let imported=try store.importFile(store.file(first.id))
        try expect(imported.id != first.id);try expectEqual(imported.entries,first.entries)
        try expectEqual(try restored.list().profiles.count,3)
        let attributes=try FileManager.default.attributesOfItem(atPath:store.file(first.id).path)
        try expectEqual((attributes[.posixPermissions] as? NSNumber)?.intValue,0o600)
        try expectEqual(try TerminalProfileStore.decode(TerminalProfileStore.read(store.file(second.id))).entries,second.entries)
        let json=String(decoding:try TerminalProfileStore.encode(first),as:UTF8.self)
        for key in ["pid","tty","token","password","prompt","command","transcript"] {try expect(!json.contains("\""+key+"\""),"Profiles contain resumable metadata only")}
        // An app that currently discovers no processes never writes over snapshots.
        try expectEqual(try TerminalProfileStore(directory:directory).list().profiles.count,3)
    }

    func testTerminalProfilesRejectMalformedUnsafeAndDuplicateFiles() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("aa-profile-invalid-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let store=TerminalProfileStore(directory:directory),entry=profileEntry(),valid=try store.save(.init(name:"기존",entries:[entry]))
        let original=try TerminalProfileStore.read(store.file(valid.id))
        for bad in ["",String(repeating:"가",count:81),"잘못된\n이름"] {var value=valid;value.name=bad;try expectThrows(try store.save(value))}
        var future=valid;future.schema=3;try expectThrows(try store.save(future))
        var duplicate=valid;duplicate.entries += [entry];try expectThrows(try store.save(duplicate))
        var unknown=entry;unknown.agent="shell";try expectThrows(try unknown.resumeCommand())
        unknown=entry;unknown.conversationID="--last";try expectThrows(try unknown.resumeCommand())
        unknown=entry;unknown.cwd="relative";try expectThrows(try unknown.resumeCommand())
        unknown=entry;unknown.providerHome="/tmp/\ncommand";try expectThrows(try unknown.resumeCommand())
        try expectThrows(try TerminalProfileStore.decode(Data(repeating:32,count:TerminalProfileStore.maximumBytes+1)))
        try expectThrows(try TerminalProfileStore.decode(Data("invalid JSON".utf8)))
        try expectEqual(try TerminalProfileStore.read(store.file(valid.id)),original)
        let malformed=directory.appendingPathComponent(UUID().uuidString.lowercased()+".autoapprove-profile.json")
        try Data("broken".utf8).write(to:malformed)
        try expectEqual(try store.list().profiles.count,1);try expectEqual(try store.list().warnings.count,1)
        let link=directory.appendingPathComponent("profile-link.json")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:store.file(valid.id))
        try expectThrows(try TerminalProfileStore.read(link))
        let linkedDirectory=directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at:linkedDirectory,withDestinationURL:directory)
        try expectThrows(try TerminalProfileStore(directory:linkedDirectory).list())
    }

    func testTerminalProfileFixedCommandsAndNativeHostContracts() throws {
        var entry=profileEntry(cwd:"/tmp/한글 '$HOME; touch /not-run'")
        let home="/tmp/provider ' $(not-run)"
        entry.providerHome=home
        let command=try entry.resumeCommand()
        try expect(command.contains("'codex' 'resume' '"+entry.conversationID+"'"))
        try expect(command.contains("'CODEX_HOME="));try expect(command.contains("'\\''"))
        for forbidden in ["--last","--yolo","dangerously","이어서","continue this"] {try expect(!command.contains(forbidden))}
        for host in TerminalProfileEntry.Host.allCases {
            entry.host=host
            let context=JSContext()!,calls=NSMutableArray();var exception:String?
            context.exceptionHandler={_,value in exception=value?.toString()}
            let record:@convention(block) (String)->Void = {calls.add($0)}
            context.setObject(record,forKeyedSubscript:"record" as NSString)
            context.evaluateScript("""
                const fixtureTab={tty:()=>'/dev/ttys099'};
                const fixtureApp={activate:()=>record('activate'),doScript:command=>{record(command);return fixtureTab;},createWindowWithDefaultProfile:options=>{record(options.command);return {currentSession:()=>fixtureTab};}};
                function Application(name){record(name);return fixtureApp;}
                """)
            let result=context.evaluateScript(try TerminalProfileLauncher.script(entry))?.toString()
            try expect(exception==nil,exception ?? "Native host contract");try expectEqual(result,#"{"tty":"/dev/ttys099"}"#)
            try expectEqual(calls.filter {($0 as? String)==command}.count,1)
            try expect(calls.contains(host == .terminal ? "com.apple.Terminal":"com.googlecode.iterm2"))
        }
        entry.agent="claude";try expect(try entry.resumeCommand().contains("'claude' '--resume'"))
        try expect(try entry.resumeCommand().contains("'CLAUDE_CONFIG_DIR="))
    }

    func testTerminalProfileFreshCLICommandsAndPrivateFiles() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-fresh-profile-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        var codex=profileEntry(cwd:"/tmp/fresh-workspace");codex.conversationID=" \n "
        let normalized=try codex.validated()
        try expectEqual(normalized.conversationID,"");try expect(!normalized.resumesConversation)
        try expectEqual(try normalized.resumeCommand(),"cd -- '/tmp/fresh-workspace' && exec 'env' 'codex'")
        var claude=normalized;claude.id=UUID();claude.agent="claude";claude.providerHome="/tmp/provider with space"
        try expectEqual(try claude.resumeCommand(),"cd -- '/tmp/fresh-workspace' && exec 'env' 'CLAUDE_CONFIG_DIR=/tmp/provider with space' 'claude'")
        var another=normalized;another.id=UUID()
        try expect(normalized.key != another.key,"Separate tabs in one folder have distinct launch receipts")
        var moved=normalized;moved.cwd="/tmp/other-workspace";try expect(moved.key != normalized.key)
        let store=TerminalProfileStore(directory:root),saved=try store.save(.init(name:"폴더와 CLI",entries:[normalized,another,claude]))
        try expectEqual(try TerminalProfileStore.decode(TerminalProfileStore.read(store.file(saved.id))).entries,saved.entries)
        for value in [normalized,claude] {for host in TerminalProfileEntry.Host.allCases {
            var entry=value;entry.host=host
            let context=JSContext()!
            context.evaluateScript("""
            var commands=[];const tab={tty:()=>'/dev/ttys099'};
            function Application(){return {activate:()=>{},doScript:command=>{commands.push(command);return tab;},createWindowWithDefaultProfile:options=>{commands.push(options.command);return {currentSession:()=>tab};}};}
            """)
            let result=context.evaluateScript(try TerminalProfileLauncher.script(entry))?.toString()
            try expectNil(context.exception);try expectEqual(result,#"{"tty":"/dev/ttys099"}"#)
            try expectEqual(context.evaluateScript("commands.length")?.toInt32(),1)
            try expectEqual(context.evaluateScript("commands[0]")?.toString(),try entry.resumeCommand())
        }}
        var specific=normalized;specific.conversationID=" 00000000-0000-4000-8000-000000000001 "
        try expectEqual(try specific.validated().conversationID,"00000000-0000-4000-8000-000000000001")
        try expect(try specific.resumeCommand().contains("'codex' 'resume'"))
    }

    func testTerminalProfileFreshCLIRestoreKeepsTabsAndReceipts() async throws {
        let group=UUID(),log=FreshProfileLaunchRecorder(),restorer=TerminalProfileRestorer()
        var a=profileEntry();a.conversationID="";a.terminalTab = .init(window:group,windowOrder:0,tabOrder:0)
        var b=a;b.id=UUID();b.terminalTab?.tabOrder=1;b.terminalTab?.selected=true
        var unrelated=a;unrelated.id=UUID()
        let profile=TerminalSessionProfile(name:"같은 폴더의 두 CLI",entries:[a,b]),selected=Set([a.id,b.id])
        let first=try await restorer.restore(profile,selected:selected,active:[unrelated],directoryExists:{_ in true},launch:{try await log.launch($0,$1)})
        try expectEqual(first.map(\.phase),[.opened,.opened]);try expectEqual(await log.anchors.count,2)
        let anchors=await log.anchors;try expectNil(anchors[0]);try expectEqual(anchors[1],"/dev/ttys980")
        let commands=await log.commands;try expect(commands.allSatisfy {!$0.contains("'resume'") && !$0.contains("'--resume'")})
        let again=try await restorer.restore(profile,selected:selected,active:[unrelated],directoryExists:{_ in true},terminalIsOpen:{_ in true},launch:{try await log.launch($0,$1)})
        try expectEqual(again.map(\.phase),[.alreadyOpen,.alreadyOpen]);try expectEqual(await log.commands.count,2)
        let closed=try await restorer.restore(profile,selected:[a.id],active:[],directoryExists:{_ in true},terminalIsOpen:{$0 != "/dev/ttys980"},launch:{try await log.launch($0,$1)})
        try expectEqual(closed.first?.phase,.opened);try expectEqual(await log.anchors.last!,"/dev/ttys981")
        let uncertain=TerminalProfileRestorer()
        _ = try await uncertain.restore(profile,selected:[a.id],active:[],directoryExists:{_ in true},launch:{_,_ in throw AppError.message("uncertain launch")})
        let retry=try await uncertain.restore(profile,selected:[a.id],active:[],directoryExists:{_ in true},launch:{try await log.launch($0,$1)})
        try expectEqual(retry.first?.phase,.needsReview);try expectEqual(await log.commands.count,3)
    }

    func testTerminalProfileRestoreDeduplicationAndPartialFailure() async throws {
        let opened=ProfileLaunchRecorder(),first=profileEntry(),missing=profileEntry(cwd:"/missing"),ambiguous=profileEntry(cwd:"/ambiguous"),next=profileEntry("claude")
        let profile=TerminalSessionProfile(name:"복원",entries:[first,missing,ambiguous,next]),restorer=TerminalProfileRestorer()
        var unknown=ambiguous;unknown.conversationID=""
        let result=try await restorer.restore(profile,selected:Set(profile.entries.map(\.id)),active:[first,unknown],activeTerminalTTYs:[first.key:"/dev/ttys099"],directoryExists:{$0 != "/missing"},launch:{entry,_ in await opened.add(entry.key);return "/dev/fixture-profile"})
        try expectEqual(result.map(\.phase),[.alreadyOpen,.failed,.needsReview,.opened]);try expectEqual(await opened.keys.count,1)
        let again=try await restorer.restore(profile,selected:[next.id],active:[],terminalIsOpen:{_ in true},launch:{entry,_ in await opened.add(entry.key);return "/dev/fixture-profile"})
        try expectEqual(again.first?.phase,.alreadyOpen);try expectEqual(await opened.keys.count,1)
        let uncertain=profileEntry(),uncertainProfile=TerminalSessionProfile(name:"확인",entries:[uncertain])
        let failed=try await restorer.restore(uncertainProfile,selected:[uncertain.id],active:[],directoryExists:{_ in true},launch:{_,_ in throw AppError.message("lost acknowledgement")})
        try expectEqual(failed.first?.phase,.needsReview)
        let retry=try await restorer.restore(uncertainProfile,selected:[uncertain.id],active:[],directoryExists:{_ in true},launch:{entry,_ in await opened.add(entry.key);return "/dev/fixture-profile"})
        try expectEqual(retry.first?.phase,.needsReview);try expectEqual(await opened.keys.count,1)
        let closed=try await restorer.restore(profile,selected:[next.id],active:[],directoryExists:{_ in true},terminalIsOpen:{_ in false},launch:{entry,_ in await opened.add(entry.key);return "/dev/fixture-profile-new"})
        try expectEqual(closed.first?.phase,.opened);try expectEqual(await opened.keys.count,2)
        let beforeStart=profileEntry(),beforeProfile=TerminalSessionProfile(name:"권한",entries:[beforeStart])
        let denied=try await restorer.restore(beforeProfile,selected:[beforeStart.id],active:[],directoryExists:{_ in true},launch:{_,_ in throw RemoteHTTPError(403,"permission",diagnostics:["delivery":"not_started"])})
        try expectEqual(denied.first?.phase,.failed)
        let allowed=try await restorer.restore(beforeProfile,selected:[beforeStart.id],active:[],directoryExists:{_ in true},launch:{entry,_ in await opened.add(entry.key);return "/dev/fixture-profile-allowed"})
        try expectEqual(allowed.first?.phase,.opened);try expectEqual(await opened.keys.count,3)
    }

    func testTerminalProfileCaptureBindsExactConversationsAndRejectsStalePID() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("aa-profile-capture-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let records=ProcessDiscovery.parse("""
        100501 1 profile1 100501 100501 Wed Oct 28 12:00:00 2026 /fixture/codex
        100502 1 profile2 100502 100502 Wed Oct 28 12:00:00 2026 /fixture/claude
        """)
        let sessions=records.map {record in AgentSession(id:record.key,agent:record.agent!,pid:record.pid,started:record.started,tty:"/dev/"+record.tty,cwd:"/tmp/shared",terminal:.terminal)}
        let claudeID=UUID().uuidString.lowercased(),first=UUID().uuidString.lowercased(),second=UUID().uuidString.lowercased()
        let transport=CodexReplyTransport(prepare:{_,_ in throw AppError.message("unused")},send:{_,_ in throw AppError.message("never send")},queueHome:{_ in .init(executable:"",home:"/tmp/profile-codex-home",threadID:"")})
        let queue=CodexQueueTransport(list:{_ in []},delete:{_,_ in .init(removed:[])},conversations:{_,_ in [.init(id:first,title:"첫 대화"),.init(id:second,title:"다른 대화")]})
        let registry:@Sendable ([ProcessRecord])->[ClaudeSessionRegistration] = {_ in [.init(processID:records[1].key,kind:"interactive",activity:.init(providerID:claudeID,status:"idle",changedAt:Date()))]}
        let layout:@Sendable ([String]) throws -> [TerminalProfileTabSnapshot] = {ttys in ttys.enumerated().map {.init(tty:$0.element,windowID:7,windowOrder:0,tabOrder:$0.offset,selected:$0.offset==1,settingsName:"Pro")}}
        let engine=try ApprovalEngine(paths:AppPaths(directory:directory),questionTransport:transport,claudeRegistryReader:registry,processReader:{records},codexQueue:queue,terminalProfileLayoutReader:layout)
        defer {engine.stop()};engine.updateDiscovery(sessions,records:records)
        let candidates=try await engine.terminalProfileCandidates()
        let codex=try unwrap(candidates.first {$0.entry.agent == "codex"}),claude=try unwrap(candidates.first {$0.entry.agent == "claude"})
        try expectEqual(codex.entry.conversationID,"");try expectEqual(codex.conversations.map(\.id),[first,second])
        try expectEqual(claude.entry.conversationID,claudeID)
        try expectEqual(try TerminalSessionProfile(name:"새 CLI",entries:[codex.entry]).validated().entries.first?.conversationID,"")
        try expect(!(try codex.entry.resumeCommand()).contains("'resume'"))
        var chosen=codex.entry;chosen.conversationID=second
        try expectEqual(try TerminalSessionProfile(name:"선택",entries:[chosen]).validated().entries[0].conversationID,second)
        let reader=ProfileReadFixture(records)
        let stale=try ApprovalEngine(paths:AppPaths(directory:directory.appendingPathComponent("stale")),questionTransport:transport,claudeRegistryReader:registry,processReader:{reader.read()},codexQueue:queue,terminalProfileLayoutReader:layout)
        defer {stale.stop()};stale.updateDiscovery(sessions,records:records)
        var rejected=false;do {_ = try await stale.terminalProfileCandidates()} catch {rejected=true}
        try expect(rejected,"A vanished or reused source cannot be captured after its async identity read")
    }

    func testHardWrappedPermissionFooterRetainsWholeDialogAndRejections() throws {
        let heading="Approve app tool call?\n› 1. Allow once\n  2. Cancel\n",hint="Press enter to confirm or esc to cancel"
        let ordinary=try unwrap(PromptDetector.detect(heading+hint,agent:.codex))
        for width in 2...16 {
            let chars=Array(hint),wrapped=stride(from:0,to:chars.count,by:width).map {String(chars[$0..<min(chars.count,$0+width)])}.joined(separator:"\n")
            let screen=heading+wrapped
            for raw in [screen,String(NSString(string:screen))] {
                let prompt=try unwrap(PromptDetector.detect(raw,agent:.codex))
                try expectEqual(prompt.dialog,screen);try expectEqual(prompt.requestIdentity,ordinary.requestIdentity)
                try expectNil(PromptDetector.detect(raw+"\n› New instruction",agent:.codex))
                try expectNil(PromptDetector.detect(raw+"\nSomething else",agent:.codex))
                try expectNil(PromptDetector.detect("```\n"+raw+"\n```",agent:.codex))
            }
        }
        for bad in ["Pre\nss enter to confir","Enter to confirm deletion","Press enter to confirm\nrun the command","Press enter to confirm or esc to cancel\n› ask again"] {
            try expectNil(PromptDetector.detect(heading+bad,agent:.codex))
        }
    }
}
