import Foundation
import CoreGraphics
import JavaScriptCore
import AutoApproveCore

private func tabEntry(_ index:Int,window:UUID,order:Int=0,selected:Bool=false)->TerminalProfileEntry {
    .init(title:"작업 \(index)",agent:"codex",cwd:"/tmp/tab-profile",conversationID:String(format:"00000000-0000-4000-8000-%012d",index+1),terminalTab:.init(window:window,windowOrder:order,tabOrder:index,selected:selected,settingsName:"Pro",customTitle:"작업 \(index)"))
}
private actor TabLaunchLog {
    var entries:[(UUID,String?)]=[]
    var selections:[String]=[]
    func launch(_ entry:TerminalProfileEntry,_ anchor:String?)->String {entries.append((entry.id,anchor));return "/dev/ttys\(700+entries.count)"}
    func select(_ tty:String) {selections.append(tty)}
}
private final class TabKeyFixture:@unchecked Sendable {
    var trusted=true,postingAllowed=true,focused=true,changeWindow=false,throwAfterPost=false,failConfirmation=false,nativeWindows=false
    var reads=0,runs=0,posts=0
    var flags:CGEventFlags=[],code:Int64=0,pid:Int32=0
    let records=ProcessDiscovery.parse("1009001 1 ?? 1009001 0 Wed Oct 28 14:00:00 2026 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")
    var environment:TerminalKeyboard.Environment {
        .init(trusted:{self.trusted},postingAllowed:{self.postingAllowed},run:{_ in
            self.runs+=1
            if self.runs==1 {return #"{"tty":"/dev/ttys700","windowID":77,"ttys":["/dev/ttys700"]}"#}
            if self.failConfirmation {throw AppError.message("no new tab")}
            return "{\"tty\":\"/dev/ttys701\",\"windowID\":\(self.nativeWindows ? 78:77)}"
        },metadata:{tty in self.reads+=1;return .init(tty:tty,windowID:(self.changeWindow && self.reads>1) || (self.nativeWindows && tty=="/dev/ttys701") ? 78:77,ownerPID:1009001,ownerBundleID:"com.apple.Terminal",selected:true,minimized:false)},ownerBundle:{_ in "com.apple.Terminal"},focused:{_ in self.focused},processes:{self.records},postPair:{pid,down,up in
            self.posts+=1;self.pid=pid;self.flags=down.flags;self.code=down.getIntegerValueField(.keyboardEventKeycode)
            if self.throwAfterPost {throw AppError.message("lost key acknowledgement")}
        })
    }
}

extension ApprovalTests {
    func testTerminalTabProfileSchemaAndLegacyFiles() throws {
        let group=UUID(),a=tabEntry(0,window:group),b=tabEntry(1,window:group,selected:true)
        let profile=TerminalSessionProfile(name:"창과 탭",savedAt:Date(timeIntervalSince1970:1793160000),entries:[a,b])
        let encoded=try TerminalProfileStore.encode(profile),decoded=try TerminalProfileStore.decode(encoded)
        try expectEqual(decoded,profile);try expectEqual(decoded.schema,2)
        try expectEqual(decoded.terminalLayoutSummary,"Terminal 창 1개 · 탭 2개")
        try expectEqual(decoded.entries[1].terminalTab?.selected,true);try expectEqual(decoded.entries[0].terminalTab?.settingsName,"Pro")
        let json=String(decoding:encoded,as:UTF8.self)
        for field in ["tty","pid","windowID","command","history"] {try expect(!json.contains("\""+field+"\""))}
        var legacy=profile;legacy.schema=1;legacy.entries=legacy.entries.map {value in var e=value;e.terminalTab=nil;return e}
        let old=try TerminalProfileStore.decode(TerminalProfileStore.encode(legacy))
        try expectEqual(old.schema,1);try expectEqual(old.terminalLayoutSummary,"Terminal 창 1개 · 탭 2개")
        var invalid=profile;invalid.schema=1;try expectThrows(try invalid.validated())
        invalid=profile;invalid.schema=3;try expectThrows(try invalid.validated())
        invalid=profile;invalid.entries[1].terminalTab?.tabOrder=0;try expectThrows(try invalid.validated())
        invalid=profile;invalid.entries[0].terminalTab?.selected=true;try expectThrows(try invalid.validated())
        invalid=profile;invalid.entries[1].terminalTab?.windowOrder=1;try expectThrows(try invalid.validated())
        invalid=profile;invalid.entries[1].terminalTab?.settingsName="bad\nprofile";try expectThrows(try invalid.validated())
    }

