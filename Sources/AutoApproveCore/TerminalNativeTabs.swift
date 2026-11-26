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
    private let services:Services
    private let terminalIdentity:TerminalProcessIdentity?
    public init(ownerPID:Int32,bundleID:String,services:Services?=nil) {
        self.ownerPID=ownerPID;self.bundleID=bundleID
        application=AXUIElementCreateApplication(ownerPID)
        self.services=services ?? .live
        terminalIdentity=services==nil && bundleID==TerminalProcessLookup.bundleID ? TerminalProcessLookup.identity(pid:ownerPID):nil
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

    struct LayoutWindows {
        var standalone = Set<UInt32>()
        var groups: [UInt32: TerminalNativeTabGroup] = [:]

        func sameTabs(as other: Self) -> Bool {
            standalone == other.standalone && groups == other.groups
        }
    }

    func layoutWindows() throws -> LayoutWindows {
        try check()
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        guard let windows = try attribute(application, kAXWindowsAttribute, deadline: deadline) as? [AXUIElement], windows.count <= 512 else {
            throw AppError.message("Terminal 창 목록을 확인하지 못했습니다.")
        }
        var result = LayoutWindows()
        for window in windows {
            guard let id = number(of: window), result.groups[id] == nil, !result.standalone.contains(id) else {
                throw AppError.message("Terminal 창 식별자를 확인하지 못했습니다.")
            }
            if let tabs = try group(window, deadline: deadline) { result.groups[id] = tabs }
            else { result.standalone.insert(id) }
        }
        return result
    }

    public func capture(_ rows: [TerminalProfileTabSnapshot]) throws -> [TerminalProfileTabSnapshot] {
        let layout = try layoutWindows()
        guard rows.allSatisfy({ layout.standalone.contains($0.windowID) }) || !layout.groups.isEmpty else {
            throw AppError.message("Terminal의 현재 창과 탭을 확인하지 못했습니다. 배치를 다시 읽어주세요.")
        }
        let hasHidden = rows.contains { layout.groups[$0.windowID] == nil && !layout.standalone.contains($0.windowID) }
        let captured = try TerminalProfileNativeCapture.capture(rows,visible:layout.groups,standalone:layout.standalone,
            labels:hasHidden ? try tabLabels(in:layout) : [:])
        guard layout.sameTabs(as:try layoutWindows()) else {
            throw AppError.message("읽는 동안 Terminal 창·탭 배치가 바뀌었습니다. 배치를 다시 읽어주세요.")
        }
        return captured
    }

    func tabLabels(in layout: LayoutWindows) throws -> [Int: String] {
        try check()
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var labels: [Int: String] = [:]
        for group in layout.groups.values {
            for token in group.tabs where labels[token] == nil {
                if let label = try attribute(elements[token - 1], kAXTitleAttribute, deadline: deadline) as? String,
                   !label.isEmpty { labels[token] = label }
            }
        }
        return labels
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
        guard !services.foreground(ownerPID) else {
            throw AppError.message("Terminal에서 작업 중입니다. 다른 앱으로 이동한 뒤 이 탭의 복원을 다시 시도해주세요.")
        }
        posting()
        guard services.action(buttons[0], kAXPressAction) == .success else { throw AppError.message("새 탭 버튼의 응답을 확인하지 못했습니다.") }
    }

    func addedWindow(in original: TerminalNativeTabGroup) throws -> UInt32? {
        try check()
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        guard let window = try barWindow(original, deadline: deadline),
              let state = try group(window, deadline: deadline), state.id == original.id,
              state.addingOneTab(to: original),
              let oldIndex = original.tabs.firstIndex(of: original.selected),
              state.tabs.firstIndex(of: state.selected) == oldIndex + 1 else { return nil }
        return number(of: window)
    }

    public func groups() throws -> [TerminalNativeTabGroup] {
        try check();let deadline=ProcessInfo.processInfo.systemUptime+3
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

    func selectRestoredTab(row: TerminalProfileTabSnapshot, afterOpening windowID: UInt32) throws {
        guard !services.foreground(ownerPID), let group = try tabBar(windowID: windowID) else {return}
        let labels = try tabLabels(in: LayoutWindows(groups: [windowID: group]))
        guard let target = TerminalProfileTabTitles(labels).match(row), target != group.selected,
              try tabBar(windowID: windowID) == group, !services.foreground(ownerPID) else {return}
        guard services.action(elements[target - 1], kAXPressAction) == .success else {
            throw AppError.message("복원한 창의 선택 탭을 확인하지 못했습니다.")
        }
    }

}

struct TerminalProfileTabTitles {
    private var tokens: [String: Set<Int>] = [:]

    static func stable(_ value: String) -> String {
        value.replacingOccurrences(of: #"^[\u2800-\u28ff]+\s*"#, with: "", options: .regularExpression)
    }

    static func identity(_ title: String, window: Bool) -> String {
        var parts = title.components(separatedBy: " — ")
        if window, parts.count > 1,
           parts.last?.range(of: #"^[0-9]+\s*[×x]\s*[0-9]+$"#, options: .regularExpression) != nil { parts.removeLast() }
        if parts.count > 1 { parts.removeFirst() }
        return parts.map(stable).joined(separator: " — ")
    }

    init(_ labels: [Int: String]) {
        for (token,label) in labels {
            for key in [Self.stable(label),Self.identity(label,window:false)] where !key.isEmpty {
                tokens[key,default:[]].insert(token)
            }
        }
    }

    func match(_ row: TerminalProfileTabSnapshot) -> Int? {
        let matches = Set([row.windowTitle,row.tabLabel].compactMap { key -> Int? in
            guard let key, let values=tokens[key], values.count==1 else {return nil}
            return values.first
        })
        return matches.count==1 ? matches.first:nil
    }
}

public enum TerminalProfileNativeCapture {
    public static func capture(_ rows: [TerminalProfileTabSnapshot], visible: [UInt32: TerminalNativeTabGroup],
                               standalone: Set<UInt32>, labels: [Int: String]) throws -> [TerminalProfileTabSnapshot] {
        let titles = TerminalProfileTabTitles(labels)
        let selected = Set(visible.values.map(\.selected))
        return try capture(rows, original: Array(visible.values)) { row in
            if let group = visible[row.windowID] { return group }
            if standalone.contains(row.windowID) { return nil }
            guard let token = titles.match(row), !selected.contains(token),
                  var group = visible.values.first(where: { $0.tabs.contains(token) }) else {
                throw AppError.message("숨겨진 Terminal 탭의 위치를 확인할 수 없습니다. 탭에 서로 다른 제목을 지정한 뒤 배치를 다시 읽어주세요.")
            }
            group.selected = token
            return group
        }
    }

    static func capture(_ rows:[TerminalProfileTabSnapshot],original:[TerminalNativeTabGroup],
                        visit:(TerminalProfileTabSnapshot) throws -> TerminalNativeTabGroup?) throws -> [TerminalProfileTabSnapshot] {
        guard original.allSatisfy(\.isValid),Set(original.map(\.id)).count==original.count else {throw AppError.message("Terminal 탭 묶음이 바뀌었습니다. 다시 불러와주세요.")}
        guard !original.isEmpty else {return rows}
        var windows=Set<UInt32>(),selections=Set<Int>(),states:[String:TerminalNativeTabGroup]=[:]
        let byWindow=Dictionary(grouping:rows,by:\.windowID)
        for row in rows where windows.insert(row.windowID).inserted {
            try Task.checkCancellation()
            if let state=try visit(row) {
                guard state.isValid,selections.insert(state.selected).inserted,let baseline=original.first(where:{$0.id==state.id}),baseline.tabs==state.tabs else {throw AppError.message("Terminal 탭 순서가 바뀌었습니다. 다시 불러와주세요.")}
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
