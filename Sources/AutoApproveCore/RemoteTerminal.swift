import Foundation
import ApplicationServices
import AppKit
import CoreGraphics

public enum TerminalKeyboard {
    public struct PasteboardLease: Sendable {
        public var isCurrent: @Sendable () -> Bool
        public var restore: @Sendable () -> Void
        public init(isCurrent: @escaping @Sendable () -> Bool, restore: @escaping @Sendable () -> Void) {
            self.isCurrent = isCurrent; self.restore = restore
        }
    }
    public static var isAvailable: Bool { AXIsProcessTrusted() }
    @MainActor @discardableResult public static func requestPermission() -> Bool {
        if isAvailable { return true }
        return AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    /// The injectable boundary keeps permission, exact-window preparation and
    /// paired event submission in one process. Tests never post actual events.
    public struct Environment: Sendable {
        public var trusted: @Sendable () -> Bool
        public var postingAllowed: @Sendable () -> Bool
        public var run: @Sendable (String) throws -> String
        public var metadata: @Sendable (String) throws -> TerminalWindowMetadata?
        public var ownerBundle: @Sendable (Int32) -> String?
        public var focused: @Sendable (TerminalWindowMetadata) -> Bool
        public var processes: @Sendable () throws -> [ProcessRecord]
        public var postPair: @Sendable (Int32, CGEvent, CGEvent) throws -> Void
        public var clock: @Sendable () -> TimeInterval
        public var cancelled: @Sendable () -> Bool
        public var preparePasteboard: @Sendable (String) throws -> PasteboardLease
        public var pasteReady: @Sendable (ScreenTarget, String, String) throws -> Bool
        public var frontmost: @Sendable () -> Bool
        public var activate: @Sendable () throws -> Void
        public var pause: @Sendable (TimeInterval) -> Void
        public var prepareLive: (@Sendable (String) throws -> TerminalWindowMetadata?)?
        public init(trusted: @escaping @Sendable () -> Bool, postingAllowed: @escaping @Sendable () -> Bool,
                    run: @escaping @Sendable (String) throws -> String,
                    metadata: @escaping @Sendable (String) throws -> TerminalWindowMetadata?,
                    ownerBundle: @escaping @Sendable (Int32) -> String?, focused: @escaping @Sendable (TerminalWindowMetadata) -> Bool,
                    processes: @escaping @Sendable () throws -> [ProcessRecord],
                    postPair: @escaping @Sendable (Int32, CGEvent, CGEvent) throws -> Void,
                    clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                    cancelled: @escaping @Sendable () -> Bool = { Task<Never, Never>.isCancelled },
                    preparePasteboard: @escaping @Sendable (String) throws -> PasteboardLease = { _ in throw RemoteHTTPError(409,"붙여넣기 연결이 없습니다.") },
                    pasteReady: @escaping @Sendable (ScreenTarget,String,String) throws -> Bool = { _,_,_ in false },
                    frontmost: @escaping @Sendable () -> Bool = { false },
                    activate: @escaping @Sendable () throws -> Void = {},
                    pause: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval:$0) },
                    prepareLive: (@Sendable (String) throws -> TerminalWindowMetadata?)? = nil) {
            self.trusted = trusted; self.postingAllowed = postingAllowed; self.run = run; self.metadata = metadata
            self.ownerBundle = ownerBundle; self.focused = focused; self.processes = processes; self.postPair = postPair
            self.clock = clock; self.cancelled = cancelled
            self.preparePasteboard = preparePasteboard; self.pasteReady = pasteReady
            self.frontmost = frontmost; self.activate = activate; self.pause = pause
            self.prepareLive = prepareLive
        }
        public static var live: Self {
            Self(trusted: { TerminalKeyboard.isAvailable }, postingAllowed: { CGPreflightPostEventAccess() },
                run: { script in try RemoteTerminalPerformance.shared.measure(.inputPreparation) {
                    try AutomationScript.run(script, app: "Terminal", denied: .permissionDenied, timeout: 3)
                } },
                metadata: { tty in try RemoteTerminalPerformance.shared.measure(.inputWindowCheck) {
                    try TerminalAppleEvents.profileWindowMetadata(tty:tty)
                } },
                ownerBundle: { TerminalProcessLookup.ownerBundle(pid:$0) }, focused: { window in
                    RemoteTerminalPerformance.shared.measure(.inputFocusCheck) { TerminalKeyboard.isFocused(window) }
                },
                processes: { try RemoteTerminalPerformance.shared.measure(.inputProcessCheck) { try ProcessDiscovery.read() } }, postPair: { pid, down, up in
                    RemoteTerminalPerformance.shared.measure(.inputEventPost) { down.postToPid(pid); up.postToPid(pid) }
                }, preparePasteboard: { try TerminalKeyboard.preparePasteboard($0) }, pasteReady: { target, text, before in
                    let latest = try TerminalAdapter.screens(ttys:[target.tty],includeCursor:false,includeTitles:false,purpose:.validation)
                    guard let screen = latest.screens.first(where:{$0.tty == target.tty})?.contents,screen != before else { return false }
                    func compact(_ value:String)->String {String(value.precomposedStringWithCanonicalMapping.filter{!$0.isWhitespace})}
                    return compact(screen).contains(compact(text))
                }, frontmost: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Terminal" },
                activate: { try RemoteTerminalPerformance.shared.measure(.inputPreparation) {
                    let owner=try TerminalProcessLookup.running()
                    try TerminalKeyboard.activateApplication(owner:owner)
                } }, prepareLive: {tty in try RemoteTerminalPerformance.shared.measure(.inputPreparation) {
                    try TerminalAppleEvents.prepareLiveInput(tty:tty)
                } })
        }
        public static func live(sourcePID: Int32) throws -> Self {
            let chain = try RemoteTerminalPerformance.shared.measure(.inputProcessCheck) {
                try ProcessDiscovery.readAncestorChain(of:sourcePID)
            }
            guard let owner = chain.lazy.compactMap({ TerminalProcessLookup.identity(pid:$0.pid) }).first else {
                throw RemoteHTTPError(409,"원본 CLI를 실행한 Terminal 프로세스를 확인하지 못했습니다.")
            }
            var value = Self.live
            value.processes = {
                try RemoteTerminalPerformance.shared.measure(.inputProcessCheck) {
                    try ProcessDiscovery.readAncestorChain(of:sourcePID,through:owner.pid)
                }
            }
            value.metadata = { tty in
                try RemoteTerminalPerformance.shared.measure(.inputWindowCheck) {
                    try TerminalAppleEvents.profileWindowMetadata(tty:tty,owner:owner)
                }
            }
            value.activate = {
                try RemoteTerminalPerformance.shared.measure(.inputPreparation) {
                    try TerminalKeyboard.activateApplication(owner:owner)
                }
            }
            value.prepareLive = { tty in
                try RemoteTerminalPerformance.shared.measure(.inputPreparation) {
                    try TerminalAppleEvents.prepareLiveInput(tty:tty,owner:owner)
                }
            }
            return value
        }
    }

    /// Accessibility activation works from the authorized sender even when
    /// ordinary cooperative app activation declines a background request.
    public static func activateApplication(owner:TerminalProcessIdentity,
        identity:(Int32)->TerminalProcessIdentity? = {TerminalProcessLookup.identity(pid:$0)},
        setAttribute:(Int32,String,Bool)->AXError = {pid,name,value in
            let app=AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app,0.3)
            return AXUIElementSetAttributeValue(app,name as CFString,value ? kCFBooleanTrue:kCFBooleanFalse)
        }) throws {
        func checkOwner() throws {
            guard identity(owner.pid)==owner else {throw RemoteHTTPError(409,"원래 Terminal 앱을 확인하지 못했습니다.")}
        }
        for (attribute,value) in [(kAXHiddenAttribute,false),(kAXFrontmostAttribute,true)] {
            try checkOwner()
            let result=setAttribute(owner.pid,attribute,value)
            guard result == .success else {
                throw RemoteHTTPError(409,"손쉬운 사용으로 Terminal 창을 활성화하지 못했습니다 (\(attribute): \(result.rawValue)). Mac 화면을 확인해주세요.")
            }
        }
        try checkOwner()
    }

    private static func preparePasteboard(_ text: String) throws -> PasteboardLease {
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType:type).map{(type,$0)} } }
        board.clearContents()
        let prepared = board.setString(text,forType:.string)
        let revision = board.changeCount
        let lease = PasteboardLease(isCurrent:{NSPasteboard.general.changeCount == revision}, restore:{
            let board = NSPasteboard.general
            guard board.changeCount == revision else { return }
            let items = saved.map { values -> NSPasteboardItem in
                let item=NSPasteboardItem();for (type,data) in values {item.setData(data,forType:type)};return item
            }
            board.clearContents();if !items.isEmpty {board.writeObjects(items)}
        })
        guard prepared else { lease.restore(); throw RemoteHTTPError(409,"붙여넣기 텍스트를 준비하지 못했습니다.") }
        return lease
    }

    private static let deliveryLock = NSLock()
    private static func isFocused(_ metadata: TerminalWindowMetadata) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let first = windows.first(where: {
                  ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == metadata.ownerPID
                    && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
              }) else { return false }
        // CGWindow.h defines this list's order as front to back. Only the
        // prepared owner's exact first window can receive terminal keys.
        guard (first[kCGWindowNumber as String] as? NSNumber)?.uint32Value == metadata.windowID else { return false }
        let app = AXUIElementCreateApplication(metadata.ownerPID)
        AXUIElementSetMessagingTimeout(app, 0.2)
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        guard (attribute(app,kAXFrontmostAttribute) as? NSNumber)?.boolValue==true,
              let focused = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID(),
              attribute(focused as! AXUIElement, kAXRoleAttribute) as? String == kAXTextAreaRole,
              let inputWindow = attribute(focused as! AXUIElement, kAXWindowAttribute), CFGetTypeID(inputWindow) == AXUIElementGetTypeID(),
              let focusedWindow = attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(focusedWindow) == AXUIElementGetTypeID(), CFEqual(inputWindow, focusedWindow) else { return false }
        return true
    }
    private static func source(_ target: ScreenTarget, agent: AgentKind, records: [ProcessRecord]) -> ProcessRecord? {
        guard let pid = target.sourcePID, pid > 0, let started = target.sourceStarted, !started.isEmpty,
              target.jobPIDs.contains(pid), !target.tty.isEmpty else { return nil }
        let tty = target.tty.replacingOccurrences(of: "/dev/", with: "")
        return records.first { $0.pid == pid && $0.started == started && $0.tty == tty && $0.agent == agent && $0.isForeground }
    }
    private static func sameWindow(_ lhs: TerminalWindowMetadata, _ rhs: TerminalWindowMetadata) -> Bool {
        lhs.tty == rhs.tty && lhs.windowID == rhs.windowID && lhs.ownerPID == rhs.ownerPID
            && lhs.ownerBundleID == rhs.ownerBundleID && lhs.bindingToken == rhs.bindingToken
            && rhs.selected && !rhs.minimized
    }
    private static func chunks(_ text: String) -> [[UniChar]] {
        var result = [[UniChar]](), pending = [UniChar]()
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            let units = Array(String(scalar).utf16)
            if pending.count + units.count > 20 { result.append(pending); pending.removeAll(keepingCapacity: true) }
            pending.append(contentsOf: units)
        }
        if !pending.isEmpty { result.append(pending) }
        return result
    }

    public static func deliver(target: ScreenTarget, expected: String, agent: AgentKind, input: RemoteTerminalInput,
                               environment: Environment = .live, timeout: TimeInterval = 8, goalWorkingComparison: Bool = false) throws -> TerminalDelivery {
        try input.validate()
        guard agent != .shell, timeout.isFinite, timeout > 0 else { throw RemoteHTTPError(400, "이 직접 입력 방식은 지원하지 않습니다.") }
        let deadline = environment.clock() + min(timeout, 8)
        guard deliveryLock.lock(before: Date().addingTimeInterval(min(timeout, 8))) else {
            throw RemoteHTTPError(409, "다른 Terminal 입력이 끝나지 않아 입력하지 않았습니다. 화면을 확인해주세요.")
        }
        defer { deliveryLock.unlock() }
        var attemptedPairs = 0
        var pasteboard: PasteboardLease?
        var pasteVerified = false
        defer { if attemptedPairs == 0 || pasteVerified { pasteboard?.restore() } }
        func checkPermissionAndTime() throws {
            if environment.cancelled() { throw CancellationError() }
            guard environment.clock() < deadline else { throw RemoteHTTPError(409, "입력 준비 시간이 지나 입력하지 않았습니다. 원래 터미널을 확인해주세요.") }
            guard environment.trusted(), environment.postingAllowed() else {
                throw RemoteHTTPError(409, "Mac의 손쉬운 사용에서 실행 중인 AutoApprove의 직접 입력 권한을 허용해주세요.")
            }
        }
        do {
            try checkPermissionAndTime()
            let initialRecords = try environment.processes()
            guard let original = source(target, agent: agent, records: initialRecords) else { return .agentMissing }
            let window: TerminalWindowMetadata
            // Live keys already bind the source lifetime, rather than a screen
            // revision. A fresh selected-TTY query and exact focused window can
            // prepare them without launching osascript for every keystroke.
            // Changing focus/selection and revision-bound sends retain JXA.
            if input.isRelay, ![.message,.choice].contains(input.kind), environment.frontmost(),
               let current = try environment.metadata(target.tty), current.tty == target.tty,
               current.windowID > 0, current.ownerPID > 0, current.ownerBundleID == "com.apple.Terminal",
               current.selected, !current.minimized, environment.focused(current) {
                window = current
                RemoteTerminalPerformance.shared.increment(.nativeInputPreparations)
            } else {
                // Wake the existing app before asking its scripting interface
                // for windows. A background read can time out before JXA's
                // later activate command ever runs.
                try environment.activate()
                try checkPermissionAndTime()
                let current:TerminalWindowMetadata
                if input.isRelay, ![.message,.choice].contains(input.kind), let prepare=environment.prepareLive {
                    guard let prepared=try prepare(target.tty),prepared.tty==target.tty,prepared.windowID>0,
                          prepared.ownerPID>0,prepared.ownerBundleID=="com.apple.Terminal",prepared.selected,!prepared.minimized else {return .missingTarget}
                    current=prepared
                    RemoteTerminalPerformance.shared.increment(.nativeInputPreparations)
                } else {
                    let prepared = try environment.run(RemoteTerminalAdapter.script(host: .terminal, target: target, expected: expected, agent: agent, input: input, goalWorkingComparison: goalWorkingComparison))
                    if let failure = TerminalDelivery(rawValue: prepared), failure != .sent { return failure }
                    guard prepared.hasPrefix("ready:"), let windowID = UInt32(prepared.dropFirst(6)), windowID > 0,
                          let metadata = try environment.metadata(target.tty), metadata.tty == target.tty, metadata.windowID == windowID,
                          metadata.ownerPID > 0, metadata.ownerBundleID == "com.apple.Terminal", metadata.selected, !metadata.minimized else { return .missingTarget }
                    current=metadata
                    RemoteTerminalPerformance.shared.increment(.scriptedInputPreparations)
                }
                window=current
                // App activation/tab selection is asynchronous. Wait only for
                // readiness; never retry activation or an input event.
                let focusDeadline=min(deadline,environment.clock()+0.5)
                var ready=false
                for attempt in 0..<26 {
                    try checkPermissionAndTime()
                    if environment.focused(current) {ready=true;break}
                    guard attempt<25,environment.clock()<focusDeadline else {break}
                    environment.pause(max(0,min(0.02,focusDeadline-environment.clock())))
                }
                guard ready else {throw RemoteHTTPError(409,"원래 Terminal 창으로 초점을 옮기지 못해 입력하지 않았습니다. Mac 화면을 확인해주세요.")}
            }
            let preparedRecords = try environment.processes()
            guard source(target, agent: agent, records: preparedRecords) == original,
                  let owner = preparedRecords.first(where: { $0.pid == window.ownerPID }), !owner.started.isEmpty,
                  ProcessDiscovery.ancestors(of: original.pid, records: preparedRecords).contains(where: { $0.pid == owner.pid && $0.started == owner.started }) else { return .agentMissing }
            let keyCodes: [RemoteTerminalInput.Kind: CGKeyCode] = [.enter: 36, .escape: 53, .interrupt: 8, .up: 126, .down: 125,
                .left: 123, .right: 124, .backspace: 51, .delete: 117, .home: 115, .end: 119, .tab: 48]
            var packets: [(key:CGKeyCode,flags:CGEventFlags,text:[UniChar],paste:Bool)] = []
            if input.kind == .characters {
                packets = chunks(input.text).map{(0,[], $0,false)}
            } else if [.text,.submit,.message].contains(input.kind) {
                pasteboard = try environment.preparePasteboard(input.text)
                packets = [(9,.maskCommand,[],true)]
                if input.kind != .text { packets.append((36,[],[],false)) }
            } else if input.kind == .choice {
                if input.text.hasPrefix("digit:") { packets = chunks(String(input.text.dropFirst(6))).map{(0,[],$0,false)} }
                else { let delta=Int(input.text) ?? 0;packets=Array(repeating:(delta < 0 ? 126:125,[],[],false),count:abs(delta));packets.append((36,[],[],false)) }
            } else {
                guard let key=keyCodes[input.kind] else { throw RemoteHTTPError(400,"이 직접 키는 지원하지 않습니다.") }
                packets=[(key,input.kind == .interrupt ? .maskControl:[],[],false)]
            }
            guard let eventSource = CGEventSource(stateID: .privateState) else { throw RemoteHTTPError(409, "입력 이벤트를 준비하지 못했습니다.") }
            for packet in packets {
                guard let down = CGEvent(keyboardEventSource: eventSource, virtualKey: packet.key, keyDown: true),
                      let up = CGEvent(keyboardEventSource: eventSource, virtualKey: packet.key, keyDown: false) else {
                    throw RemoteHTTPError(409, "입력 이벤트를 준비하지 못했습니다.")
                }
                down.flags = packet.flags
                up.flags = []
                if !packet.text.isEmpty {
                    packet.text.withUnsafeBufferPointer { units in
                        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units.baseAddress)
                        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units.baseAddress)
                    }
                }
                let currentWindow = try environment.metadata(target.tty)
                guard let currentWindow, sameWindow(window, currentWindow), environment.focused(currentWindow),
                      environment.ownerBundle(owner.pid) == "com.apple.Terminal" else {
                    throw RemoteHTTPError(409, "원래 CLI나 선택한 Terminal 창이 바뀌어 입력하지 않았습니다. 원래 터미널을 확인해주세요.")
                }
                let currentRecords = try environment.processes()
                guard source(target, agent: agent, records: currentRecords) == original,
                      currentRecords.contains(where: { $0.pid == owner.pid && $0.started == owner.started }),
                      ProcessDiscovery.ancestors(of: original.pid, records: currentRecords).contains(where: { $0.pid == owner.pid && $0.started == owner.started }) else {
                    throw RemoteHTTPError(409, "원래 CLI나 선택한 Terminal 창이 바뀌어 입력하지 않았습니다. 원래 터미널을 확인해주세요.")
                }
                try checkPermissionAndTime()
                if packet.paste, pasteboard?.isCurrent() != true { throw RemoteHTTPError(409,"클립보드가 바뀌어 입력하지 않았습니다.") }
                // Once submission begins, even a throwing callback is an uncertain
                // outcome. Both events already exist and the pair is never retried.
                attemptedPairs += 1
                try environment.postPair(owner.pid, down, up)
                if packet.paste {
                    let until = min(deadline,environment.clock()+2), wall = Date().addingTimeInterval(2)
                    while environment.clock() < until, Date() < wall {
                        try checkPermissionAndTime()
                        guard pasteboard?.isCurrent() == true, let current=try environment.metadata(target.tty),sameWindow(window,current),environment.focused(current) else { break }
                        if try environment.pasteReady(target,input.text,expected) {pasteVerified=true;break}
                        Thread.sleep(forTimeInterval:0.02)
                    }
                    guard pasteVerified else {throw RemoteHTTPError(409,"붙여넣기 결과를 확인하지 못해 Enter를 보내지 않았습니다. 원본 터미널과 클립보드를 확인해주세요.")}
                }
            }
            return .sent
        } catch {
            if attemptedPairs > 0 {
                throw RemoteHTTPError(409, "일부 키가 원래 터미널에 전달되었을 수 있습니다. 전달 결과를 확인하지 못했으므로 다시 보내지 말고 Mac 화면을 확인해주세요.")
            }
            throw error
        }
    }
}

