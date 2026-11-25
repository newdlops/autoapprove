import Foundation
import CoreGraphics
import AppKit

enum TerminalProfileScriptQueries {
    static let windowIDs = """
    function realWindowIDs(ids){
      if(!Array.isArray(ids)||ids.length>512||ids.some(id=>id!==null&&(!Number.isInteger(id)||id<=0)))
        throw Error('Terminal 창·탭 구성을 확인하지 못했습니다.');
      const real=ids.filter(id=>id!==null);
      if(new Set(real).size!==real.length)throw Error('Terminal 창을 구분하지 못했습니다.');
      return real;
    }
    """
    static let inventory = windowIDs + """

    function inventory(){
      const ids=app.windows.id(),real=realWindowIDs(ids);
      let groups=real.length===ids.length
        ? app.windows.tabs.tty()
        : real.map(id=>app.windows.byId(id).tabs.tty());
      if(JSON.stringify(ids)!==JSON.stringify(app.windows.id())){
        const current=realWindowIDs(app.windows.id());
        if(current.length!==real.length||current.some(id=>!real.includes(id)))throw Error('Terminal 창·탭 구성이 바뀌었습니다.');
        groups=real.map(id=>app.windows.byId(id).tabs.tty());
      }
      if(!Array.isArray(groups)||real.length!==groups.length||groups.some(tabs=>!Array.isArray(tabs)))
        throw Error('Terminal 창·탭 구성이 바뀌었습니다.');
      const rows=[],seen=new Set();
      groups.forEach((tabs,index)=>tabs.forEach(tty=>{
        if(typeof tty!=='string'||!/^\\/dev\\/ttys[0-9]+$/.test(tty)||seen.has(tty)||rows.length>=4095)
          throw Error('Terminal 탭을 구분하지 못했습니다.');
        seen.add(tty);rows.push({tty,windowID:real[index]});
      }));return rows;
    }
    function exactTab(row){
      const window=app.windows.byId(row.windowID);
      if(!window.exists()||Number(window.id())!==row.windowID)throw Error('선택할 Terminal 창이 닫혔거나 바뀌었습니다.');
      const tabs=window.tabs.whose({tty:row.tty})();
      if(tabs.length!==1||tabs[0].tty()!==row.tty)throw Error('선택할 Terminal 탭이 닫혔거나 이동했습니다.');
      return {window,tab:tabs[0]};
    }
    """
    static let matchingTab = """
    function matchingTab(tty){
      const groups=app.windows.tabs.whose({tty})();
      if(!Array.isArray(groups)||groups.length>512||groups.some(tabs=>!Array.isArray(tabs)))
        throw Error('새 Terminal 탭을 확인하지 못했습니다.');
      const matches=groups.flat();
      if(matches.length!==1||matches[0].tty()!==tty)throw Error('새 Terminal 탭을 확인하지 못했습니다.');
      return matches[0];
    }
    """
}

public struct TerminalProfileTabSnapshot:Codable,Equatable,Sendable {
    public var tty:String
    public var windowID:UInt32
    public var windowOrder:Int
    public var tabOrder:Int
    public var selected:Bool
    public var settingsName:String?
    public var customTitle:String?
    public var bounds:TerminalWindowBounds?
    public var selectedTTY:String?
    public init(tty:String,windowID:UInt32,windowOrder:Int,tabOrder:Int,selected:Bool=false,settingsName:String?=nil,customTitle:String?=nil,selectedTTY:String?=nil) {
        self.tty=tty;self.windowID=windowID;self.windowOrder=windowOrder;self.tabOrder=tabOrder;self.selected=selected;self.settingsName=settingsName;self.customTitle=customTitle
        self.selectedTTY=selectedTTY
    }
}