    func testTerminalTabTopologyCapturesRelativeGroupsAndOrder() throws {
        let context=JSContext()!
        context.evaluateScript("""
        function tab(tty,name,title){return {tty:()=>tty,currentSettings:()=>({name:()=>name}),customTitle:()=>title};}
        const a=tab('/dev/ttys701','Pro','API'),b=tab('/dev/ttys702','Basic','Web'),c=tab('/dev/ttys703','Ocean','Other');
        function Application(){return {running:()=>true,windows:()=>[
          {id:()=>101,tabs:()=>[a,b],selectedTab:()=>b},
          {id:()=>102,tabs:()=>[c],selectedTab:()=>c}
        ]};}
        """)
        let text=context.evaluateScript(try TerminalProfileTopology.script(ttys:["/dev/ttys703","/dev/ttys702","/dev/ttys701"]))?.toString() ?? ""
        try expectNil(context.exception)
        let rows=try JSONDecoder().decode([TerminalProfileTabSnapshot].self,from:Data(text.utf8)),group=UUID()
        let candidates=[2,1,0].map {index in TerminalProfileCandidate(id:"\(index)",entry:tabEntry(index,window:group),tty:"/dev/ttys\(701+index)")}
        let captured=try TerminalProfileTopology.apply(rows,to:candidates)
        try expectEqual(captured.map(\.id),["0","1","2"])
        try expectEqual(captured[0].entry.terminalTab?.window,captured[1].entry.terminalTab?.window)
        try expect(captured[1].entry.terminalTab?.window != captured[2].entry.terminalTab?.window)
        try expectEqual(captured[0].entry.terminalTab?.customTitle,"API")
        try expectEqual(captured[1].entry.terminalTab?.selected,true)
        try expectEqual(captured[2].entry.terminalTab?.windowOrder,1)
        try expectThrows(try TerminalProfileTopology.apply(Array(rows.dropFirst()),to:candidates))
        try expectThrows(try TerminalProfileTopology.apply(rows+[rows[0]],to:candidates))
    }

    func testTerminalTabTopologySkipsUnrelatedWindowsWithoutSelection() throws {
        let context=JSContext()!
        context.evaluateScript("""
        const tab={tty:()=>'/dev/ttys701',currentSettings:()=>({name:()=> 'Pro'}),customTitle:()=> 'API'};
        const empty={id:()=>100,tabs:()=>[],selectedTab:()=>null};
        const unrelated={tabs:()=>[{tty:()=>'/dev/ttys799'}],id:()=>{throw Error('unrelated ID read');},selectedTab:()=>{throw Error('unrelated selection read');}};
        const target={id:()=>101,tabs:()=>[tab],selectedTab:()=>tab};
        function Application(){return {running:()=>true,windows:()=>[empty,unrelated,target]};}
        """)
        let text=context.evaluateScript(try TerminalProfileTopology.script(ttys:["/dev/ttys701"]))?.toString() ?? ""
        try expectNil(context.exception)
        let rows=try JSONDecoder().decode([TerminalProfileTabSnapshot].self,from:Data(text.utf8))
        try expectEqual(rows.count,1);try expectEqual(rows.first?.tty,"/dev/ttys701")
        try expectEqual(rows.first?.windowID,101);try expectEqual(rows.first?.windowOrder,2);try expectEqual(rows.first?.selected,true)
    }

