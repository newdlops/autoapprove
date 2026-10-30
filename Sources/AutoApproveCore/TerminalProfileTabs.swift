import Foundation
import CoreGraphics

/// Native IDs are used only during capture. Saved files contain relative groups.
public struct TerminalProfileTabSnapshot:Codable,Equatable,Sendable {
    public var tty:String
    public var windowID:UInt32
    public var windowOrder:Int
    public var tabOrder:Int
    public var selected:Bool
    public var settingsName:String?
    public var customTitle:String?
    public var selectedTTY:String?
    public init(tty:String,windowID:UInt32,windowOrder:Int,tabOrder:Int,selected:Bool=false,settingsName:String?=nil,customTitle:String?=nil,selectedTTY:String?=nil) {
        self.tty=tty;self.windowID=windowID;self.windowOrder=windowOrder;self.tabOrder=tabOrder;self.selected=selected;self.settingsName=settingsName;self.customTitle=customTitle
        self.selectedTTY=selectedTTY
    }
}

public enum TerminalProfileTopology {
    /// Verify the preceding selection and select the next exact TTY in one
    /// scripting process. Capture never needs the opener's all-TTY inventory.
    public static func focusScript(tty:String,previous:TerminalWindowMetadata? = nil) throws -> String {
        guard TerminalProfileLauncher.validTTY(tty) else {throw AppError.message("선택할 Terminal 탭을 확인하지 못했습니다.")}
        let target=try AutomationScript.literal(tty)
        let preceding=try AutomationScript.literal(previous.map {["tty":$0.tty,"windowID":$0.windowID] as JSONObject} as Any? ?? NSNull())
        return """
        (()=>{
          const app=Application('com.apple.Terminal'),wanted=\(target),previous=\(preceding),matches=[],prior=[];
          for(const window of app.windows())for(const tab of window.tabs()){
            const tty=tab.tty();if(tty===wanted)matches.push({window,tab});
            if(previous!==null&&tty===previous.tty)prior.push({window,tab});
          }
          if(previous!==null&&(prior.length!==1||Number(prior[0].window.id())!==previous.windowID||
             prior[0].window.selectedTab().tty()!==previous.tty||!prior[0].tab.selected()||prior[0].window.miniaturized()||!app.frontmost()))
            throw Error('확인 중 Terminal 선택이 바뀌었습니다. 현재 탭을 확인한 뒤 다시 불러와주세요.');
          if(matches.length!==1)throw Error('선택할 Terminal 탭이 닫혔거나 이동했습니다.');
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
          app.windows().forEach((window,windowOrder)=>{
            const matches=[];
            window.tabs().forEach((tab,tabOrder)=>{
              const tty=tab.tty();if(wanted.has(tty))matches.push({tab,tty,tabOrder});
            });
            if(!matches.length)return;
            const windowID=Number(window.id()),selectedTab=window.selectedTab(),selected=selectedTab ? selectedTab.tty():null;
            matches.forEach(({tab,tty,tabOrder})=>{
              const settingsName=String(tab.currentSettings().name()),customTitle=String(tab.customTitle());
              result.push({tty,windowID,windowOrder,tabOrder,selected:tty===selected,selectedTTY:selected,settingsName,customTitle:customTitle||null});
            });
          });return JSON.stringify(result);
        })();
        """
    }
    public static func read(ttys:[String]) throws -> [TerminalProfileTabSnapshot] {
        guard !ttys.isEmpty else {return []}
        let text=try AutomationScript.run(script(ttys:ttys),app:"Terminal",denied:.permissionDenied)
        let rows=try JSONDecoder().decode([TerminalProfileTabSnapshot].self,from:Data(text.utf8))
        let reader=try TerminalNativeTabReader.terminal(),keyboard=TerminalKeyboard.Environment.live
        var previous:TerminalWindowMetadata?
        func confirmFocus() throws {
            guard let previous else {return}
            guard let current=try keyboard.metadata(previous.tty),current.windowID==previous.windowID,current.ownerPID==previous.ownerPID,
                  current.selected,!current.minimized,keyboard.focused(current) else {throw AppError.message("확인 중 Terminal 선택이 바뀌었습니다. 현재 탭을 확인한 뒤 다시 불러와주세요.")}
        }
        return try TerminalProfileNativeCapture.capture(rows,environment:.init(groups:{try reader.groups()},focus:{tty in
            if let previous,!keyboard.focused(previous) {throw AppError.message("확인 중 Terminal 선택이 바뀌었습니다. 현재 탭을 확인한 뒤 다시 불러와주세요.")}
            let text=try keyboard.run(focusScript(tty:tty,previous:previous))
            guard let metadata=try TerminalAdapter.windowMetadata(output:text,tty:tty),metadata.ownerBundleID=="com.apple.Terminal",
                  metadata.tty==tty,metadata.selected,!metadata.minimized else {
                throw AppError.message("선택한 Terminal 탭을 확인하지 못했습니다. 다시 불러와주세요.")
            }
            try TerminalProfileReadiness.wait(message:"선택한 Terminal 탭의 화면 반영을 확인하지 못했습니다.") {keyboard.focused(metadata) ? true:nil}
            previous=metadata
            return metadata.windowID
        },focusedGroup:{try reader.focusedGroup()},restore:{groups in
            // Restore legacy selections as well as the native selected window.
            // Never type or run a command while collecting a profile.
            try confirmFocus()
            let selections=Array(Set(rows.compactMap(\.selectedTTY)))
            let target=try AutomationScript.literal(selections)
            var failure:Error?
            do {_ = try keyboard.run("const app=Application('com.apple.Terminal'),wanted=new Set(\(target)); if(app.frontmost())for(const window of app.windows())for(const tab of window.tabs())if(wanted.has(tab.tty()))window.selectedTab=tab; 'restored';")}
            catch {failure=error}
            try reader.restore(groups)
            if let failure {throw failure}
        }))
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
            result[index].entry.terminalTab=try TerminalProfileTabLayout(window:group.0,windowOrder:group.1,tabOrder:row.tabOrder,selected:row.selected,settingsName:row.settingsName,customTitle:row.customTitle).validated()
        }
        return result.enumerated().sorted {left,right in
            let a=left.element.entry.terminalTab,b=right.element.entry.terminalTab
            return (a?.windowOrder ?? 512,a?.tabOrder ?? left.offset,left.offset)<(b?.windowOrder ?? 512,b?.tabOrder ?? right.offset,right.offset)
        }.map(\.element)
    }
}

