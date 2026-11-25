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

public final class TerminalNativeTabReader:@unchecked Sendable {
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
    private var originalApplication:NSRunningApplication?
    private let observesForeground:Bool
    private let services:Services
    private let terminalIdentity:TerminalProcessIdentity?
    public init(ownerPID:Int32,bundleID:String,services:Services?=nil) {
        self.ownerPID=ownerPID;self.bundleID=bundleID
        application=AXUIElementCreateApplication(ownerPID)
        self.services=services ?? .live
        terminalIdentity=services==nil && bundleID==TerminalProcessLookup.bundleID ? TerminalProcessLookup.identity(pid:ownerPID):nil
        observesForeground=services == nil
    }
    public static func terminal(owner suppliedOwner:TerminalProcessIdentity? = nil) throws -> TerminalNativeTabReader {
        let owner=try suppliedOwner ?? TerminalProcessLookup.running()
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
    private typealias WindowNumber = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError
    private static let windowNumber: WindowNumber? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow").map {
        unsafeBitCast($0, to: WindowNumber.self)
    }

    private func number(of window: AXUIElement) -> UInt32? {
        var number: UInt32 = 0
        guard Self.windowNumber?(window, &number) == .success, number > 0 else { return nil }
        return number
    }

    struct FrontWindow {
        let element: AXUIElement
        let number: UInt32
    }

    func frontWindow() -> FrontWindow? {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        guard services.foreground(ownerPID), let value = try? attribute(application, kAXFocusedWindowAttribute, deadline: deadline),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = value as! AXUIElement
        return number(of: window).map { FrontWindow(element: window, number: $0) }
    }

    func returnFocus(to previous: FrontWindow?, afterOpening newWindow: UInt32) {
        guard let previous, previous.number != newWindow, number(of: previous.element) == previous.number,
              (try? check()) != nil, frontWindow()?.number == newWindow else { return }
        _ = services.action(previous.element, kAXRaiseAction)
    }

    func tabBar(windowID: UInt32) throws -> TerminalNativeTabGroup? {
        try check()
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        guard let windows = try attribute(application, kAXWindowsAttribute, deadline: deadline) as? [AXUIElement],
              windows.count <= 512, let window = windows.first(where: { number(of: $0) == windowID }) else { return nil }
        return try group(window, deadline: deadline)
    }