public struct RemoteTerminalInput: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, submit, message, characters, enter, escape, interrupt, up, down, left, right, backspace, delete, home, end, tab, choice }
    public var kind: Kind
    public var text: String
    public var relay: Bool? = nil
    public init(kind: Kind, text: String = "", relay: Bool = false) { self.kind = kind; self.text = text; self.relay = relay ? true : nil }
    public var isRelay: Bool { relay == true && ![.text, .submit].contains(kind) }
    public var bytes: String {
        switch kind {
        case .text, .characters: return text
        case .submit: return text + "\r"
        case .message: return "\u{1b}[200~" + text + "\u{1b}[201~\r"
        case .enter: return "\r"
        case .escape: return "\u{1b}"
        case .interrupt: return "\u{03}"
        case .up: return "\u{1b}[A"
        case .down: return "\u{1b}[B"
        case .left: return "\u{1b}[D"
        case .right: return "\u{1b}[C"
        case .backspace: return "\u{7f}"
        case .delete: return "\u{1b}[3~"
        case .home: return "\u{1b}[H"
        case .end: return "\u{1b}[F"
        case .tab: return "\t"
        case .choice:
            if text.hasPrefix("digit:"), let number = Int(text.dropFirst(6)), (1...9).contains(number) { return String(number) }
            let delta = Int(text).flatMap { (-19...19).contains($0) ? $0 : nil } ?? 0
            return String(repeating: delta < 0 ? "\u{1b}[A" : "\u{1b}[B", count: abs(delta)) + "\r"
        }
    }
    public func validate() throws {
        if kind == .choice {
            if text.hasPrefix("digit:"), let number = Int(text.dropFirst(6)), (1...9).contains(number), text == "digit:\(number)" { return }
            guard let delta = Int(text), (-19...19).contains(delta), String(delta) == text else {
                throw RemoteHTTPError(400, "선택할 항목을 다시 확인해주세요.")
            }
            return
        }
        let textual = [.text, .submit, .message, .characters].contains(kind)
        let limit = kind == .message ? 7_987 : 8_000
        guard !textual || (!text.isEmpty && text.utf8.count <= limit && text.unicodeScalars.allSatisfy({ ($0.value >= 32 && $0.value != 127) || kind != .characters && ($0 == "\n" || $0 == "\t") })),
              textual || text.isEmpty else { throw RemoteHTTPError(400, "텍스트는 제어 문자 없이 \(limit)바이트 이내로 입력해주세요.") }
    }
}

