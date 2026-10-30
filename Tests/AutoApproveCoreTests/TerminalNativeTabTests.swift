import Foundation
import JavaScriptCore
import AutoApproveCore

extension ApprovalTests {
    func testTerminalProfileReadinessWaitsOnlyForObservations() throws {
        var now:TimeInterval=0,reads=0,pauses=0
        let result:Int=try TerminalProfileReadiness.wait(timeout:1,message:"late",clock:{now},pause:{now+=$0;pauses+=1}) {
            reads+=1;return reads==4 ? 42:nil
        }
        try expectEqual(result,42);try expectEqual(reads,4);try expectEqual(pauses,3);try expect(now<0.1)
        now=0;reads=0
        try expectThrows(try TerminalProfileReadiness.wait(timeout:0.05,message:"bounded",clock:{now},pause:{now+=$0},read:{() -> Bool? in reads+=1;return nil}))
        try expectEqual(now,0.05);try expect(reads<=4)
        reads=0
        try expectThrows(try TerminalProfileReadiness.wait(message:"denied",read:{() throws -> Bool? in reads+=1;throw TerminalProfileAccessError.accessibilityDenied}))
        try expectEqual(reads,1,"Permission and source errors cannot become retry loops")
    }

    func testTerminalProfileCaptureFocusVerifiesPreviousAndReturnsSelectionInOneScript() throws {
        let context=JSContext()!
        context.evaluateScript("""
        var front=true,activations=0;
        function makeWindow(id,tty){
          let minimized=false;
          const tab={tty:()=>tty,selected:()=>true},window={id:()=>id,tabs:()=>[tab]};
          Object.defineProperty(window,'selectedTab',{get:()=>()=>tab,set:value=>{if(value!==tab)throw Error('foreign tab');}});
          Object.defineProperty(window,'miniaturized',{get:()=>()=>minimized,set:value=>{minimized=value;}});
          return window;
        }
        const a=makeWindow(77,'/dev/ttys700'),b=makeWindow(78,'/dev/ttys701');
        const app={windows:()=>[a,b],frontmost:()=>front,activate:()=>{activations++;front=true;}};
        function Application(){return app;}
        """)
        let previous=TerminalWindowMetadata(tty:"/dev/ttys700",windowID:77,ownerPID:1009001,ownerBundleID:"com.apple.Terminal",selected:true,minimized:false)
        let text=context.evaluateScript(try TerminalProfileTopology.focusScript(tty:"/dev/ttys701",previous:previous))?.toString()
        try expectNil(context.exception);try expectEqual(text,#"{"tty":"/dev/ttys701","windowID":78,"selected":true,"minimized":false}"#)
        try expectEqual(context.evaluateScript("activations")?.toInt32(),1)
        context.evaluateScript("front=false;")
        _ = context.evaluateScript(try TerminalProfileTopology.focusScript(tty:"/dev/ttys701",previous:previous))
        try expect(context.exception != nil);context.exception=nil
        try expectEqual(context.evaluateScript("activations")?.toInt32(),1,"A changed previous focus cannot select another tab")
        context.evaluateScript("front=true;")
        var stale=previous;stale.windowID=99
        _ = context.evaluateScript(try TerminalProfileTopology.focusScript(tty:"/dev/ttys701",previous:stale))
        try expect(context.exception != nil);context.exception=nil
        try expectEqual(context.evaluateScript("activations")?.toInt32(),1)
        try expectThrows(try TerminalProfileTopology.focusScript(tty:"/dev/foreign"))
    }

    func testTerminalProfileKnownWindowFocusBoundsQueriesAndRejectsChanges() throws {
        for count in [2,20,128,1024] {
            let context=JSContext()!
            context.evaluateScript("""
            var allTabs=0,lookups=0,exactQueries=0,activations=0,front=true,missing=false,moved=false;
            function makeWindow(index){
              const tty='/dev/ttys'+(700+index),tab={tty:()=>tty,selected:()=>true},window={id:()=>77+index,exists:()=>!missing};
              const tabs=()=>{allTabs++;return [tab];};tabs.whose=predicate=>()=>{exactQueries++;return moved?[]:predicate.tty===tty?[tab]:[];};window.tabs=tabs;
              Object.defineProperty(window,'selectedTab',{get:()=>()=>tab,set:value=>{if(value!==tab)throw Error('foreign tab');}});
              Object.defineProperty(window,'miniaturized',{get:()=>()=>false,set:()=>{}});return window;
            }
            const windows=Array.from({length:\(count)},(_,index)=>makeWindow(index)),list=()=>windows;
            list.byId=id=>{lookups++;return windows.find(w=>w.id()===id)||{exists:()=>false};};
            const app={windows:list,frontmost:()=>front,activate:()=>{activations++;}};function Application(){return app;}
            function reset(){allTabs=lookups=exactQueries=activations=0;}
            """)
            let previous=TerminalWindowMetadata(tty:"/dev/ttys700",windowID:77,ownerPID:1009001,ownerBundleID:"com.apple.Terminal",selected:true,minimized:false)
            let tty="/dev/ttys\(699+count)",windowID=UInt32(76+count)
            let baseline=context.evaluateScript(try TerminalProfileTopology.focusScript(tty:tty,previous:previous))?.toString()
            try expectNil(context.exception);try expectEqual(context.evaluateScript("allTabs")?.toInt32(),Int32(count))
            context.evaluateScript("reset();")
            let fastScript=try TerminalProfileTopology.focusScript(tty:tty,windowID:windowID,previous:previous)
            let fast=context.evaluateScript(fastScript)?.toString()
            try expectNil(context.exception);try expectEqual(fast,baseline)
            try expectEqual(context.evaluateScript("allTabs")?.toInt32(),0)
            try expectEqual(context.evaluateScript("lookups")?.toInt32(),2)
            try expectEqual(context.evaluateScript("exactQueries")?.toInt32(),2)
            for mutation in ["front=false","missing=true","moved=true"] {
                context.evaluateScript("reset();front=true;missing=moved=false;"+mutation+";")
                _ = context.evaluateScript(fastScript)
                try expect(context.exception != nil,"A changed window, TTY or preceding focus cannot select another tab")
                context.exception=nil;try expectEqual(context.evaluateScript("activations")?.toInt32(),0)
            }
        }
    }

    func testTerminalProfileShellReadinessAllowsSlowStartupWithoutRepeatingActions() throws {
        let context=JSContext()!
        context.evaluateScript("""
        var checks=0,sleeps=0;
        const old={tty:()=>'/dev/ttys700'},tab={tty:()=>'/dev/ttys701',busy:()=>{checks++;return checks<60;},processes:()=>['-zsh']};
        const window={id:()=>77,tabs:()=>[old,tab]};
        function Application(){return {windows:()=>[window]};}
        const ObjC={import:()=>{}};const $={NSThread:{sleepForTimeInterval:()=>{sleeps++;}}};
        """)
        let result=context.evaluateScript(try TerminalProfileTabOpener.confirmationScript(anchorTTY:"/dev/ttys700",windowID:77,previousTTYs:["/dev/ttys700"]))?.toString()
        try expectNil(context.exception);try expectEqual(result,#"{"tty":"/dev/ttys701","windowID":77}"#)
        try expectEqual(context.evaluateScript("checks")?.toInt32(),60);try expectEqual(context.evaluateScript("sleeps")?.toInt32(),59)
    }

    func testTerminalNativeCaptureUsesRealGroupInsteadOfScriptingWindows() throws {
        let rows=[TerminalProfileTabSnapshot(tty:"/dev/ttys702",windowID:102,windowOrder:0,tabOrder:0,selected:true,customTitle:"동일 제목"),
                  .init(tty:"/dev/ttys703",windowID:103,windowOrder:1,tabOrder:0,selected:true,customTitle:"동일 제목"),
                  .init(tty:"/dev/ttys701",windowID:101,windowOrder:2,tabOrder:0,selected:true,customTitle:"동일 제목")]
        let baseline=TerminalNativeTabGroup(id:10,tabs:[11,12],selected:12)
        var current="",restored=0
        let captured=try TerminalProfileNativeCapture.capture(rows,environment:.init(groups:{[baseline]},focus:{tty in
            current=tty;return rows.first {$0.tty==tty}!.windowID
        },focusedGroup:{
            if current=="/dev/ttys703" {return nil}
            var group=baseline;group.selected=current=="/dev/ttys701" ? 11:12;return group
        },restore:{groups in try expectEqual(groups,[baseline]);restored+=1}))
        try expectEqual(restored,1)
        try expectEqual(captured[0].windowID,captured[2].windowID)
        try expect(captured[0].windowID != captured[1].windowID)
        try expectEqual(captured.map(\.tabOrder),[1,0,0])
        try expectEqual(captured.map(\.selected),[true,true,false])
        let candidates=rows.map {row in TerminalProfileCandidate(id:row.tty,entry:.init(title:"동일 제목",agent:"codex",cwd:"/tmp/native-tabs",conversationID:""),tty:row.tty)}
        let entries=try TerminalProfileTopology.apply(captured,to:candidates).map(\.entry)
        let profile=TerminalSessionProfile(name:"기본 macOS 탭",entries:entries)
        try expectEqual(profile.terminalLayoutSummary,"Terminal 창 2개 · 탭 3개")
        let saved=try TerminalProfileStore.decode(TerminalProfileStore.encode(profile))
        try expectEqual(saved.entries[0].terminalTab?.tabOrder,0)
        try expectEqual(saved.entries[1].terminalTab?.selected,true)
        try expectEqual(saved.entries[0].terminalTab?.window,saved.entries[1].terminalTab?.window)
    }

    func testTerminalNativeCaptureMissingShellSelectionAndChangedGroups() throws {
        let rows=[TerminalProfileTabSnapshot(tty:"/dev/ttys701",windowID:101,windowOrder:0,tabOrder:0,selected:true),
                  .init(tty:"/dev/ttys702",windowID:102,windowOrder:1,tabOrder:0,selected:true)]
        let original=TerminalNativeTabGroup(id:10,tabs:[11,12,13],selected:13)
        var index=0,restored=0
        let output=try TerminalProfileNativeCapture.capture(rows,environment:.init(groups:{[original]},focus:{tty in rows.first {$0.tty==tty}!.windowID},focusedGroup:{
            var value=original;value.selected=11+index;index+=1;return value
        },restore:{_ in restored+=1}))
        try expectEqual(output.map(\.selected),[false,false],"An unsaved shell tab must not mark a CLI as originally selected")
        try expectEqual(restored,1)
        for mode in 0..<4 {
            var restoration=0,rejected=false
            do {
                _ = try TerminalProfileNativeCapture.capture(rows,environment:.init(groups:{[original]},focus:{_ in mode==0 ? 999:101},focusedGroup:{
                    var changed=original
                    if mode==1 {changed.id=99};if mode==2 {changed.tabs.swapAt(0,1)};if mode==3 {changed.selected=999}
                    return changed
                },restore:{_ in restoration+=1}))
            } catch {rejected=true}
            try expect(rejected,"Changed window, group, order or selected member must abort capture")
            try expectEqual(restoration,1,"Restore the initial selection when capture fails")
        }
        var focuses=0
        let legacy=try TerminalProfileNativeCapture.capture(rows,environment:.init(groups:{[]},focus:{_ in focuses+=1;return 0},focusedGroup:{nil},restore:{_ in try expect(false)}))
        try expectEqual(legacy,rows);try expectEqual(focuses,0)
    }

    func testTerminalNativeCaptureTwoGroupsKeepsOrderAndRestoreFailure() throws {
        let rows=(0..<4).map {TerminalProfileTabSnapshot(tty:"/dev/ttys\(701+$0)",windowID:UInt32(101+$0),windowOrder:$0,tabOrder:0,selected:true)}
        let a=TerminalNativeTabGroup(id:10,tabs:[11,12],selected:11),b=TerminalNativeTabGroup(id:20,tabs:[21,22],selected:22)
        var index=0
        let output=try TerminalProfileNativeCapture.capture(rows,environment:.init(groups:{[a,b]},focus:{tty in index=rows.firstIndex {$0.tty==tty}!;return rows[index].windowID},focusedGroup:{
            var group=index%2==0 ? a:b;group.selected=group.tabs[index/2];return group
        },restore:{_ in}))
        try expectEqual(output.map(\.windowID),[101,102,101,102])
        try expectEqual(output.map(\.tabOrder),[0,0,1,1])
        try expectEqual(output.map(\.selected),[true,false,false,true])
        do {
            _ = try TerminalProfileNativeCapture.capture([rows[0]],environment:.init(groups:{[a]},focus:{_ in 101},focusedGroup:{a},restore:{_ in throw AppError.message("restore failed")}))
            try expect(false,"Do not save a successful capture when selection restoration failed")
        } catch {try expect(error.localizedDescription.contains("restore failed"))}
    }

    func testTerminalNativeScriptsFindNewTabInDifferentScriptingWindowAndSelectIt() throws {
        let context=JSContext()!
        context.evaluateScript("""
        var activated=0;
        const old={tty:()=>'/dev/ttys700'},newTab={tty:()=>'/dev/ttys701',busy:()=>false,processes:()=>['-zsh']};
        const oldWindow={id:()=>77,tabs:()=>[old]},newWindow={id:()=>78,tabs:()=>[newTab]};
        function Application(){return {windows:()=>[newWindow,oldWindow],activate:()=>{activated++}};}
        const ObjC={import:()=>{}};const $={NSThread:{sleepForTimeInterval:()=>{}}};
        """)
        let result=context.evaluateScript(try TerminalProfileTabOpener.confirmationScript(anchorTTY:"/dev/ttys700",windowID:77,previousTTYs:["/dev/ttys700"]))?.toString()
        try expectNil(context.exception);try expectEqual(result,#"{"tty":"/dev/ttys701","windowID":78}"#)
        _ = context.evaluateScript(try TerminalProfileLauncher.selectionScript("/dev/ttys700"))
        try expectNil(context.exception);try expectEqual(context.evaluateScript("oldWindow.index")?.toInt32(),1)
        try expectEqual(context.evaluateScript("oldWindow.miniaturized")?.toBool(),false)
        try expectEqual(context.evaluateScript("activated")?.toInt32(),1)
        try expectThrows(try TerminalProfileLauncher.selectionScript("/dev/foreign"))
    }
}
