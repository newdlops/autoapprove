import Foundation

/// Official Codex presents inactive-thread approvals in the current widget.
/// Enter their owner before answering; a resolved request needs navigation only.
/// All writes are exact-frame inputs. No command, draft or uncertain write is replayed.
enum CodexChildApprovalNavigation {
    struct Interrupted: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }
    struct Outcome: Sendable {
        let delivery: TerminalDelivery
        let approved: Bool
    }
    struct Request: Equatable, Sendable {
        let label: String
        let content: String
    }
    private static func compact(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.filter { !$0.isWhitespace }
    }
    private static func rows(_ text: String) -> [String] {
        PromptDetector.normalizedLines(text).map { $0.trimmingCharacters(in: .whitespaces) }
    }
    static func requiresNavigation(_ raw: String) -> Bool {
        PromptDetector.detect(raw, agent: .codex).map {
            compact($0.dialog).hasSuffix("Pressentertoconfirmoresctocancelorotoopenthread")
        } == true
    }
    static func request(_ raw: String) -> Request? {
        guard let prompt = PromptDetector.detect(raw, agent: .codex),
              compact(prompt.dialog).hasSuffix("Pressentertoconfirmoresctocancelorotoopenthread") else { return nil }
        let lines = rows(prompt.dialog)
        guard let index = lines.firstIndex(where: { $0.hasPrefix("Thread: ") }),
              lines.filter({ $0.hasPrefix("Thread: ") }).count == 1,
              index > 0,let end=lines[(index+1)...].firstIndex(of:""),end-index<=8 else { return nil }
        let label = String(lines[index].dropFirst(8))+lines[(index+1)..<end].joined()
        // Preserve every label character across terminal reflow. A clipped or
        // ambiguous label still cannot identify a navigation destination.
        guard label.hasPrefix("/root/"), !label.contains("…"), !label.contains("["),
              !label.contains(where: \.isWhitespace),
              let content = content(prompt, removing: index..<end) else { return nil }
        return Request(label: label, content: content)
    }
    private static func content(_ prompt: ApprovalPrompt, removing thread: Range<Int>? = nil) -> String? {
        let lines = rows(prompt.dialog)
        guard let choice = lines.firstIndex(where: { $0.range(of: #"^[›❯»>]\s*1\.\s+"#, options: .regularExpression) != nil }) else { return nil }
        return compact(lines[..<choice].enumerated().filter {thread?.contains($0.offset) != true}.map(\.element).joined(separator: "\n"))
    }
    static func childReady(_ raw: String, label: String) -> Bool {
        guard PromptDetector.detect(raw, agent: .codex) == nil,
              QuestionDetector.detect(raw, agent: .codex) == nil else { return false }
        let lines = rows(raw)
        guard let composer = lines.lastIndex(where: { compact($0) == "›Viewingsub-agent—directinputisdisabled" }) else { return false }
        var footer = Array(lines.dropFirst(composer + 1).filter { !$0.isEmpty })
        if footer.last == "← for agents · ? for shortcuts" {footer.removeLast()}
        guard (1...4).contains(footer.count),!footer.contains(where:{$0.hasPrefix("›")}) else{return false}
        let joined=compact(footer.joined())
        return joined.hasSuffix("·`"+label+"`") || joined.hasSuffix("·"+label)
    }
    struct PickerRow: Equatable {
        let selected: Bool
        let primary: Bool
        let id: String
    }
    static func picker(_ raw: String) -> [PickerRow]? {
        let lines = rows(raw)
        guard let start = lines.lastIndex(of: "Subagents"),
              lines.last(where: { !$0.isEmpty }) == "enter select · esc back",
              lines.dropFirst(start + 1).contains(where: { $0.hasPrefix("Select an agent to watch.") }) else { return nil }
        let expression = try! NSRegularExpression(pattern: #"^([›❯»>]\s*)?[1-9][0-9]*\.\s+(.+?)\s+([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})$"#)
        let body=Array(lines.dropFirst(start+1).dropLast())
        let numbered=body.indices.filter {body[$0].range(of:#"^([›❯»>]\s*)?[1-9][0-9]*\.\s+"#,options:.regularExpression) != nil}
        let entries = numbered.enumerated().compactMap { position,index -> PickerRow? in
            let end=position+1<numbered.count ? numbered[position+1]:body.count
            let row=body[index..<end].filter{!$0.isEmpty}.joined(separator:" ")
            let ns = row as NSString
            guard let match = expression.firstMatch(in: row, range: NSRange(location: 0, length: ns.length)) else { return nil }
            let title = ns.substring(with: match.range(at: 2)).replacingOccurrences(of: "• ", with: "")
            return PickerRow(selected: match.range(at: 1).location != NSNotFound,
                primary: title == "Main [default]" || title == "Main [default] (current)",
                id: ns.substring(with: match.range(at: 3)).lowercased())
        }
        guard !entries.isEmpty,entries.count==numbered.count, entries.filter(\.selected).count == 1,
              Set(entries.map(\.id)).count == entries.count else { return nil }
        return entries
    }
    static func approve(target: ScreenTarget, initial: String, parentThreadID: String?, adapter: ScreenHostAdapter,
                        valid: @escaping @Sendable () async -> Bool) async throws -> Outcome {
        guard let original = request(initial) else { throw AppError.message("하위 요청의 화면 연결을 확인하지 못했습니다.") }
        func check() async throws {
            try Task.checkCancellation()
            guard await valid() else { throw AppError.message("원본 세션 또는 입력 상태가 바뀌어 화면 조작을 멈췄습니다.") }
        }
        func work<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
            try await check()
            let task = Task.detached(priority: .userInitiated, operation: operation)
            return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        }
        func read() async throws -> String {
            let snapshot = try await work { try adapter.readForValidation([target]) }
            let frames = snapshot.screens.filter { $0.tty == target.tty }
            guard frames.count == 1, !snapshot.failures.contains(where: { $0.tty == nil || $0.tty == target.tty }) else {
                throw AppError.message("원래 터미널의 새 화면을 확인하지 못했습니다.")
            }
            try await check()
            return frames[0].contents
        }
        func awaitFrame(_ predicate: (String) -> Bool) async throws -> String {
            let deadline = Date().addingTimeInterval(8)
            for _ in 0..<40 {
                let frame = try await read()
                if predicate(frame) { return frame }
                guard Date() < deadline else { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw AppError.message("하위 요청의 화면 이동 결과를 확인하지 못했습니다. 원래 터미널을 확인해주세요.")
        }
        func deliver(_ input: RemoteTerminalInput, frame: String) async throws -> TerminalDelivery {
            try await work { try adapter.input(target, frame, .codex, input) }
        }
        func send(_ input: RemoteTerminalInput, frame: String) async throws {
            guard try await deliver(input, frame: frame) == .sent else {
                throw AppError.message("화면이 바뀌어 추가 키를 보내지 않았습니다. 터미널을 확인해주세요.")
            }
        }
        let opened: TerminalDelivery
        do { opened = try await deliver(.init(kind: .characters, text: "o"), frame: initial) }
        catch { throw Interrupted(reason: error.localizedDescription) }
        guard opened == .sent else { return Outcome(delivery: opened, approved: false) }
        do {
            var frame = try await awaitFrame { raw in
                childReady(raw, label: original.label) || PromptDetector.detect(raw, agent: .codex).map {
                    !compact($0.dialog).contains("orotoopenthread") && content($0) == original.content
                } == true
            }
            var approved = false
            if let prompt = PromptDetector.detect(frame, agent: .codex) {
                guard content(prompt) == original.content else { throw AppError.message("하위 요청이 바뀌었습니다.") }
                let expected = frame
                let delivery = try await work { try adapter.approve(target, expected, .codex) }
                guard delivery == .sent else { throw AppError.message("하위 요청의 승인 입력을 전달하지 못했습니다.") }
                approved = true
                frame = try await awaitFrame { childReady($0, label: original.label) }
            }
            // Alt+Left cycles through siblings, so select the primary UUID in the
            // official picker instead. The disabled child composer has no draft.
            try await send(.init(kind: .characters, text: "/subagents"), frame: frame)
            frame = try await awaitFrame { rows($0).contains("› /subagents") }
            try await Task.sleep(for: .milliseconds(350)) // Codex's ASCII paste-burst window.
            try await send(.init(kind: .enter), frame: frame)
            frame = try await awaitFrame { picker($0) != nil }
            var selectedParent = false
            for _ in 0..<64 {
                guard let selected = picker(frame)?.first(where: \.selected) else { break }
                if selected.primary {
                    selectedParent = parentThreadID == nil || selected.id == parentThreadID?.lowercased()
                    break
                }
                // Physical Home may scroll Terminal.app's buffer rather than send
                // a key to Codex. Use ordinary arrows and verify each selected UUID.
                try await send(.init(kind: .up), frame: frame)
                frame = try await awaitFrame { picker($0)?.first(where: \.selected)?.id != selected.id && picker($0) != nil }
            }
            guard selectedParent else { throw AppError.message("원래 부모 세션을 목록에서 확인하지 못해 선택하지 않았습니다.") }
            try await send(.init(kind: .enter), frame: frame)
            _ = try await awaitFrame { raw in
                let footer = Array(rows(raw).filter { !$0.isEmpty }.suffix(2))
                return (footer.last?.hasSuffix("Main [default]") == true ||
                    footer.count == 2 && footer[0].hasSuffix("Main [default]") && footer[1] == "← for agents · ? for shortcuts") && picker(raw) == nil
            }
            return Outcome(delivery: .sent, approved: approved)
        } catch { throw Interrupted(reason: error.localizedDescription) }
    }
}
