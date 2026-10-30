import Foundation
import AppKit
import ApplicationServices

public enum TerminalProfileAccessError:LocalizedError,Equatable {
    case terminalNotRunning,accessibilityDenied
    public var errorDescription:String? {
        switch self {
        case .terminalNotRunning:return "Terminal이 실행 중이 아닙니다. Terminal을 연 뒤 현재 창을 다시 불러와주세요."
        case .accessibilityDenied:return "macOS가 실행 중인 AutoApprove의 손쉬운 사용 접근을 거부했습니다. 설정에서 이미 허용했다면 AutoApprove를 완전히 종료한 뒤 다시 열어주세요."
        }
    }
}

/// Wait for the result of an action that was submitted once. Reads can settle
/// on a later AppKit/AX turn; actions and resume commands are never retried.
public enum TerminalProfileReadiness {
    @discardableResult public static func wait<Value>(timeout:TimeInterval = 1.5,message:String,
        clock:() -> TimeInterval = {ProcessInfo.processInfo.systemUptime},
        pause:(TimeInterval) -> Void = {Thread.sleep(forTimeInterval:$0)},
        read:() throws -> Value?) throws -> Value {
        let deadline=clock()+timeout
        while true {
            try Task.checkCancellation()
            if let value=try read() {return value}
            let remaining=deadline-clock()
            guard remaining>0 else {throw AppError.message(message)}
            pause(min(0.02,remaining))
        }
    }
}

/// Operation-local accessibility identities. Never written to a saved profile.
public struct TerminalNativeTabGroup:Equatable,Sendable {
    public var id:Int
    public var tabs:[Int]
    public var selected:Int
    public init(id:Int,tabs:[Int],selected:Int) {self.id=id;self.tabs=tabs;self.selected=selected}
    public var isValid:Bool {id>0 && !tabs.isEmpty && tabs.count<=4096 && Set(tabs).count==tabs.count && tabs.allSatisfy {$0>0} && tabs.contains(selected)}
    public func addingOneTab(to previous:Self)->Bool {
        id==previous.id && tabs.count==previous.tabs.count+1 && tabs.filter {previous.tabs.contains($0)}==previous.tabs && !previous.tabs.contains(selected)
    }
}