    func testTerminalTabTopologyUnknownSelectionStillSavesExactGroupedTabs() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-null-tabs-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=TerminalProfileStore(directory:root)
        for selection in ["null","undefined"] {
            let context=JSContext()!
            context.evaluateScript("""
            function tab(tty,name,title){return {tty:()=>tty,currentSettings:()=>({name:()=>name}),customTitle:()=>title};}
            const a=tab('/dev/ttys701','Pro','API'),b=tab('/dev/ttys702','Basic','Web');
            const target={id:()=>101,tabs:()=>[a,b],selectedTab:()=>\(selection)};
            function Application(){return {running:()=>true,windows:()=>[target]};}
            """)
            let script=try TerminalProfileTopology.script(ttys:["/dev/ttys701","/dev/ttys702"])
            let text=context.evaluateScript(script)?.toString() ?? ""
            try expectNil(context.exception)
            let rows=try JSONDecoder().decode([TerminalProfileTabSnapshot].self,from:Data(text.utf8)),group=UUID()
            let candidates=[0,1].map {TerminalProfileCandidate(id:"\($0)",entry:tabEntry($0,window:group),tty:"/dev/ttys\(701+$0)")}
            let captured=try TerminalProfileTopology.apply(rows,to:candidates)
            try expectEqual(captured.count,2);try expect(captured.allSatisfy {$0.entry.terminalTab?.selected==false})
            try expectEqual(captured[0].entry.terminalTab?.window,captured[1].entry.terminalTab?.window)
            try expectEqual(captured.map {$0.entry.terminalTab?.tabOrder},[0,1]);try expectEqual(captured.map {$0.entry.terminalTab?.settingsName},["Pro","Basic"])
            let saved=try store.save(.init(name:selection,entries:captured.map(\.entry)))
            try expectEqual(try TerminalProfileStore.decode(TerminalProfileStore.read(store.file(saved.id))).entries,saved.entries)
            try expectThrows(try TerminalProfileTopology.apply(Array(rows.dropLast()),to:candidates))
            context.evaluateScript("target.selectedTab=()=>{throw Error('automation denied');};")
            _ = context.evaluateScript(script)
            try expect(context.exception?.toString()?.contains("automation denied")==true,"Read failures must not be hidden as missing selection")
        }
        try expectEqual(try store.list().profiles.count,2)
    }

    func testTerminalTabRestoreKeepsWindowsOrderAndSelection() async throws {
        let first=UUID(),second=UUID(),a=tabEntry(0,window:first),b=tabEntry(1,window:first,selected:true),c=tabEntry(2,window:second,order:1)
        let log=TabLaunchLog(),restorer=TerminalProfileRestorer(),profile=TerminalSessionProfile(name:"배치",entries:[c,b,a])
        let result=try await restorer.restore(profile,selected:[a.id,b.id,c.id],active:[],directoryExists:{_ in true},launch:{await log.launch($0,$1)},selectTab:{await log.select($0)})
        let events=await log.entries,selections=await log.selections
        try expectEqual(result.map(\.phase),[.opened,.opened,.opened]);try expectEqual(events.map(\.0),[a.id,b.id,c.id])
        try expectNil(events[0].1);try expectEqual(events[1].1,"/dev/ttys701");try expectNil(events[2].1)
        try expectEqual(Set(selections),Set(["/dev/ttys702","/dev/ttys703"]))
        _ = try await restorer.restore(profile,selected:[a.id,b.id,c.id],active:[],directoryExists:{_ in true},terminalIsOpen:{_ in true},launch:{await log.launch($0,$1)})
        try expectEqual(await log.entries.count,3)
        let partial=TerminalProfileRestorer()
        _ = try await partial.restore(profile,selected:[b.id],active:[a],activeTerminalTTYs:[a.key:"/dev/ttys799"],directoryExists:{_ in true},launch:{await log.launch($0,$1)})
        try expectEqual(await log.entries.last?.1,"/dev/ttys799","An unselected but already open member anchors missing tabs")
        var old=profile;old.schema=1;old.entries=old.entries.map {value in var entry=value;entry.terminalTab=nil;return entry}
        let legacy=TabLaunchLog()
        _ = try await TerminalProfileRestorer().restore(old,selected:Set(old.entries.map(\.id)),active:[],directoryExists:{_ in true},launch:{await legacy.launch($0,$1)})
        try expectEqual(await legacy.entries.filter {$0.1==nil}.count,1,"Legacy Terminal sessions share one new window")
    }

