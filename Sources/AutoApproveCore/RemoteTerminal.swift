import Foundation
import ApplicationServices
import AppKit
import CoreGraphics

public enum TerminalKeyboard {
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
        public init(trusted: @escaping @Sendable () -> Bool, postingAllowed: @escaping @Sendable () -> Bool,
                    run: @escaping @Sendable (String) throws -> String,
                    metadata: @escaping @Sendable (String) throws -> TerminalWindowMetadata?,
                    ownerBundle: @escaping @Sendable (Int32) -> String?, focused: @escaping @Sendable (TerminalWindowMetadata) -> Bool,
                    processes: @escaping @Sendable () throws -> [ProcessRecord],
                    postPair: @escaping @Sendable (Int32, CGEvent, CGEvent) throws -> Void,
                    clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                    cancelled: @escaping @Sendable () -> Bool = { Task<Never, Never>.isCancelled }) {
            self.trusted = trusted; self.postingAllowed = postingAllowed; self.run = run; self.metadata = metadata
            self.ownerBundle = ownerBundle; self.focused = focused; self.processes = processes; self.postPair = postPair
            self.clock = clock; self.cancelled = cancelled
        }
        public static var live: Self {
            Self(trusted: { TerminalKeyboard.isAvailable }, postingAllowed: { CGPreflightPostEventAccess() },
                run: { try AutomationScript.run($0, app: "Terminal", denied: .permissionDenied, timeout: 3) },
                metadata: { try TerminalAdapter.windowMetadata(tty: $0) },
                ownerBundle: { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }, focused: { TerminalKeyboard.isFocused($0) },
                processes: { try ProcessDiscovery.read() }, postPair: { pid, down, up in
                    down.postToPid(pid); up.postToPid(pid)
                })
        }
    }

    private static let deliveryLock = NSLock()
    static func needsNative(_ input: RemoteTerminalInput) -> Bool {
        ![.text, .submit, .enter].contains(input.kind) || input.kind == .enter && input.isRelay
    }
    private static func isFocused(_ metadata: TerminalWindowMetadata) -> Bool {
        guard NSRunningApplication(processIdentifier: metadata.ownerPID)?.isActive == true,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
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
        guard let focused = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID(),
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
                               environment: Environment = .live, timeout: TimeInterval = 8) throws -> TerminalDelivery {
        try input.validate()
        guard agent != .shell, needsNative(input), timeout.isFinite, timeout > 0 else { throw RemoteHTTPError(400, "이 직접 입력 방식은 지원하지 않습니다.") }
        let deadline = environment.clock() + min(timeout, 8)
        guard deliveryLock.lock(before: Date().addingTimeInterval(min(timeout, 8))) else {
            throw RemoteHTTPError(409, "다른 Terminal 입력이 끝나지 않아 입력하지 않았습니다. 화면을 확인해주세요.")
        }
        defer { deliveryLock.unlock() }
        var attemptedPairs = 0
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
            let prepared = try environment.run(RemoteTerminalAdapter.script(host: .terminal, target: target, expected: expected, agent: agent, input: input))
            if let failure = TerminalDelivery(rawValue: prepared), failure != .sent { return failure }
            guard prepared.hasPrefix("ready:"), let windowID = UInt32(prepared.dropFirst(6)), windowID > 0,
                  let window = try environment.metadata(target.tty), window.tty == target.tty, window.windowID == windowID,
                  window.ownerPID > 0, window.ownerBundleID == "com.apple.Terminal", window.selected, !window.minimized else { return .missingTarget }
            let preparedRecords = try environment.processes()
            guard source(target, agent: agent, records: preparedRecords) == original,
                  let owner = preparedRecords.first(where: { $0.pid == window.ownerPID }), !owner.started.isEmpty,
                  ProcessDiscovery.ancestors(of: original.pid, records: preparedRecords).contains(where: { $0.pid == owner.pid && $0.started == owner.started }) else { return .agentMissing }
            let keyCodes: [RemoteTerminalInput.Kind: CGKeyCode] = [.enter: 36, .escape: 53, .interrupt: 8, .up: 126, .down: 125,
                .left: 123, .right: 124, .backspace: 51, .delete: 117, .home: 115, .end: 119, .tab: 48]
            let packets: [[UniChar]]
            if input.kind == .characters { packets = chunks(input.text) }
            else { guard keyCodes[input.kind] != nil else { throw RemoteHTTPError(400, "이 직접 키는 지원하지 않습니다.") }; packets = [[]] }
            guard let eventSource = CGEventSource(stateID: .privateState) else { throw RemoteHTTPError(409, "입력 이벤트를 준비하지 못했습니다.") }
            for packet in packets {
                guard let down = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCodes[input.kind] ?? 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCodes[input.kind] ?? 0, keyDown: false) else {
                    throw RemoteHTTPError(409, "입력 이벤트를 준비하지 못했습니다.")
                }
                down.flags = input.kind == .interrupt ? .maskControl : []
                up.flags = []
                if !packet.isEmpty {
                    packet.withUnsafeBufferPointer { units in
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
                // Once submission begins, even a throwing callback is an uncertain
                // outcome. Both events already exist and the pair is never retried.
                attemptedPairs += 1
                try environment.postPair(owner.pid, down, up)
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
    public enum Kind: String, Codable, Sendable { case text, submit, characters, enter, escape, interrupt, up, down, left, right, backspace, delete, home, end, tab }
    public var kind: Kind
    public var text: String
    public var relay: Bool? = nil
    public init(kind: Kind, text: String = "", relay: Bool = false) { self.kind = kind; self.text = text; self.relay = relay ? true : nil }
    public var isRelay: Bool { relay == true && ![.text, .submit].contains(kind) }
    public var bytes: String {
        switch kind {
        case .text, .characters: return text
        case .submit: return text + "\r"
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
        }
    }
    public func validate() throws {
        let textual = [.text, .submit, .characters].contains(kind)
        guard !textual || (!text.isEmpty && text.utf8.count <= 8_000 && text.unicodeScalars.allSatisfy({ ($0.value >= 32 && $0.value != 127) || kind != .characters && ($0 == "\n" || $0 == "\t") })),
              textual || text.isEmpty else { throw RemoteHTTPError(400, "텍스트는 제어 문자 없이 8,000바이트 이내로 입력해주세요.") }
    }
}

public enum RemoteTerminalAdapter {
    public static func input(host: ScreenHost, target: ScreenTarget, expected: String, agent: AgentKind, input: RemoteTerminalInput) throws -> TerminalDelivery {
        try input.validate()
        if host == .terminal, input.isRelay || ![.text, .submit, .enter].contains(input.kind) {
            return try TerminalDeviceInput.deliver(target: target, agent: agent, input: input)
        }
        if host == .orca {
            guard let handle = target.handle else { return .missingTarget }
            if !input.isRelay, OrcaAdapter.normalize(try OrcaAdapter.readScreen(handle: handle)) != OrcaAdapter.normalize(expected) { return .screenChanged }
            let result = try OrcaAdapter.sendComposed(handle: handle, text: input.bytes)
            return (result["send"] as? JSONObject)?["accepted"] as? Bool == true ? .sent : .missingTarget
        }
        let result = try AutomationScript.run(script(host: host, target: target, expected: expected, agent: agent, input: input),
            app: host.title, denied: host == .terminal ? .permissionDenied : .automationDenied(host.title))
        guard let delivery = TerminalDelivery(rawValue: result) else { throw AppError.message("입력 전달 결과를 확인하지 못했습니다. 화면을 확인해주세요.") }
        return delivery
    }
    public static func script(host: ScreenHost, target: ScreenTarget, expected: String, agent: AgentKind, input: RemoteTerminalInput) throws -> String {
        guard agent != .shell, host != .orca else { throw RemoteHTTPError(400, "이 터미널의 입력 방식은 지원하지 않습니다.") }
        try input.validate()
        let terminalKeyboard = host == .terminal && TerminalKeyboard.needsNative(input)
        let data = try AutomationScript.literal(["tty": target.tty, "expected": expected, "agent": agent.rawValue,
            "text": host == .terminal && [.text, .submit].contains(input.kind) ? input.text : input.kind == .enter && host == .terminal ? "" : input.bytes,
            "jobPIDs": target.jobPIDs.map(Int.init), "relay": input.isRelay] as JSONObject)
        let helpers = """
        function normalize(text) { return String(text).normalize('NFC').replace(/\\r\\n?/g, '\\n'); }
        function skipClosed(read) {
          try { return read(); } catch (error) {
            if (Number(error.errorNumber || error.number) === -1743 || String(error).includes('-1743')) throw error;
            return null;
          }
        }
        """
        if host == .terminal {
            let delivery = terminalKeyboard ? """
              window.miniaturized = false; window.selectedTab = tab; window.index = 1; app.activate();
              if (!app.frontmost() || window.selectedTab().tty() !== target.tty) return 'missingTarget';
              if (!target.relay && normalize(tab.contents()) !== normalize(target.expected)) return 'screenChanged';
              const windowID = Number(window.id());
              if (!Number.isSafeInteger(windowID) || windowID <= 0 || windowID > 4294967295) return 'missingTarget';
              return 'ready:' + windowID;
            """ : "app.doScript(String(target.text).normalize('NFC'), {in:tab});"
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