    private func barWindow(_ state: TerminalNativeTabGroup, deadline: TimeInterval) throws -> AXUIElement? {
        guard state.id > 0, state.id <= elements.count,
              let value = try attribute(elements[state.id - 1], kAXWindowAttribute, deadline: deadline),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func pressNewTab(in state: TerminalNativeTabGroup, windowID: UInt32, posting: () -> Void) throws {
        try check()
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        guard let window = try barWindow(state, deadline: deadline), number(of: window) == windowID,
              try group(window, deadline: deadline) == state,
              let items = try attribute(elements[state.id - 1], kAXChildrenAttribute, deadline: deadline) as? [AXUIElement] else {
            throw AppError.message("탭을 추가할 Terminal 창이 바뀌었습니다.")
        }
        let buttons = try items.filter { try attribute($0, kAXRoleAttribute, deadline: deadline) as? String == kAXButtonRole }
        guard buttons.count == 1, (try attribute(buttons[0], kAXEnabledAttribute, deadline: deadline) as? NSNumber)?.boolValue == true,
              let current = try barWindow(state, deadline: deadline), number(of: current) == windowID else {
            throw AppError.message("원래 창의 새 탭 버튼을 확인하지 못했습니다.")
        }
        try Task.checkCancellation()
        posting()
        guard services.action(buttons[0], kAXPressAction) == .success else { throw AppError.message("새 탭 버튼의 응답을 확인하지 못했습니다.") }
    }

    func addedWindow(in original: TerminalNativeTabGroup) throws -> UInt32? {
        try check()
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        guard let window = try barWindow(original, deadline: deadline),
              let state = try group(window, deadline: deadline), state.id == original.id,
              state.tabs.count == original.tabs.count + 1,
              let oldIndex = original.tabs.firstIndex(of: original.selected),
              state.tabs.firstIndex(of: state.selected) == oldIndex + 1 else { return nil }
        return number(of: window)
    }

    private func rememberFocus(deadline:TimeInterval) throws {
        originalWindow=nil
        if observesForeground {originalApplication=NSWorkspace.shared.frontmostApplication}
        if let window=try attribute(application,kAXFocusedWindowAttribute,deadline:deadline),CFGetTypeID(window)==AXUIElementGetTypeID() {
            originalWindow=(window as! AXUIElement)
        }
    }

    func currentSelections(_ original:[TerminalNativeTabGroup]) throws -> [TerminalNativeTabGroup] {
        try check()
        let deadline=ProcessInfo.processInfo.systemUptime+3
        try rememberFocus(deadline:deadline)
        var result:[TerminalNativeTabGroup]=[]
        for var state in original {
            let bar=elements[state.id-1]
            guard let value=try attribute(bar,kAXValueAttribute,deadline:deadline), CFGetTypeID(value)==AXUIElementGetTypeID(),
                  let selected=state.tabs.first(where:{CFEqual(elements[$0-1],value)}) else {return try groups()}
            state.selected=selected
            result.append(state)
        }
        return result
    }

    public func groups() throws -> [TerminalNativeTabGroup] {
        try check();let deadline=ProcessInfo.processInfo.systemUptime+3
        try rememberFocus(deadline:deadline)
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
    public func select(_ state:TerminalNativeTabGroup,expected:TerminalNativeTabGroup? = nil) throws {
        try check()
        guard services.foreground(ownerPID) else {throw AppError.message("확인 중 앱 초점이 바뀌었습니다. Terminal의 선택 탭을 확인한 뒤 다시 불러와주세요.")}
        guard state.isValid,state.selected<=elements.count,state.id<=elements.count else {throw AppError.message("원래 선택 탭을 확인하지 못했습니다.")}
        let bar=elements[state.id-1],deadline=ProcessInfo.processInfo.systemUptime+1
        let fresh:TerminalNativeTabGroup
        if let expected {
            guard expected.isValid,expected.id==state.id,expected.tabs==state.tabs,let focused=try focusedGroup(),focused==expected else {
                throw AppError.message("선택한 Terminal 탭이 바뀌어 탭 선택을 중단했습니다.")
            }
            fresh=focused
        } else {
            let window=try attribute(bar,kAXWindowAttribute,deadline:deadline)
            guard let window,CFGetTypeID(window)==AXUIElementGetTypeID(),let current=try group(window as! AXUIElement,deadline:deadline),current.id==state.id,current.tabs==state.tabs else {
                throw AppError.message("탭 구성이 바뀌어 원래 선택 탭을 복원하지 않았습니다.")
            }
            fresh=current
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
    public func restore(_ original:[TerminalNativeTabGroup]) throws {
        try check()
        guard services.foreground(ownerPID) else {throw AppError.message("확인 중 앱 초점이 바뀌었습니다. Terminal의 선택 탭을 확인한 뒤 다시 불러와주세요.")}
        for state in original {try select(state)}
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
        return try capture(rows,original:original) {row in
            let state:TerminalNativeTabGroup?
            do {
                guard try environment.focus(row.tty)==row.windowID else {throw AppError.message("Terminal 창이 바뀌었습니다. 다시 불러와주세요.")}
                state=try environment.focusedGroup()
            }
            catch {try? environment.restore(original);throw error}
            try environment.restore(original)
            return state
        }
    }

    static func capture(_ rows:[TerminalProfileTabSnapshot],original:[TerminalNativeTabGroup],
                        visit:(TerminalProfileTabSnapshot) throws -> TerminalNativeTabGroup?) throws -> [TerminalProfileTabSnapshot] {
        guard original.allSatisfy(\.isValid),Set(original.map(\.id)).count==original.count else {throw AppError.message("Terminal 탭 묶음이 바뀌었습니다. 다시 불러와주세요.")}
        guard !original.isEmpty else {return rows}
        var windows=Set<UInt32>(),states:[String:TerminalNativeTabGroup]=[:]
        let byWindow=Dictionary(grouping:rows,by:\.windowID)
        for row in rows where windows.insert(row.windowID).inserted {
            try Task.checkCancellation()
            if let state=try visit(row) {
                guard state.isValid,let baseline=original.first(where:{$0.id==state.id}),baseline.tabs==state.tabs else {throw AppError.message("Terminal 탭 순서가 바뀌었습니다. 다시 불러와주세요.")}
                for member in byWindow[row.windowID] ?? [] {states[member.tty]=state}
            }
        }
        var result=rows
        let grouped=Dictionary(grouping:rows.filter {states[$0.tty] != nil},by:{states[$0.tty]!.id})
        for (id,members) in grouped {
            guard let baseline=original.first(where:{$0.id==id}),let representative=members.min(by:{$0.windowOrder<$1.windowOrder}) else {continue}
            let bounds=members.first(where: {states[$0.tty]?.selected==baseline.selected && $0.bounds != nil})?.bounds ?? members.compactMap(\.bounds).first
            let ordered=members.sorted {a,b in
                let left=states[a.tty]!,right=states[b.tty]!
                return (baseline.tabs.firstIndex(of:left.selected)!,a.tabOrder)<(baseline.tabs.firstIndex(of:right.selected)!,b.tabOrder)
            }
            for (order,row) in ordered.enumerated() {
                guard let index=result.firstIndex(where:{$0.tty==row.tty}) else {continue}
                result[index].bounds=bounds
                result[index].windowID=representative.windowID;result[index].windowOrder=representative.windowOrder
                result[index].tabOrder=order;result[index].selected=row.selected && states[row.tty]!.selected==baseline.selected
            }
        }
        return result
    }
}