    func testTerminalTabGroupFailureNeverSpillsIntoSeparateWindows() async throws {
        let group=UUID(),other=UUID(),a=tabEntry(0,window:group),b=tabEntry(1,window:group),c=tabEntry(2,window:other,order:1)
        let profile=TerminalSessionProfile(name:"부분 실패",entries:[a,b,c]),restorer=TerminalProfileRestorer(),log=TabLaunchLog()
        let first=try await restorer.restore(profile,selected:[a.id,b.id,c.id],active:[],directoryExists:{_ in true},launch:{entry,anchor in
            if entry.id==a.id {throw AppError.message("uncertain first tab")};return await log.launch(entry,anchor)
        })
        try expectEqual(first.map(\.phase),[.needsReview,.needsReview,.opened]);try expectEqual(await log.entries.count,1)
        let retry=try await restorer.restore(profile,selected:[b.id],active:[],directoryExists:{_ in true},terminalIsOpen:{_ in true},launch:{await log.launch($0,$1)})
        try expectEqual(retry.first?.phase,.needsReview);try expectEqual(await log.entries.count,1)
        let unknown=try await TerminalProfileRestorer().restore(profile,selected:[b.id],active:[a],directoryExists:{_ in true},launch:{await log.launch($0,$1)})
        try expectEqual(unknown.first?.phase,.needsReview);try expectEqual(await log.entries.count,1)
        let denied=TerminalProfileRestorer()
        _ = try await denied.restore(profile,selected:[a.id,b.id],active:[],directoryExists:{_ in true},launch:{_,_ in throw RemoteHTTPError(403,"permission",diagnostics:["delivery":"not_started"])})
        let allowed=try await denied.restore(profile,selected:[a.id,b.id],active:[],directoryExists:{_ in true},launch:{await log.launch($0,$1)})
        try expectEqual(allowed.map(\.phase),[.opened,.opened]);try expectEqual(await log.entries.count,3)
        try expectEqual(await log.entries.last?.1,"/dev/ttys702")
    }

    func testTerminalTabKeyboardPinsOwnerWindowAndUncertainResult() throws {
        let fixture=TabKeyFixture()
        try expectEqual(try TerminalProfileTabOpener.open(anchorTTY:"/dev/ttys700",environment:fixture.environment,nativeGroupReader:{nil}),"/dev/ttys701")
        try expectEqual(fixture.posts,1);try expectEqual(fixture.pid,1009001);try expectEqual(fixture.code,17);try expect(fixture.flags.contains(.maskCommand))
        for mode in [0,1,2] {
            let blocked=TabKeyFixture()
            if mode==0 {blocked.postingAllowed=false};if mode==1 {blocked.focused=false};if mode==2 {blocked.changeWindow=true}
            do {_ = try TerminalProfileTabOpener.open(anchorTTY:"/dev/ttys700",environment:blocked.environment,nativeGroupReader:{nil});try expect(false)}
            catch let error as RemoteHTTPError {try expectEqual(error.diagnostics?["delivery"],"not_started")}
            try expectEqual(blocked.posts,0)
        }
        for afterPost in [true,false] {
            let uncertain=TabKeyFixture();uncertain.throwAfterPost=afterPost;uncertain.failConfirmation = !afterPost
            do {_ = try TerminalProfileTabOpener.open(anchorTTY:"/dev/ttys700",environment:uncertain.environment,nativeGroupReader:{nil});try expect(false)}
            catch let error as RemoteHTTPError {try expect(error.diagnostics?["delivery"] != "not_started")}
            try expectEqual(uncertain.posts,1)
        }
    }

    func testTerminalNativeTabDoesNotTreatStaleTrustAsPermissionDenial() throws {
        let fixture=TabKeyFixture();fixture.trusted=false
        let tty=try TerminalProfileTabOpener.open(anchorTTY:"/dev/ttys700",environment:fixture.environment,nativeGroupReader:{nil})
        try expectEqual(tty,"/dev/ttys701");try expectEqual(fixture.posts,1,"Current posting permission plus verified AX focus permits the exact target even if the advisory trust value is false")
        let denied=TabKeyFixture();denied.trusted=false
        do {
            _ = try TerminalProfileTabOpener.open(anchorTTY:"/dev/ttys700",environment:denied.environment,nativeGroupReader:{throw TerminalProfileAccessError.accessibilityDenied})
            try expect(false)
        } catch let error as RemoteHTTPError {
            try expectEqual(error.diagnostics?["delivery"],"not_started")
            try expect(error.localizedDescription.contains("macOS가"))
        }
        try expectEqual(denied.posts,0,"An actual AX denial still prevents the key, without replay")
    }