/// Cmd-T is sent only to the verified Terminal process and exact prepared window.
/// The new TTY is confirmed before any resume command can reach it.
public enum TerminalProfileTabOpener {
    private struct Prepared:Codable {var tty:String;var windowID:UInt32;var ttys:[String]}
    private static let lock=NSLock()
    public static func prepareScript(anchorTTY:String) throws -> String {
        guard TerminalProfileLauncher.validTTY(anchorTTY) else {throw AppError.message("원래 Terminal 탭을 확인하지 못했습니다.")}
        let wanted=try AutomationScript.literal(anchorTTY)
        return """
        (()=>{
          const app=Application('com.apple.Terminal'),wanted=\(wanted),matches=[],ttys=[];
          for(const window of app.windows())for(const tab of window.tabs()){
            const tty=tab.tty();ttys.push(tty);if(tty===wanted)matches.push({window,tab});
          }
          if(matches.length!==1)throw Error('원래 Terminal 탭이 닫혔거나 이동했습니다.');
          const {window,tab}=matches[0];
          window.miniaturized=false;window.selectedTab=tab;window.index=1;app.activate();
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
          for(let attempt=0;attempt<200&&Date.now()<deadline;attempt++){
            const all=[];
            for(const window of app.windows())for(const tab of window.tabs())all.push({window,tab,tty:tab.tty()});
            const anchor=all.filter(item=>item.tty===target.anchor),ttys=all.map(item=>item.tty);
            if(anchor.length!==1||Number(anchor[0].window.id())!==target.windowID||!target.previous.every(tty=>ttys.includes(tty)))throw Error('원래 탭 구성이 바뀌었습니다.');
            const added=all.filter(item=>!previous.has(item.tty));
            if(added.length>1)throw Error('새 탭이 여러 개여서 입력 대상을 확인하지 못했습니다.');
            if(added.length===1){
              const {window,tab}=added[0],processes=tab.processes();
              if(!tab.busy()&&processes.length&&processes.every(p=>/^(?:-?(?:zsh|bash|sh|fish|tcsh|csh|dash|ksh)|login)$/.test(String(p).trim().split(/\\s+/)[0].split('/').pop()))){
                window.selectedTab=tab;return JSON.stringify({tty:tab.tty(),windowID:Number(window.id())});
              }
            }
            $.NSThread.sleepForTimeInterval(0.025);
          }throw Error('같은 창의 새 탭을 확인하지 못했습니다. 개별 창으로 열지 않았습니다.');
        })();
        """
    }
    public static func open(anchorTTY:String,environment suppliedEnvironment:TerminalKeyboard.Environment? = nil,
                            nativeGroupReader:(() throws -> TerminalNativeTabGroup?)? = nil) throws -> String {
        var environment=suppliedEnvironment ?? .live
        if suppliedEnvironment == nil {
            environment.run={try AutomationScript.run($0,app:"Terminal",denied:.permissionDenied,timeout:8)}
            environment.metadata={try TerminalAppleEvents.profileWindowMetadata(tty:$0)}
        }
        var posted=false
        guard lock.lock(before:Date().addingTimeInterval(3)) else {throw RemoteHTTPError(409,"다른 Terminal 탭 복원을 마친 뒤 다시 시도해주세요.",diagnostics:["delivery":"not_started"])}
        defer {lock.unlock()}
        let deadline=environment.clock()+8
        func check() throws {
            guard !environment.cancelled(),environment.clock()<deadline else {throw AppError.message("탭 복원 준비가 중단되었습니다.")}
            // Posting has its own current authorization check. Native AX
            // reads below prove access and focus before any key is submitted.
            guard environment.postingAllowed() else {throw AppError.message("macOS가 AutoApprove의 새 탭 키 전달을 허용하지 않았습니다. 손쉬운 사용에서 이미 허용했다면 앱을 완전히 종료한 뒤 다시 열어주세요.")}
        }
        do {
            try check()
            let nativeReader=nativeGroupReader == nil ? try TerminalNativeTabReader.terminal():nil
            func nativeGroup() throws -> TerminalNativeTabGroup? {
                if let nativeGroupReader {return try nativeGroupReader()}
                return try nativeReader?.focusedGroup()
            }
            let initial=try JSONDecoder().decode(Prepared.self,from:Data(environment.run(prepareScript(anchorTTY:anchorTTY)).utf8))
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
            try check();posted=true;try environment.postPair(owner.pid,down,up)
            let text=try environment.run(confirmationScript(anchorTTY:anchorTTY,windowID:initial.windowID,previousTTYs:initial.ttys))
            guard let object=try JSONSerialization.jsonObject(with:Data(text.utf8)) as? JSONObject,let tty=object["tty"] as? String,
                  let returnedWindow=object["windowID"] as? NSNumber,
                  TerminalProfileLauncher.validTTY(tty),!initial.ttys.contains(tty) else {throw AppError.message("새 Terminal 탭의 전달 결과를 확인하지 못했습니다.")}
            guard let newMetadata=try environment.metadata(tty),newMetadata.windowID==returnedWindow.uint32Value,newMetadata.tty==tty,newMetadata.ownerPID==metadata.ownerPID,
                  newMetadata.ownerBundleID=="com.apple.Terminal",newMetadata.selected,!newMetadata.minimized else {
                throw AppError.message("새 탭을 선택한 원래 Terminal 프로세스에서 확인하지 못했습니다.")
            }
            try TerminalProfileReadiness.wait(message:"새 Terminal 탭의 화면 반영을 확인하지 못했습니다.") {environment.focused(newMetadata) ? true:nil}
            // Adding ANY tab can rebuild the AX bar and its tab objects.
            // Compare insertion positions and any surviving identities, then
            // bind the current bar through both exact TTYs below. Old AX
            // identities are never a prerequisite for the Nth addition.
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
            if let added {
                guard matchesAddition(added) else {throw AppError.message("새 탭의 묶음과 순서를 확인하지 못했습니다.")}
                // A native tab is a different scripting window. Select the
                // exact anchor to prove both TTYs share the same native bar.
                _ = try environment.run(TerminalProfileLauncher.selectionScript(anchorTTY))
                guard let anchor=try environment.metadata(anchorTTY),anchor.windowID==initial.windowID,anchor.ownerPID==metadata.ownerPID,
                      anchor.tty==anchorTTY,anchor.ownerBundleID=="com.apple.Terminal",anchor.selected,!anchor.minimized else {throw AppError.message("새 탭이 원래 탭과 같은 창에 속하는지 확인하지 못했습니다.")}
                try TerminalProfileReadiness.wait(message:"새 탭이 원래 탭과 같은 창에 속하는지 확인하지 못했습니다.") {
                    guard environment.focused(anchor),let same=try nativeGroup(),same.id==added.id,same.tabs==added.tabs,
                          same.tabs.firstIndex(of:same.selected)==anchorIndex else {return nil as Bool?}
                    return true
                }
                _ = try environment.run(TerminalProfileLauncher.selectionScript(tty))
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
            throw RemoteHTTPError(409,error.localizedDescription,diagnostics:posted ? nil:["delivery":"not_started"])
        }
    }
}