public enum TerminalProfileTopology {
    public static func focusScript(tty:String,windowID:UInt32? = nil,previous:TerminalWindowMetadata? = nil) throws -> String {
        guard TerminalProfileLauncher.validTTY(tty),windowID.map({$0>0}) ?? true else {throw AppError.message("선택할 Terminal 탭을 확인하지 못했습니다.")}
        let target=try AutomationScript.literal(tty)
        let preceding=try AutomationScript.literal(previous.map {["tty":$0.tty,"windowID":$0.windowID] as JSONObject} as Any? ?? NSNull())
        let lookup:String
        if let windowID {
            lookup="""
            const wantedWindow=app.windows.byId(\(windowID));
            if(!wantedWindow.exists()||Number(wantedWindow.id())!==\(windowID))throw Error('선택할 Terminal 창이 닫혔거나 바뀌었습니다.');
            for(const tab of wantedWindow.tabs.whose({tty:wanted})())matches.push({window:wantedWindow,tab});
            if(previous!==null){
              const window=app.windows.byId(previous.windowID);
              if(window.exists())for(const tab of window.tabs.whose({tty:previous.tty})())prior.push({window,tab});
            }
            """
        } else {
            lookup="""
            for(const window of app.windows())for(const tab of window.tabs()){
              const tty=tab.tty();if(tty===wanted)matches.push({window,tab});
              if(previous!==null&&tty===previous.tty)prior.push({window,tab});
            }
            """
        }
        return """
        (()=>{
          const app=Application('com.apple.Terminal'),wanted=\(target),previous=\(preceding),matches=[],prior=[];
          \(lookup)
          if(previous!==null&&(prior.length!==1||Number(prior[0].window.id())!==previous.windowID||
             prior[0].tab.tty()!==previous.tty||prior[0].window.selectedTab().tty()!==previous.tty||!prior[0].tab.selected()||prior[0].window.miniaturized()||!app.frontmost()))
            throw Error('확인 중 Terminal 선택이 바뀌었습니다. 현재 탭을 확인한 뒤 다시 불러와주세요.');
          if(matches.length!==1||matches[0].tab.tty()!==wanted)throw Error('선택할 Terminal 탭이 닫혔거나 이동했습니다.');
          const {window,tab}=matches[0];window.miniaturized=false;window.selectedTab=tab;window.index=1;app.activate();
          return JSON.stringify({tty:wanted,windowID:Number(window.id()),selected:window.selectedTab().tty()===wanted&&tab.selected(),minimized:window.miniaturized()});
        })();
        """
    }
    public static func script(ttys:[String]) throws -> String {
        let targets=try AutomationScript.literal(ttys)
        return """
        (()=>{
          const app=Application('com.apple.Terminal'),wanted=new Set(\(targets)),result=[];
          if(!app.running())throw Error('Terminal이 실행 중이 아닙니다.');
          \(TerminalProfileScriptQueries.windowIDs)
          const windows=app.windows,ids=windows.id(),real=realWindowIDs(ids);
          const readTTYs=()=>real.length===ids.length ? windows.tabs.tty() : real.map(id=>windows.byId(id).tabs.tty());
          const ttys=readTTYs();
          if(!Array.isArray(ttys)||ttys.length!==real.length||ttys.some(tabs=>!Array.isArray(tabs)))
            throw Error('Terminal 창·탭 구성을 확인하지 못했습니다.');
          function bulk(query){
            if(real.length!==ids.length)return null;
            try {const values=query(windows);return Array.isArray(values)&&values.length===real.length ? values:null;}
            catch(error){if(error.errorNumber!==-1728)throw error;return null;}
          }
          const selected=bulk(w=>w.selectedTab.tty()),settings=bulk(w=>w.tabs.currentSettings.name()),titles=bulk(w=>w.tabs.customTitle());
          real.forEach((windowID,w)=>{
            const tabs=ttys[w];
            if(!tabs.some(tty=>wanted.has(tty)))return;
            const window=windows.byId(windowID);
            let active;
            if(selected)active=selected[w];
            else {const tab=window.selectedTab();active=tab ? tab.tty():null;}
            const names=settings ? settings[w]:window.tabs.currentSettings.name();
            const labels=titles ? titles[w]:window.tabs.customTitle();
            if(![names,labels].every(c=>Array.isArray(c)&&c.length===tabs.length)||(active!=null&&!tabs.includes(active)))
              throw Error('Terminal 탭 순서가 바뀌었습니다.');
            tabs.forEach((tty,t)=>{
              if(wanted.has(tty))result.push({tty,windowID,windowOrder:w,tabOrder:t,selected:tty===active,
                selectedTTY:active,settingsName:names[t],customTitle:labels[t]||null});
            });
          });
          if(JSON.stringify(ids)!==JSON.stringify(windows.id())||JSON.stringify(ttys)!==JSON.stringify(readTTYs()))
            throw Error('Terminal 창·탭 구성이 바뀌었습니다.');
          return JSON.stringify(result);
        })();
        """
    }