/// AppKit moves the same native tab bar between its individual NSWindows.
/// Compare AX elements, never tab titles, window bounds or scripting IDs.
public final class TerminalNativeTabReader:@unchecked Sendable {
    /// Actual AX replies are authoritative. A cached trust preflight must not
    /// prevent an already permitted process from even trying a read.
    public struct Services {
        public var ownsProcess:(Int32,String)->Bool
        public var read:(AXUIElement,String)->(AXError,CFTypeRef?)
        public var action:(AXUIElement,String)->AXError
        public var foreground:(Int32)->Bool
        public init(ownsProcess:@escaping (Int32,String)->Bool,read:@escaping (AXUIElement,String)->(AXError,CFTypeRef?),
                    action:@escaping (AXUIElement,String)->AXError,foreground:@escaping (Int32)->Bool) {
            self.ownsProcess=ownsProcess;self.read=read;self.action=action;self.foreground=foreground
        }
        public static var live:Self {
            .init(ownsProcess:{pid,bundle in
                TerminalProcessLookup.ownerBundle(pid:pid)==bundle
            },read:{element,name in
                var value:CFTypeRef?;let result=AXUIElementCopyAttributeValue(element,name as CFString,&value);return (result,value)
            },action:{AXUIElementPerformAction($0,$1 as CFString)},foreground:{pid in
                let app=AXUIElementCreateApplication(pid);AXUIElementSetMessagingTimeout(app,0.15)
                var value:CFTypeRef?
                return AXUIElementCopyAttributeValue(app,kAXFrontmostAttribute as CFString,&value) == .success && (value as? NSNumber)?.boolValue==true
            })
        }
    }
    private let application:AXUIElement
    private let ownerPID:Int32
    private let bundleID:String
    private var elements:[AXUIElement]=[]
    private var originalWindow:AXUIElement?
    private let originalApplication:NSRunningApplication?
    private let services:Services
    private let terminalIdentity:TerminalProcessIdentity?
    public init(ownerPID:Int32,bundleID:String,services:Services?=nil) {
        self.ownerPID=ownerPID;self.bundleID=bundleID
        application=AXUIElementCreateApplication(ownerPID)
        self.services=services ?? .live
        terminalIdentity=services==nil && bundleID==TerminalProcessLookup.bundleID ? TerminalProcessLookup.identity(pid:ownerPID):nil
        // Injected adapters cannot acquire a path to real focus-changing UI.
        originalApplication=services == nil ? NSWorkspace.shared.frontmostApplication:nil
    }
    public static func terminal() throws -> TerminalNativeTabReader {
        let owner=try TerminalProcessLookup.running()
        let reader=TerminalNativeTabReader(ownerPID:owner.pid,bundleID:TerminalProcessLookup.bundleID)
        guard reader.terminalIdentity==owner else {throw AppError.message("탭 구성을 읽기 전에 Terminal 프로세스가 바뀌었습니다. 다시 불러와주세요.")}
        return reader
    }
    private func check() throws {
        if let terminalIdentity,TerminalProcessLookup.identity(pid:ownerPID) != terminalIdentity {
            throw AppError.message("탭 구성을 읽는 동안 원래 Terminal 프로세스가 바뀌었습니다.")
        }
        guard services.ownsProcess(ownerPID,bundleID) else {
            throw AppError.message("탭 구성을 읽는 동안 원래 Terminal 프로세스가 바뀌었습니다.")
        }
    }
    private func attribute(_ element:AXUIElement,_ name:String,deadline:TimeInterval) throws -> CFTypeRef? {
        guard ProcessInfo.processInfo.systemUptime<deadline else {throw AppError.message("Terminal 탭 구성 확인 시간이 초과됐습니다. 다시 불러와주세요.")}
        AXUIElementSetMessagingTimeout(element,0.15)
        let (error,value)=services.read(element,name)
        if error == .apiDisabled {throw TerminalProfileAccessError.accessibilityDenied}
        if error == .attributeUnsupported || error == .noValue {return nil}
        guard error == .success else {throw AppError.message("Terminal 탭 구성을 읽지 못했습니다. 창을 확인한 뒤 다시 불러와주세요.")}
        return value
    }
    private func token(_ element:AXUIElement) throws -> Int {
        if let index=elements.firstIndex(where:{CFEqual($0,element)}) {return index+1}
        guard elements.count<16384 else {throw AppError.message("확인할 Terminal 탭이 너무 많습니다.")}
        elements.append(element);return elements.count
    }
    private func group(_ window:AXUIElement,deadline:TimeInterval) throws -> TerminalNativeTabGroup? {
        // The native tab bar is a direct window child. Never descend into a
        // terminal text area, scrollback or an application-rendered TUI.
        let children=try attribute(window,kAXChildrenAttribute,deadline:deadline) as? [AXUIElement] ?? []
        guard children.count<=256 else {throw AppError.message("Terminal 창의 탭 표시를 확인하지 못했습니다.")}
        var groups:[TerminalNativeTabGroup]=[]
        for child in children {
            let role=try attribute(child,kAXRoleAttribute,deadline:deadline) as? String
            guard role==kAXTabGroupRole else {continue}
            var tabs=try attribute(child,kAXTabsAttribute,deadline:deadline) as? [AXUIElement] ?? []
            if tabs.isEmpty {
                let items=try attribute(child,kAXChildrenAttribute,deadline:deadline) as? [AXUIElement] ?? []
                for item in items where try attribute(item,kAXRoleAttribute,deadline:deadline) as? String == kAXRadioButtonRole {tabs.append(item)}
            }
            guard !tabs.isEmpty,tabs.count<=4096 else {throw AppError.message("Terminal 탭의 순서를 확인하지 못했습니다.")}
            let value=try attribute(child,kAXValueAttribute,deadline:deadline)
            var selected:[AXUIElement]=[]
            if let value,CFGetTypeID(value)==AXUIElementGetTypeID(),let tab=tabs.first(where:{CFEqual($0,value)}) {selected=[tab]}
            else {
                for tab in tabs where (try attribute(tab,kAXValueAttribute,deadline:deadline) as? NSNumber)?.boolValue == true {selected.append(tab)}
            }
            guard selected.count==1 else {throw AppError.message("Terminal의 선택 탭을 확인하지 못했습니다.")}
            let state=try TerminalNativeTabGroup(id:token(child),tabs:tabs.map {try token($0)},selected:token(selected[0]))
            guard state.isValid else {throw AppError.message("Terminal 탭 구성이 바뀌었습니다. 다시 불러와주세요.")}
            groups.append(state)
        }
        guard groups.count<=1 else {throw AppError.message("Terminal의 탭 묶음을 구분하지 못했습니다.")}
        return groups.first
    }
    public func groups() throws -> [TerminalNativeTabGroup] {
        try check();let deadline=ProcessInfo.processInfo.systemUptime+3
        if let window=try attribute(application,kAXFocusedWindowAttribute,deadline:deadline),CFGetTypeID(window)==AXUIElementGetTypeID() {originalWindow=(window as! AXUIElement)}
        guard let windows=try attribute(application,kAXWindowsAttribute,deadline:deadline) as? [AXUIElement] else {throw AppError.message("Terminal의 접근성 창 목록을 확인하지 못했습니다. 현재 창을 다시 불러와주세요.")}
        guard windows.count<=512 else {throw AppError.message("확인할 Terminal 창이 너무 많습니다.")}
        var result:[TerminalNativeTabGroup]=[]
        for window in windows {
            if let state=try group(window,deadline:deadline),!result.contains(where:{$0.id==state.id}) {result.append(state)}
        }
        return result
    }
    public func focusedGroup() throws -> TerminalNativeTabGroup? {
        try check();let deadline=ProcessInfo.processInfo.systemUptime+1
        guard let window=try attribute(application,kAXFocusedWindowAttribute,deadline:deadline),CFGetTypeID(window)==AXUIElementGetTypeID() else {throw AppError.message("선택한 Terminal 창을 확인하지 못했습니다.")}
        return try group(window as! AXUIElement,deadline:deadline)
    }
    public func restore(_ original:[TerminalNativeTabGroup]) throws {
        try check()
        // Re-read the exact native group before acting. Every AX read/action
        // is permission-checked by macOS; do not gate on cached AX trust here.
        guard services.foreground(ownerPID) else {throw AppError.message("확인 중 앱 초점이 바뀌었습니다. Terminal의 선택 탭을 확인한 뒤 다시 불러와주세요.")}
        for state in original {
            guard state.isValid,state.selected<=elements.count,state.id<=elements.count else {throw AppError.message("원래 선택 탭을 확인하지 못했습니다.")}
            let bar=elements[state.id-1],deadline=ProcessInfo.processInfo.systemUptime+1
            let window=try attribute(bar,kAXWindowAttribute,deadline:deadline)
            guard let window,CFGetTypeID(window)==AXUIElementGetTypeID(),let fresh=try group(window as! AXUIElement,deadline:deadline),fresh.id==state.id,fresh.tabs==state.tabs else {
                throw AppError.message("탭 구성이 바뀌어 원래 선택 탭을 복원하지 않았습니다.")
            }
            if fresh.selected != state.selected {
                let target=elements[state.selected-1];AXUIElementSetMessagingTimeout(target,0.5)
                let result=services.action(target,kAXPressAction)
                if result == .apiDisabled {throw TerminalProfileAccessError.accessibilityDenied}
                guard result == .success else {throw AppError.message("원래 선택 탭으로 돌아가지 못했습니다.")}
            }
            try TerminalProfileReadiness.wait(message:"원래 선택 탭 복원을 확인하지 못했습니다.") {
                try self.check()
                guard self.services.foreground(self.ownerPID) else {throw AppError.message("선택 탭 복원 중 앱 초점이 바뀌었습니다.")}
                let limit=ProcessInfo.processInfo.systemUptime+1
                guard let window=try self.attribute(bar,kAXWindowAttribute,deadline:limit),CFGetTypeID(window)==AXUIElementGetTypeID(),
                      let restored=try self.group(window as! AXUIElement,deadline:limit),restored.id==state.id,restored.tabs==state.tabs else {
                    throw AppError.message("탭 구성이 바뀌어 원래 선택 탭 복원을 확인하지 못했습니다.")
                }
                return restored==state ? true:nil
            }
        }
        if let originalWindow {_ = services.action(originalWindow,kAXRaiseAction)}
        if let originalApplication,!originalApplication.isTerminated,originalApplication.processIdentifier != ownerPID {originalApplication.activate()}
    }
}

