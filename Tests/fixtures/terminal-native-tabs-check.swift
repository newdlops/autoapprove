import AppKit
import ApplicationServices
import AutoApproveCore

@MainActor private final class NativeTabsFixture:NSObject,NSApplicationDelegate {
    var windows:[NSWindow]=[]
    var labels:[NSTextField]=[]
    var running=false
    var originalSelections:[NSWindow]=[]
    var originalKeyWindow:NSWindow?
    func applicationDidFinishLaunching(_ notification:Notification) {
        NSWindow.allowsAutomaticWindowTabbing=false
        for index in 0..<5 {windows.append(makeWindow(index))}
        windows[0].makeKeyAndOrderFront(nil)
        windows[0].addTabbedWindow(windows[1],ordered:.above)
        windows[1].addTabbedWindow(windows[2],ordered:.above)
        windows[3].makeKeyAndOrderFront(nil)
        windows[3].addTabbedWindow(windows[4],ordered:.above)
        windows[4].makeKeyAndOrderFront(nil)
        windows[1].makeKeyAndOrderFront(nil)
        NSApp.activate()
        let menu=NSMenu(),item=NSMenuItem(),appMenu=NSMenu();menu.addItem(item)
        appMenu.addItem(withTitle:"Quit Native Tabs Check",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");item.submenu=appMenu;NSApp.mainMenu=menu
    }
    @objc func startCheck() {
        guard !running else {return};running=true
        originalSelections=[windows[0].tabGroup!.selectedWindow!,windows[3].tabGroup!.selectedWindow!]
        originalKeyWindow=NSApp.keyWindow
        let rows=windows.enumerated().map {index,window in TerminalProfileTabSnapshot(tty:"/dev/ttys\(800+index)",windowID:UInt32(window.windowNumber),windowOrder:index,tabOrder:0,selected:true,customTitle:"동일 제목")}
        DispatchQueue.global(qos:.userInitiated).async {self.run(rows)}
    }
    func makeWindow(_ index:Int)->NSWindow {
        let window=NSWindow(contentRect:NSRect(x:index<3 ? 80:880,y:180,width:740,height:440),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        window.title="Native Tabs Check \(index+1)";window.tab.title="동일 제목";window.tabbingMode = .preferred
        let label=NSTextField(wrappingLabelWithString:"격리된 macOS 기본 탭 \(index+1)\n생성된 창과 탭만 검사합니다.")
        label.font = .systemFont(ofSize:24);label.frame=NSRect(x:30,y:170,width:670,height:160)
        window.contentView?.addSubview(label);labels.append(label)
        let button=NSButton(title:"탭 복원 검사 시작",target:self,action:#selector(startCheck));button.frame=NSRect(x:30,y:80,width:220,height:40)
        window.contentView?.addSubview(button);return window
    }
    nonisolated func run(_ rows:[TerminalProfileTabSnapshot]) {
        var report:[String:Any]=["realTerminalAccess":false,"liveTerminalAXRestoreTested":false,"accessibilityTrusted":AXIsProcessTrusted(),"selectionRestoreAdapter":"own AppKit windows"]
        func attribute(_ element:AXUIElement,_ name:String)->CFTypeRef? {var value:CFTypeRef?;return AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success ? value:nil}
        let app=AXUIElementCreateApplication(getpid())
        let nativeWindows=attribute(app,kAXWindowsAttribute) as? [AXUIElement] ?? []
        report["tabActions"]=nativeWindows.flatMap {window in
            (attribute(window,kAXChildrenAttribute) as? [AXUIElement] ?? []).flatMap {child in
                (attribute(child,kAXTabsAttribute) as? [AXUIElement] ?? []).map {tab -> [String:Any] in
                    var actions:CFArray?,settable=DarwinBoolean(false)
                    let status=AXUIElementCopyActionNames(tab,&actions)
                    let writable=AXUIElementIsAttributeSettable(tab,kAXValueAttribute as CFString,&settable)
                    return ["actions":actions as? [String] ?? [],"actionStatus":status.rawValue,"settable":settable.boolValue,"settableStatus":writable.rawValue]
                }
            }
        }
        do {
            let live=TerminalNativeTabReader.Services.live
            report["liveForegroundConfirmed"]=live.foreground(getpid())
            report["liveOwnerConfirmed"]=live.ownsProcess(getpid(),Bundle.main.bundleIdentifier!)
            let active=DispatchQueue.main.sync {NSApp.isActive}
            report["ownAppActive"]=active
            var frontmost:CFTypeRef?
            report["AXFrontmostStatus"]=AXUIElementCopyAttributeValue(app,kAXFrontmostAttribute as CFString,&frontmost).rawValue
            report["AXFrontmostValue"]=(frontmost as? NSNumber)?.boolValue ?? false
            guard live.ownsProcess(getpid(),Bundle.main.bundleIdentifier!),live.foreground(getpid())==active else {throw AppError.message("Own live AX foreground/owner validation failed")}
            let reader=TerminalNativeTabReader(ownerPID:getpid(),bundleID:Bundle.main.bundleIdentifier!)
            var baseline:[TerminalNativeTabGroup]=[]
            let captured=try TerminalProfileNativeCapture.capture(rows,environment:.init(groups:{baseline=try reader.groups();return baseline},focus:{tty in
                let index=rows.firstIndex {$0.tty==tty}!
                return DispatchQueue.main.sync {self.windows[index].makeKeyAndOrderFront(nil);NSApp.activate();return UInt32(self.windows[index].windowNumber)}
            },focusedGroup:{try reader.focusedGroup()},restore:{_ in
                // No TCC grant is requested for the fixture. Restore only our
                // own AppKit windows; live Terminal uses the guarded AX action.
                DispatchQueue.main.sync {
                    for window in self.originalSelections {window.tabGroup?.selectedWindow=window}
                    self.originalKeyWindow?.makeKeyAndOrderFront(nil)
                }
            }))
            report["nativeGroups"]=baseline.count;report["capturedWindowGroups"]=Set(captured.map(\.windowID)).count
            report["tabOrder"]=captured.map(\.tabOrder);report["selected"]=captured.map(\.selected)
            report["nativeRoles"]=nativeWindows.map {window in
                (attribute(window,kAXChildrenAttribute) as? [AXUIElement] ?? []).map {child in
                    ["role":attribute(child,kAXRoleAttribute) as? String ?? "nil","tabs":(attribute(child,kAXTabsAttribute) as? [AXUIElement])?.count ?? 0]
                }
            }
            guard baseline.count==2,Set(captured.map(\.windowID)).count==2,
                  captured.map(\.tabOrder)==[0,1,2,0,1],captured.map(\.selected)==[false,true,false,false,true] else {throw AppError.message("Native layout differs from the two actual tab groups")}
            let restored=try reader.groups()
            report["baselineGroups"]=baseline.map {["id":$0.id,"tabs":$0.tabs,"selected":$0.selected]}
            report["restoredGroups"]=restored.map {["id":$0.id,"tabs":$0.tabs,"selected":$0.selected]}
            guard baseline.allSatisfy({restored.contains($0)}) else {throw AppError.message("Original native selection was not restored")}
            DispatchQueue.main.sync {self.windows[1].makeKeyAndOrderFront(nil)}
            guard let before=try reader.focusedGroup() else {throw AppError.message("Missing original native bar")}
            DispatchQueue.main.sync {
                let added=self.makeWindow(5);self.windows[1].addTabbedWindow(added,ordered:.above);added.makeKeyAndOrderFront(nil);self.windows.append(added)
            }
            // AppKit can publish its AX tree a run-loop turn after window
            // creation. Wait for the observed condition without repeating it.
            let added:TerminalNativeTabGroup=try TerminalProfileReadiness.wait(message:"New native tab was not recognized") {
                guard let group=try reader.focusedGroup(),group.addingOneTab(to:before) else {return nil}
                return group
            }
            report["beforeAddition"]=["id":before.id,"tabs":before.tabs,"selected":before.selected]
            report["afterAddition"]=["id":added.id,"tabs":added.tabs,"selected":added.selected]
            DispatchQueue.main.sync {self.windows[1].makeKeyAndOrderFront(nil)}
            let _:TerminalNativeTabGroup=try TerminalProfileReadiness.wait(message:"Anchor and new window do not share the exact bar") {
                guard let anchor=try reader.focusedGroup(),anchor.id==added.id,anchor.tabs==added.tabs,anchor.selected != added.selected else {return nil}
                return anchor
            }
            report.merge(["passed":true,"nativeGroups":baseline.count,"scriptingWindowCount":rows.count,"capturedWindowGroups":Set(captured.map(\.windowID)).count,"originalSelectionRestored":true,"newTabVerifiedAcrossWindowIDs":true,"duplicateTitles":true]) {_,new in new}
        } catch {report["passed"]=false;report["error"]=error.localizedDescription}
        let root=URL(fileURLWithPath:Bundle.main.object(forInfoDictionaryKey:"NativeTabsQAOutput") as! String)
        if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:root.appendingPathComponent("result.json"),options:.atomic)}
        let passed=report["passed"] as? Bool == true
        DispatchQueue.main.async {for label in self.labels {label.stringValue += passed ? "\n\n그룹·순서·선택 복원 검사 통과":"\n\n검사 실패 · result.json 확인"}}
    }
}

@main private struct Main {
    @MainActor static func main() {
        let app=NSApplication.shared,delegate=NativeTabsFixture()
        app.delegate=delegate;app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {app.run()}
    }
}