    func testTerminalNativeTabOpenerVerifiesAnchorAndNewWindowShareAGroup() throws {
        for alreadyGrouped in [false,true] {
            let fixture=TabKeyFixture();fixture.nativeWindows=true
            var reads=0
            let before=TerminalNativeTabGroup(id:10,tabs:alreadyGrouped ? [11,13]:[11],selected:11)
            let added=TerminalNativeTabGroup(id:10,tabs:alreadyGrouped ? [11,12,13]:[11,12],selected:12)
            let tty=try TerminalProfileTabOpener.open(anchorTTY:"/dev/ttys700",environment:fixture.environment,nativeGroupReader:{
                defer {reads+=1}
                if reads==0 {return alreadyGrouped ? before:nil}
                var value=added;if reads==2 {value.selected=11};return value
            })
            try expectEqual(tty,"/dev/ttys701");try expectEqual(fixture.posts,1);try expectEqual(reads,4)
        }
        for mode in 0..<4 {
            let fixture=TabKeyFixture();fixture.nativeWindows=true
            var reads=0
            do {
                _ = try TerminalProfileTabOpener.open(anchorTTY:"/dev/ttys700",environment:fixture.environment,nativeGroupReader:{
                    defer {reads+=1}
                    if reads==0 {return .init(id:10,tabs:[11,13],selected:11)}
                    var value=TerminalNativeTabGroup(id:10,tabs:[11,12,13],selected:reads==2 ? 11:12)
                    if mode==0 {value.id=99};if mode==1 {value.tabs=[13,12,11]}
                    if mode==2 && reads==2 {value.id=99};if mode==3 && reads>=3 {value.selected=11}
                    return value
                })
                try expect(false,"A separate native window, reordered group or changed selection cannot receive a command")
            } catch let error as RemoteHTTPError {try expect(error.diagnostics?["delivery"] != "not_started")}
            try expectEqual(fixture.posts,1)
        }
    }

    func testTerminalNativeTabOpenerWaitsForDelayedAXWithoutRepeatingKey() throws {
        let fixture=TabKeyFixture();fixture.nativeWindows=true
        let before=TerminalNativeTabGroup(id:10,tabs:[11,13],selected:11)
        let added=TerminalNativeTabGroup(id:10,tabs:[11,12,13],selected:12)
        var reads:[Int:Int]=[:]
        let tty=try TerminalProfileTabOpener.open(anchorTTY:"/dev/ttys700",environment:fixture.environment,nativeGroupReader:{
            let phase=fixture.runs;reads[phase,default:0]+=1
            if phase==1 {return before}
            if phase==2 {return reads[phase]!<3 ? before:added}
            var anchor=added;anchor.selected=11
            if phase==3 {return reads[phase]!<3 ? added:anchor}
            return reads[phase]!<3 ? anchor:added
        })
        try expectEqual(tty,"/dev/ttys701");try expectEqual(fixture.posts,1)
        try expectEqual(fixture.runs,4,"Only observation repeats; selection and Cmd-T each run once")
        try expectEqual(reads[2],3);try expectEqual(reads[3],3);try expectEqual(reads[4],3)
    }