enum RemoteMessageReadiness {
    /// A message must not act as Enter on a CLI's current setup or choice menu.
    /// Historical menus above a newer composer do not block new messages.
    static func hasMenu(_ screen: String, agent: AgentKind) -> Bool {
        if agent == .codex, TerminalChoiceQuestion.hasCodexOverlay(screen) { return true }
        if PromptDetector.detect(screen, agent: agent) != nil || QuestionDetector.detect(screen, agent: agent) != nil { return true }
        let rows = Array(PromptDetector.normalizedLines(screen).suffix(30)).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let option = #"^(?:[›❯»>]\s*)?[1-9][0-9]?\.\s+"#
        guard let last = rows.lastIndex(where: { $0.range(of: option, options: .regularExpression) != nil }),
              rows[...last].filter({ $0.range(of: option, options: .regularExpression) != nil }).count >= 2,
              rows[...last].contains(where: { $0.range(of: #"^[›❯»>]\s*[1-9][0-9]?\.\s+"#, options: .regularExpression) != nil }) else {
            // Claude's initial workspace trust menu has unnumbered choices.
            return agent == .claude && rows.contains("Accessing workspace:") && rows.contains(where: { $0.hasPrefix("❯ No, exit") || $0.hasPrefix("❯ Yes, I trust this folder") }) && rows.contains(where: { $0.contains("Enter to confirm") })
        }
        return rows.dropFirst(last + 1).allSatisfy { row in
            row.allSatisfy { "─━╌- ".contains($0) } || row.range(of: #"(?i)^(?:press |enter\b|esc\b|use (?:the )?arrow|↑|↓)"#, options: .regularExpression) != nil
        }
    }
}

public enum RemoteTerminalAdapter {
    public static func input(host: ScreenHost, target: ScreenTarget, expected: String, agent: AgentKind, input: RemoteTerminalInput) throws -> TerminalDelivery {
        try input.validate()
        if input.kind == .choice, host == .terminal {
            let latest = try TerminalAdapter.screens(ttys: [target.tty], includeCursor: false, includeTitles: false, purpose: .validation)
            guard latest.screens.first(where: { $0.tty == target.tty })?.contents == expected else { return .screenChanged }
        }
        if host == .terminal {
            return try TerminalDeviceInput.deliver(target: target, agent: agent, input: input, screen: expected)
        }
        if host == .orca {
            guard let handle = target.handle else { return .missingTarget }
            if !input.isRelay || input.kind == .choice,
               OrcaAdapter.normalize(try OrcaAdapter.readScreen(handle: handle)) != OrcaAdapter.normalize(expected) { return .screenChanged }
            let result = try OrcaAdapter.sendComposed(handle: handle, text: input.bytes)
            return (result["send"] as? JSONObject)?["accepted"] as? Bool == true ? .sent : .missingTarget
        }
        let result = try AutomationScript.run(script(host: host, target: target, expected: expected, agent: agent, input: input),
            app: host.title, denied: host == .terminal ? .permissionDenied : .automationDenied(host.title))
        guard let delivery = TerminalDelivery(rawValue: result) else { throw AppError.message("입력 전달 결과를 확인하지 못했습니다. 화면을 확인해주세요.") }
        return delivery
    }
    public static func script(host: ScreenHost, target: ScreenTarget, expected: String, agent: AgentKind, input: RemoteTerminalInput, goalWorkingComparison: Bool = false) throws -> String {
        guard agent != .shell, host != .orca else { throw RemoteHTTPError(400, "이 터미널의 입력 방식은 지원하지 않습니다.") }
        try input.validate()
        let data = try AutomationScript.literal(["tty": target.tty, "expected": expected, "agent": agent.rawValue,
            "text": host == .terminal && [.text, .submit].contains(input.kind) ? input.text : input.kind == .enter && host == .terminal ? "" : input.bytes,
            "jobPIDs": target.jobPIDs.map(Int.init), "relay": input.isRelay] as JSONObject)
        var helpers = """
        function normalize(text) { return String(text).normalize('NFC').replace(/\\r\\n?/g, '\\n'); }
        function skipClosed(read) {
          try { return read(); } catch (error) {
            if (Number(error.errorNumber || error.number) === -1743 || String(error).includes('-1743')) throw error;
            return null;
          }
        }
        """
        if goalWorkingComparison {
            guard host == .terminal,agent == .codex,input.kind == .escape,!input.isRelay,CodexGoalScreen.workingReady(expected) else{throw RemoteHTTPError(400,"Goal 중단 비교 대상이 아닙니다.")}
            helpers += #"""

            const normalizeOriginal = normalize;
            normalize = text => normalizeOriginal(text).split('\n').map(line => {
              if (!/esc to interrupt|tab to queue/i.test(line)) return line;
              return line.replace(/^[\u2800-\u28ff\s]+/u,'')
                .replace(/\([^\n]*(?:esc to interrupt|tab to queue)[^\n]*\)/ig,'(busy)')
                .replace(/\b\d+(?:\.\d+)?\s*(?:ms|s|secs?|m|mins?|h|hrs?)\b/g,'time');
            }).join('\n');
            """#
        }
        if host == .terminal {
            let delivery = """
              window.miniaturized = false; window.selectedTab = tab; window.index = 1; app.activate();
              if (window.selectedTab().tty() !== target.tty) return 'missingTarget';
              if (!target.relay && normalize(tab.contents()) !== normalize(target.expected)) return 'screenChanged';
              const windowID = Number(window.id());
              if (!Number.isSafeInteger(windowID) || windowID <= 0 || windowID > 4294967295) return 'missingTarget';
              return 'ready:' + windowID;
            """
            return """
            (() => {
            const app = Application('com.apple.Terminal'); const target = \(data);
            \(helpers)
            if (app.running()) for (const window of app.windows()) for (const tab of skipClosed(() => window.tabs()) || []) {
              if (skipClosed(() => tab.tty()) !== target.tty) continue;
              if (!target.relay && normalize(tab.contents()) !== normalize(target.expected)) return 'screenChanged';
              if (!tab.processes().some(p => p.toLowerCase().includes(target.agent))) return 'agentMissing';
              \(delivery)
              return 'sent';
            }
            return 'missingTarget';
            })();
            """
        }
        return """
        (() => {
        const app = Application('com.googlecode.iterm2'); const target = \(data);
        \(helpers)
        \(ITermAdapter.visibleFunction)
        if (app.running()) for (const window of app.windows()) for (const tab of skipClosed(() => window.tabs()) || [])
        for (const session of skipClosed(() => tab.sessions()) || []) {
          if (skipClosed(() => session.tty()) !== target.tty) continue;
          if (!target.relay && normalize(visible(session)) !== normalize(target.expected)) return 'screenChanged';
          let job = 0;
          try { job = Number(session.variable({named: 'jobPid'})) || 0; } catch (_) {}
          if (!target.jobPIDs.includes(job)) return 'agentMissing';
          session.write({text: String(target.text).normalize('NFC'), newline: false});
          return 'sent';
        }
        return 'missingTarget';
        })();
        """
    }
}