    private static func readRows(_ ttys:[String], timeout:TimeInterval) throws -> [TerminalProfileTabSnapshot] {
        let text=try AutomationScript.run(script(ttys:ttys),app:"Terminal",denied:.permissionDenied,timeout:timeout,readOnly:true)
        let rows=try JSONDecoder().decode([TerminalProfileTabSnapshot].self,from:Data(text.utf8))
        guard rows.count==ttys.count,Set(rows.map(\.tty))==Set(ttys),Set(ttys).count==ttys.count else {
            throw AppError.message("Terminal 창·탭 구성이 바뀌었습니다. 다시 불러와주세요.")
        }
        return rows
    }

    public static func read(ttys:[String]) throws -> [TerminalProfileTabSnapshot] {
        guard !ttys.isEmpty else {return []}
        let gate=AutomationIPC.shared,owner=try TerminalProcessLookup.running()
        let reader=try TerminalNativeTabReader.terminal(owner:owner)
        let timeout=min(45,max(8,Double(ttys.count)*1.5))
        let (rows,original)=try gate.run(host:"Terminal",readOnly:true,budget:timeout+3,admissionWait:3) {
            var rows=try readRows(ttys,timeout:timeout)
            let windows=CGWindowListCopyWindowInfo([.optionAll,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
            let frames=TerminalProfileWindowPlacement.frames(windows,owner:owner.pid)
            for index in rows.indices {rows[index].bounds=frames[rows[index].windowID]}
            return (rows,try reader.layoutWindows())
        }
        guard !original.groups.isEmpty || rows.allSatisfy({ original.standalone.contains($0.windowID) }) else {
            throw AppError.message("Terminal의 현재 창과 탭을 확인하지 못했습니다. 배치를 다시 읽어주세요.")
        }
        let captured = try TerminalProfileNativeCapture.capture(rows,original:Array(original.groups.values)) {row in
            if original.standalone.contains(row.windowID) {return nil}
            if let visible = original.groups[row.windowID] {return visible}
            return try gate.run(host:"Terminal",readOnly:false,budget:8,admissionWait:5) {
                try reader.inspectWindow(row,original:original)
            }
        }
        let final = try gate.run(host:"Terminal",readOnly:true,budget:timeout+3,admissionWait:5) {
            (try readRows(ttys,timeout:timeout),try reader.layoutWindows())
        }
        let verified = Dictionary(uniqueKeysWithValues:final.0.map { ($0.tty,$0) })
        guard original.sameTabs(as:final.1),rows.allSatisfy({ row in
            verified[row.tty]?.windowID == row.windowID && verified[row.tty]?.tabOrder == row.tabOrder
        }) else {throw AppError.message("읽는 동안 Terminal 창·탭 배치가 바뀌었습니다. 배치를 다시 읽어주세요.")}
        return captured
    }

    static func readForProfile(ttys:[String]) async throws -> [TerminalProfileTabSnapshot] {
        let work=Task.detached(priority:.userInitiated) {try read(ttys:ttys)}
        return try await withTaskCancellationHandler(operation:{try await work.value},onCancel:{work.cancel()})
    }
    public static func apply(_ snapshots:[TerminalProfileTabSnapshot],to candidates:[TerminalProfileCandidate]) throws -> [TerminalProfileCandidate] {
        let terminal=candidates.filter {$0.entry.host == .terminal && $0.tty != nil}
        let wanted=Set(terminal.compactMap(\.tty)),rows=snapshots.filter {wanted.contains($0.tty)}
        guard terminal.count==wanted.count,rows.count==wanted.count,Set(rows.map(\.tty))==wanted,Set(rows.map(\.tty)).count==rows.count,
              rows.allSatisfy({$0.windowID>0 && (0..<512).contains($0.windowOrder)}) else {throw AppError.message("Terminal 창·탭 구성을 확인하지 못했습니다. 창을 다시 불러와주세요.")}
        let nativeGroups=Dictionary(grouping:rows,by:\.windowID)
        guard Set(nativeGroups.values.compactMap {$0.first?.windowOrder}).count==nativeGroups.count,
              nativeGroups.values.allSatisfy({group in Set(group.map(\.windowOrder)).count==1 && Set(group.map(\.tabOrder)).count==group.count && group.filter(\.selected).count<=1}) else {
            throw AppError.message("Terminal 창·탭 구성이 바뀌었습니다. 현재 창을 다시 불러와주세요.")
        }
        let windowIDs=Array(Set(rows.map(\.windowID))).sorted {left,right in
            (rows.first {$0.windowID==left}!.windowOrder,left)<(rows.first {$0.windowID==right}!.windowOrder,right)
        }
        let groups=Dictionary(uniqueKeysWithValues:windowIDs.enumerated().map {($0.element,(UUID(),$0.offset))})
        var result=candidates
        for index in result.indices {
            guard result[index].entry.host == .terminal,let tty=result[index].tty,let row=rows.first(where:{$0.tty==tty}),let group=groups[row.windowID] else {continue}
            result[index].entry.terminalTab=try TerminalProfileTabLayout(window:group.0,windowOrder:group.1,tabOrder:row.tabOrder,selected:row.selected,settingsName:row.settingsName,customTitle:row.customTitle,bounds:row.bounds).validated()
        }
        return result.enumerated().sorted {left,right in
            let a=left.element.entry.terminalTab,b=right.element.entry.terminalTab
            return (a?.windowOrder ?? 512,a?.tabOrder ?? left.offset,left.offset)<(b?.windowOrder ?? 512,b?.tabOrder ?? right.offset,right.offset)
        }.map(\.element)
    }
}

public enum TerminalProfileTabOpener {
    private struct Prepared:Codable {var tty:String;var windowID:UInt32;var ttys:[String]}
    private static let lock=NSLock()
    public static func prepareScript(anchorTTY:String,settingsName:String? = nil,select:Bool = true) throws -> String {
        guard TerminalProfileLauncher.validTTY(anchorTTY) else {throw AppError.message("원래 Terminal 탭을 확인하지 못했습니다.")}
        let wanted=try AutomationScript.literal(anchorTTY)
        let settings=try AutomationScript.literal(settingsName as Any? ?? NSNull())
        return """
        (()=>{
          const app=Application('com.apple.Terminal'),wanted=\(wanted),settings=\(settings);
          if(settings!==null&&!app.settingsSets.byName(settings).exists())throw Error('저장한 Terminal 설정 프로필이 없습니다.');
          \(TerminalProfileScriptQueries.inventory)
          const rows=inventory(),anchor=rows.find(row=>row.tty===wanted),ttys=rows.map(row=>row.tty);
          if(!anchor)throw Error('원래 Terminal 탭이 닫혔거나 이동했습니다.');
          const {window,tab}=exactTab(anchor);
          \(select ? "window.miniaturized=false;window.selectedTab=tab;window.index=1;app.activate();" : "")
          return JSON.stringify({tty:wanted,windowID:Number(window.id()),ttys});
        })();
        """
    }
    public static func confirmationScript(anchorTTY:String,windowID:UInt32,previousTTYs:[String]) throws -> String {
        let target=try AutomationScript.literal(["anchor":anchorTTY,"windowID":windowID,"previous":previousTTYs] as JSONObject)
        return """
        (()=>{
          ObjC.import('Foundation');
          const app=Application('com.apple.Terminal'),target=\(target),previous=new Set(target.previous),deadline=Date.now()+5000;
          \(TerminalProfileScriptQueries.inventory)
          for(let attempt=0;attempt<200&&Date.now()<deadline;attempt++){
            const all=inventory();
            const anchor=all.filter(item=>item.tty===target.anchor),ttys=all.map(item=>item.tty);
            if(anchor.length!==1||anchor[0].windowID!==target.windowID||!target.previous.every(tty=>ttys.includes(tty)))throw Error('원래 탭 구성이 바뀌었습니다.');
            const added=all.filter(item=>!previous.has(item.tty));
            if(added.length>1)throw Error('새 탭이 여러 개여서 입력 대상을 확인하지 못했습니다.');
            if(added.length===1){
              const {window,tab}=exactTab(added[0]),processes=tab.processes();
              if(!tab.busy()&&processes.length&&processes.every(p=>/^(?:-?(?:zsh|bash|sh|fish|tcsh|csh|dash|ksh)|login)$/.test(String(p).trim().split(/\\s+/)[0].split('/').pop()))){
                window.selectedTab=tab;return JSON.stringify({tty:tab.tty(),windowID:Number(window.id())});
              }
            }
            $.NSThread.sleepForTimeInterval(0.025);
          }throw Error('같은 창의 새 탭을 확인하지 못했습니다. 개별 창으로 열지 않았습니다.');
        })();
        """
    }
    public static func openForProfile(anchorTTY: String, settingsName: String?) throws -> String {
        var posted = false
        do {
            let owner = try TerminalProcessLookup.running()
            let reader = try TerminalNativeTabReader.terminal(owner: owner)
            func run(_ body: String) throws -> String {
                try AutomationScript.run(body, app: "Terminal", denied: .permissionDenied, timeout: 6)
            }
            let initial = try JSONDecoder().decode(Prepared.self, from: Data(run(prepareScript(anchorTTY: anchorTTY, settingsName: settingsName, select: false)).utf8))
            guard initial.tty == anchorTTY, initial.ttys.contains(anchorTTY) else { throw AppError.message("탭을 추가할 원래 창이 닫혔습니다.") }
            let previousFocus = reader.frontWindow()
            func locate() throws -> TerminalNativeTabGroup? {
                if let bar = try reader.tabBar(windowID: initial.windowID) { return bar }
                _ = try run(TerminalProfileLauncher.selectionScript(anchorTTY, activate: false))
                return try reader.tabBar(windowID: initial.windowID)
            }
            guard var bar = try locate() else {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == owner.pid {
                    do { return try open(anchorTTY: anchorTTY, settingsName: settingsName) }
                    catch let error as RemoteHTTPError {
                        posted = error.diagnostics?["tab_creation"] == "unknown"
                        throw error
                    }
                }
                throw AppError.message("원래 창의 탭 막대를 찾지 못했습니다. Terminal의 보기 메뉴에서 탭 막대를 표시해주세요.")
            }
            do { try reader.pressNewTab(in: bar, windowID: initial.windowID) { posted = true } }
            catch {
                guard !posted, let fresh = try locate() else { throw error }
                bar = fresh
                try reader.pressNewTab(in: fresh, windowID: initial.windowID) { posted = true }
            }
            let previous = try AutomationScript.literal(initial.ttys)
            let windowID: UInt32
            do {
                windowID = try TerminalProfileReadiness.wait(timeout: 0.5, message: "새 탭 선택을 확인하지 못했습니다.") {
                    try reader.addedWindow(in: bar)
                }
            } catch {
                try Task.checkCancellation()
                let text = try run("""
                (() => {
                  const app=Application('com.apple.Terminal'), previous=new Set(\(previous));
                  \(TerminalProfileScriptQueries.inventory)
                  const rows=inventory(), added=rows.filter(row=>!previous.has(row.tty));
                  if(added.length!==1 || rows.length!==previous.size+1)throw Error('추가된 탭 하나를 구분하지 못했습니다.');
                  const {window,tab}=exactTab(added[0]);window.selectedTab=tab;window.index=1;
                  return String(added[0].windowID);
                })();
                """)
                guard let candidate = UInt32(text) else { throw AppError.message("새 탭의 창을 확인하지 못했습니다.") }
                windowID = try TerminalProfileReadiness.wait(message: "새 탭이 원래 창에 추가됐는지 확인하지 못했습니다.") {
                    try reader.addedWindow(in: bar) == candidate ? candidate : nil
                }
            }
            reader.returnFocus(to: previousFocus, afterOpening: windowID)
            let result = try run("""
            (() => {
              const app = Application('com.apple.Terminal'), previous = new Set(\(previous));
              const window = app.windows.byId(\(windowID));
              if (!window.exists() || Number(window.id()) !== \(windowID)) throw Error('새 탭이 닫혔습니다.');
              const tty = window.selectedTab().tty();
              if (!tty || previous.has(tty)) throw Error('새 탭의 터미널 장치를 확인하지 못했습니다.');
              return tty;
            })();
            """)
            guard TerminalProfileLauncher.validTTY(result), TerminalProcessLookup.identity(pid: owner.pid) == owner else {
                throw AppError.message("새 Terminal 탭의 장치가 바뀌었습니다.")
            }
            return result
        } catch {
            var details = ["command_delivery": "not_started"]
            details[posted ? "tab_creation" : "delivery"] = posted ? "unknown" : "not_started"
            throw RemoteHTTPError(409, error.localizedDescription, diagnostics: details)
        }
    }

    public static func open(anchorTTY:String,settingsName:String? = nil,environment suppliedEnvironment:TerminalKeyboard.Environment? = nil,
                            nativeGroupReader:(() throws -> TerminalNativeTabGroup?)? = nil,
                            nativeTabSelector:((TerminalNativeTabGroup,TerminalNativeTabGroup) throws -> Void)? = nil) throws -> String {
        let open = {
            try openVerified(anchorTTY:anchorTTY,settingsName:settingsName,environment:suppliedEnvironment,
                             nativeGroupReader:nativeGroupReader,nativeTabSelector:nativeTabSelector)
        }
        if suppliedEnvironment == nil {
            return try AutomationIPC.shared.runInput(host:"Terminal",budget:12,admissionWait:3,body:open)
        }
        return try open()
    }

    private static func openVerified(anchorTTY:String,settingsName:String?,environment suppliedEnvironment:TerminalKeyboard.Environment?,
                                     nativeGroupReader:(() throws -> TerminalNativeTabGroup?)?,
                                     nativeTabSelector:((TerminalNativeTabGroup,TerminalNativeTabGroup) throws -> Void)?) throws -> String {
        var environment=suppliedEnvironment ?? .live
        if suppliedEnvironment == nil {
            environment.run={try AutomationScript.run($0,app:"Terminal",denied:.permissionDenied,timeout:8)}
        }
        var posted=false
        var stage="Terminal 연결 준비"
        guard lock.lock(before:Date().addingTimeInterval(3)) else {throw RemoteHTTPError(409,"다른 Terminal 탭 복원을 마친 뒤 다시 시도해주세요.",diagnostics:["delivery":"not_started"])}
        defer {lock.unlock()}
        let deadline=environment.clock()+8
        func check() throws {
            guard !environment.cancelled(),environment.clock()<deadline else {throw AppError.message("탭 복원 준비가 중단되었습니다.")}
            guard environment.postingAllowed() else {throw AppError.message("macOS가 AutoApprove의 새 탭 키 전달을 허용하지 않았습니다. 손쉬운 사용에서 이미 허용했다면 앱을 완전히 종료한 뒤 다시 열어주세요.")}
        }
        do {
            try check()
            let ownerIdentity=suppliedEnvironment == nil ? try TerminalProcessLookup.running():nil
            if let ownerIdentity {
                environment.metadata={try TerminalAppleEvents.profileWindowMetadata(tty:$0,owner:ownerIdentity)}
                environment.processes={try ProcessDiscovery.read(pid:ownerIdentity.pid)}
            }
            let nativeReader=nativeGroupReader == nil ? try TerminalNativeTabReader.terminal(owner:ownerIdentity):nil
            func nativeGroup() throws -> TerminalNativeTabGroup? {
                if let nativeGroupReader {return try nativeGroupReader()}
                return try nativeReader?.focusedGroup()
            }
            func selectNative(_ state:TerminalNativeTabGroup,from expected:TerminalNativeTabGroup,tty:String) throws {
                if let nativeTabSelector {try nativeTabSelector(state,expected)}
                else if suppliedEnvironment==nil,let nativeReader {try nativeReader.select(state,expected:expected)}
                else {_ = try environment.run(TerminalProfileLauncher.selectionScript(tty))}
            }
            stage="기존 창·탭 연결 확인"
            let initial=try JSONDecoder().decode(Prepared.self,from:Data(environment.run(prepareScript(anchorTTY:anchorTTY,settingsName:settingsName)).utf8))
            guard initial.tty==anchorTTY,initial.windowID>0,initial.ttys.contains(anchorTTY),initial.ttys.count<4096,
                  Set(initial.ttys).count==initial.ttys.count,
                  let metadata=try environment.metadata(anchorTTY),metadata.windowID==initial.windowID,
                  metadata.tty==anchorTTY,metadata.ownerPID>0,metadata.ownerBundleID=="com.apple.Terminal",metadata.selected,!metadata.minimized,
                  environment.ownerBundle(metadata.ownerPID)=="com.apple.Terminal",
                  let owner=try environment.processes().first(where:{$0.pid==metadata.ownerPID}),!owner.started.isEmpty else {
                throw AppError.message("탭을 추가할 원래 Terminal 창을 확인하지 못했습니다.")
            }
            try TerminalProfileReadiness.wait(message:"탭을 추가할 Terminal 창의 선택을 확인하지 못했습니다.") {environment.focused(metadata) ? true:nil}
            let before=try nativeGroup()
            guard before?.isValid ?? true else {throw AppError.message("원래 Terminal 탭 묶음을 확인하지 못했습니다.")}
            let source=CGEventSource(stateID:.privateState)
            guard let source,let down=CGEvent(keyboardEventSource:source,virtualKey:17,keyDown:true),let up=CGEvent(keyboardEventSource:source,virtualKey:17,keyDown:false) else {throw AppError.message("새 탭 키를 준비하지 못했습니다.")}
            down.flags = .maskCommand;up.flags = []
            guard let fresh=try environment.metadata(anchorTTY),fresh.windowID==metadata.windowID,fresh.ownerPID==metadata.ownerPID,
                  fresh.ownerBundleID==metadata.ownerBundleID,fresh.tty==anchorTTY,fresh.selected,!fresh.minimized,
                  environment.focused(fresh),environment.ownerBundle(metadata.ownerPID)=="com.apple.Terminal",
                  try environment.processes().contains(where:{$0.pid==owner.pid && $0.started==owner.started}) else {
                throw AppError.message("선택한 Terminal 창이 바뀌어 탭을 열지 않았습니다.")
            }
            stage="새 탭 생성"
            try check();posted=true;try environment.postPair(owner.pid,down,up)
            stage="새 탭 연결 확인"
            let text=try environment.run(confirmationScript(anchorTTY:anchorTTY,windowID:initial.windowID,previousTTYs:initial.ttys))
            guard let object=try JSONSerialization.jsonObject(with:Data(text.utf8)) as? JSONObject,let tty=object["tty"] as? String,
                  let returnedWindow=object["windowID"] as? NSNumber,
                  TerminalProfileLauncher.validTTY(tty),!initial.ttys.contains(tty) else {throw AppError.message("새 Terminal 탭의 전달 결과를 확인하지 못했습니다.")}
            guard let newMetadata=try environment.metadata(tty),newMetadata.windowID==returnedWindow.uint32Value,newMetadata.tty==tty,newMetadata.ownerPID==metadata.ownerPID,
                  newMetadata.ownerBundleID=="com.apple.Terminal",newMetadata.selected,!newMetadata.minimized else {
                throw AppError.message("새 탭을 선택한 원래 Terminal 프로세스에서 확인하지 못했습니다.")
            }
            try TerminalProfileReadiness.wait(message:"새 Terminal 탭의 화면 반영을 확인하지 못했습니다.") {environment.focused(newMetadata) ? true:nil}
            stage="새 탭의 창 묶음 확인"
            let anchorIndex=before.flatMap {$0.tabs.firstIndex(of:$0.selected)} ?? 0
            func matchesAddition(_ value:TerminalNativeTabGroup)->Bool {
                guard value.isValid,value.tabs.count==(before?.tabs.count ?? 1)+1,
                      value.tabs.firstIndex(of:value.selected)==anchorIndex+1 else {return false}
                guard let before else {return true}
                guard !before.tabs.contains(value.selected) else {return false}
                let remaining=value.tabs.filter {$0 != value.selected}
                return before.tabs.enumerated().allSatisfy {index,tab in
                    !remaining.contains(tab) || remaining[index]==tab
                }
            }
            let added:TerminalNativeTabGroup?=try TerminalProfileReadiness.wait(message:"새 탭의 묶음과 순서를 확인하지 못했습니다.") {() throws -> TerminalNativeTabGroup?? in
                let value=try nativeGroup()
                if let value,matchesAddition(value) {return .some(value)}
                if value==nil,before==nil,newMetadata.windowID==initial.windowID {return .some(nil)}
                return nil
            }
            if let added, let before, added.addingOneTab(to:before),
               try nativeGroup()==added, environment.focused(newMetadata) {
                return tty
            }
            if let added {
                guard matchesAddition(added) else {throw AppError.message("새 탭의 묶음과 순서를 확인하지 못했습니다.")}
                var anchorGroup=added;anchorGroup.selected=added.tabs[anchorIndex]
                try selectNative(anchorGroup,from:added,tty:anchorTTY)
                guard let anchor=try environment.metadata(anchorTTY),anchor.windowID==initial.windowID,anchor.ownerPID==metadata.ownerPID,
                      anchor.tty==anchorTTY,anchor.ownerBundleID=="com.apple.Terminal",anchor.selected,!anchor.minimized else {throw AppError.message("새 탭이 원래 탭과 같은 창에 속하는지 확인하지 못했습니다.")}
                try TerminalProfileReadiness.wait(message:"새 탭이 원래 탭과 같은 창에 속하는지 확인하지 못했습니다.") {
                    guard environment.focused(anchor),let same=try nativeGroup(),same.id==added.id,same.tabs==added.tabs,
                          same.tabs.firstIndex(of:same.selected)==anchorIndex else {return nil as Bool?}
                    return true
                }
                try selectNative(added,from:anchorGroup,tty:tty)
                guard let target=try environment.metadata(tty),target.windowID==newMetadata.windowID,target.ownerPID==metadata.ownerPID,
                      target.tty==tty,target.ownerBundleID=="com.apple.Terminal",target.selected,!target.minimized else {
                    throw AppError.message("새 Terminal 탭이 바뀌어 대화 명령을 보내지 않았습니다.")
                }
                try TerminalProfileReadiness.wait(message:"새 Terminal 탭이 바뀌어 대화 명령을 보내지 않았습니다.") {
                    guard environment.focused(target),try nativeGroup()==added else {return nil as Bool?}
                    return true
                }
            } else {
                guard before==nil,newMetadata.windowID==initial.windowID else {throw AppError.message("같은 창의 새 탭을 확인하지 못했습니다. 개별 창으로 열지 않았습니다.")}
            }
            return tty
        }catch {
            var diagnostics=["command_delivery":"not_started"]
            if !posted {diagnostics["delivery"]="not_started"}
            else {diagnostics["tab_creation"]="unknown"}
            throw RemoteHTTPError(409,stage+": "+error.localizedDescription,diagnostics:diagnostics)
        }
    }
}