    func testTerminalNativeTabOpenerAcceptsNewBarForFirstPairOnlyAfterTTYRoundTrip() throws {
        // Showing the first native tab bar can replace the singleton's AX
        // objects. The two exact TTYs must still select the same new bar.
        for replacedTab in [false,true] {
            let fixture=TabKeyFixture();fixture.nativeWindows=true
            let before=TerminalNativeTabGroup(id:5,tabs:[replacedTab ? 6:11],selected:replacedTab ? 6:11)
            let added=TerminalNativeTabGroup(id:10,tabs:[11,12],selected:12)
            var reads=0
            let tty=try TerminalProfileTabOpener.open(anchorTTY:"/dev/ttys700",environment:fixture.environment,nativeGroupReader:{
                defer {reads+=1}
                if reads==0 {return before}
                var value=added;if reads==2 {value.selected=11};return value
            })
            try expectEqual(tty,"/dev/ttys701");try expectEqual(fixture.posts,1);try expectEqual(fixture.runs,4)
            try expectEqual(reads,4)
        }
        for mode in 0..<3 {
            let fixture=TabKeyFixture();fixture.nativeWindows=true
            var reads=0
            do {
                _ = try TerminalProfileTabOpener.open(anchorTTY:"/dev/ttys700",environment:fixture.environment,nativeGroupReader:{
                    defer {reads+=1}
                    if reads==0 {return .init(id:5,tabs:[6],selected:6)}
                    var value=TerminalNativeTabGroup(id:10,tabs:[11,12],selected:reads==2 ? 11:12)
                    if mode==0 && reads>=2 {value.id=20}
                    if mode==1 && reads>=2 {value.selected=12}
                    if mode==2 && reads>=3 {value.selected=11}
                    return value
                })
                try expect(false,"A replaced bar still needs exact anchor/new-TTY selection confirmation")
            } catch let error as RemoteHTTPError {try expect(error.diagnostics?["delivery"] != "not_started")}
            try expectEqual(fixture.posts,1,"An uncertain new tab cannot repeat Cmd-T")
        }
    }

    func testTerminalTabScriptsOnlyWriteConfirmedIdleNewTab() throws {
        let context=JSContext()!,group=UUID(),entry=tabEntry(0,window:group)
        context.evaluateScript("""
        var commands=[],created=0;
        function makeTab(tty){return {tty:()=>tty,busy:()=>false,processes:()=>['-zsh'],currentSettings:null,customTitle:''};}
        const oldTab=makeTab('/dev/ttys700'),newTab=makeTab('/dev/ttys701'),foreignTab=makeTab('/dev/ttys799');
        var targetTabs=[oldTab];const targetWindow={id:()=>77,tabs:()=>targetTabs};
        const profile={exists:()=>true},foreignWindow={id:()=>88,tabs:()=>[foreignTab]};
        function Application(){return {activate:()=>{},windows:()=>[foreignWindow,targetWindow],settingsSets:{byName:()=>profile},doScript:(command,options)=>{
          if(!options){created++;return makeTab('/dev/ttys702');}commands.push({command,tty:options.in.tty()});return options.in;
        }};}
        const ObjC={import:()=>{}};const $={NSThread:{sleepForTimeInterval:()=>{}}};
        """)
        let prepared=context.evaluateScript(try TerminalProfileTabOpener.prepareScript(anchorTTY:"/dev/ttys700"))?.toString() ?? ""
        try expectNil(context.exception);try expect(prepared.contains("77"))
        context.evaluateScript("targetTabs.push(newTab);")
        let confirmed=context.evaluateScript(try TerminalProfileTabOpener.confirmationScript(anchorTTY:"/dev/ttys700",windowID:77,previousTTYs:["/dev/ttys700","/dev/ttys799"]))?.toString()
        try expectNil(context.exception);try expectEqual(confirmed,#"{"tty":"/dev/ttys701","windowID":77}"#)
        let delivered=context.evaluateScript(try TerminalProfileLauncher.script(entry,targetTTY:"/dev/ttys701"))?.toString()
        try expectNil(context.exception);try expectEqual(delivered,#"{"tty":"/dev/ttys701"}"#)
        try expectEqual(context.evaluateScript("commands.length")?.toInt32(),1);try expectEqual(context.evaluateScript("created")?.toInt32(),0)
        try expectEqual(context.evaluateScript("commands[0].tty")?.toString(),"/dev/ttys701")
        context.evaluateScript("newTab.busy=()=>true;")
        _ = context.evaluateScript(try TerminalProfileLauncher.script(entry,targetTTY:"/dev/ttys701"));try expect(context.exception != nil);context.exception=nil
        try expectEqual(context.evaluateScript("commands.length")?.toInt32(),1)
        context.evaluateScript("targetTabs=[oldTab];")
        _ = context.evaluateScript(try TerminalProfileTabOpener.confirmationScript(anchorTTY:"/dev/ttys700",windowID:77,previousTTYs:["/dev/ttys700","/dev/ttys799"]));try expect(context.exception != nil);context.exception=nil
        try expectEqual(context.evaluateScript("created")?.toInt32(),0,"A failed tab never falls back to a separate window")
    }
}