public enum TerminalProfileNativeCapture {
    public struct Environment {
        public var groups:() throws -> [TerminalNativeTabGroup]
        public var focus:(String) throws -> UInt32
        public var focusedGroup:() throws -> TerminalNativeTabGroup?
        public var restore:([TerminalNativeTabGroup]) throws -> Void
        public init(groups:@escaping () throws -> [TerminalNativeTabGroup],focus:@escaping (String) throws -> UInt32,
                    focusedGroup:@escaping () throws -> TerminalNativeTabGroup?,restore:@escaping ([TerminalNativeTabGroup]) throws -> Void) {
            self.groups=groups;self.focus=focus;self.focusedGroup=focusedGroup;self.restore=restore
        }
    }
    public static func capture(_ rows:[TerminalProfileTabSnapshot],environment:Environment) throws -> [TerminalProfileTabSnapshot] {
        let original=try environment.groups()
        guard original.allSatisfy(\.isValid),Set(original.map(\.id)).count==original.count else {throw AppError.message("Terminal 탭 묶음이 바뀌었습니다. 다시 불러와주세요.")}
        guard !original.isEmpty else {return rows}
        var states:[String:TerminalNativeTabGroup]=[:]
        do {
            for row in rows {
                try Task.checkCancellation()
                guard try environment.focus(row.tty)==row.windowID else {throw AppError.message("Terminal 창이 바뀌었습니다. 다시 불러와주세요.")}
                if let state=try environment.focusedGroup() {
                    guard state.isValid,let baseline=original.first(where:{$0.id==state.id}),baseline.tabs==state.tabs else {throw AppError.message("Terminal 탭 순서가 바뀌었습니다. 다시 불러와주세요.")}
                    states[row.tty]=state
                }
            }
        } catch {try? environment.restore(original);throw error}
        try environment.restore(original)
        var result=rows
        // Preserve unrelated independent windows and flatten any legacy tabs
        // within the native group in their original order.
        let grouped=Dictionary(grouping:rows.filter {states[$0.tty] != nil},by:{states[$0.tty]!.id})
        for (id,members) in grouped {
            guard let baseline=original.first(where:{$0.id==id}),let representative=members.min(by:{$0.windowOrder<$1.windowOrder}) else {continue}
            let ordered=members.sorted {a,b in
                let left=states[a.tty]!,right=states[b.tty]!
                return (baseline.tabs.firstIndex(of:left.selected)!,a.tabOrder)<(baseline.tabs.firstIndex(of:right.selected)!,b.tabOrder)
            }
            for (order,row) in ordered.enumerated() {
                guard let index=result.firstIndex(where:{$0.tty==row.tty}) else {continue}
                result[index].windowID=representative.windowID;result[index].windowOrder=representative.windowOrder
                result[index].tabOrder=order;result[index].selected=row.selected && states[row.tty]!.selected==baseline.selected
            }
        }
        return result
    }
}
