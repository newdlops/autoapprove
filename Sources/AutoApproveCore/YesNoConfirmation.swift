import Foundation

/// A single yes/no decision, optionally with repeated-permission choices.
/// This does not choose between projects, plans, environments or multiple answers.
public struct YesNoConfirmation {
    public let question: String
    public let answer: String
    private static let affirmativeWords = "예|네|응|허용|yes|allow"
    private static let denialWords = "아니오|아니요|거부|취소|no|deny|cancel|don't allow|do not allow"

    public static func detect(_ question: QueuedQuestion) -> YesNoConfirmation? {
        guard question.multiSelect != true else { return nil }
        return detect(question: question.title, labels: question.options)
    }

    public static func detect(_ input: JSONObject) -> YesNoConfirmation? {
        if let answers = input["answers"] {
            guard let answers = answers as? JSONObject, answers.isEmpty else { return nil }
        }
        guard let questions = input["questions"] as? [JSONObject], questions.count == 1,
              let item = questions.first, let question = item["question"] as? String,
              let options = item["options"] as? [JSONObject] else { return nil }
        if let multiSelect = item["multiSelect"] {
            guard let value = multiSelect as? Bool, !value else { return nil }
        }
        let labels = options.compactMap { $0["label"] as? String }
        guard labels.count == options.count else { return nil }
        return detect(question: question, labels: labels,
            descriptions: options.map { $0["description"] as? String ?? "" })
    }

    /// A queue already has typed labels. Hook objects validate their shape
    /// before entering this shared confirmation policy.
    static func detect(question: String, labels: [String], descriptions: [String] = []) -> YesNoConfirmation? {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              labels.count >= 2 else { return nil }
        // Two options are not inherently a confirmation: "Yes, use staging" /
        // "No, use production" still chooses a task. Apply the same complete-label
        // permission rules to every menu, regardless of its option count.
        guard let index = singleApprovalIndex(labels, descriptions: descriptions) else { return nil }
        // Hook answers identify an option by its label, not by its position.
        let answer = labels[index].precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard labels.filter({ $0.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == answer }).count == 1 else { return nil }
        return YesNoConfirmation(question: question, answer: labels[index])
    }

    static func isDenial(_ label: String) -> Bool {
        isDenial(cleaned: cleaned(label))
    }

    private static func isDenial(cleaned text: String) -> Bool {
        if text.range(of: "(?i)^(?:" + denialWords + ")$", options: .regularExpression) != nil { return true }
        // The CLI's fixed rejection action is still No. Arbitrary explanations
        // after No/Cancel must not turn a different task into a permission menu.
        return text.range(of: #"(?i)^no\s*[,，:：—–-]\s*and tell (?:codex|claude|the agent) what to do differently$"#, options: .regularExpression) != nil
    }

    private static func isUnchangedASCII(_ value: String) -> Bool {
        value.utf8.withContiguousStorageIfAvailable { bytes in
            guard let first = bytes.first, let last = bytes.last else { return true }
            guard first != 32, first != 33, first != 46,
                  last != 32, last != 33, last != 46 else { return false }
            var previousSpace = false
            for byte in bytes {
                guard byte >= 32, byte < 127, byte != 40, byte != 91 else { return false }
                if byte == 32 && previousSpace { return false }
                previousSpace = byte == 32
            }
            return true
        } ?? false
    }

    /// Plain words outside every supported permission prefix cannot become a
    /// confirmation. Hints, whitespace compaction, punctuation cleanup and
    /// Unicode/foreign labels always keep the original parser.
    private static func isPlainNonPermissionWord(_ value: String) -> Bool {
        value.utf8.withContiguousStorageIfAvailable { bytes in
            guard bytes.count <= 4096, let first = bytes.first, first < 128 else { return false }
            switch first | 32 {
            case 97: return false // Allow, approve, always, and
            case 99 where bytes.count >= 3 && bytes[1] | 32 == 97 && bytes[2] | 32 == 110: return false
            case 100 where bytes.count >= 2 && bytes[1] | 32 == 111: return false
            case 100 where bytes.count >= 3 && bytes[1] | 32 == 101 && bytes[2] | 32 == 110: return false
            case 110 where bytes.count >= 2 && bytes[1] | 32 == 111: return false
            case 115 where bytes.count >= 2 && bytes[1] | 32 == 119: return false
            case 117 where bytes.count >= 3 && bytes[1] | 32 == 115 && bytes[2] | 32 == 101: return false
            case 121 where bytes.count >= 3 && bytes[1] | 32 == 101 && bytes[2] | 32 == 115: return false
            default: break
            }
            return isUnchangedASCII(value) && !bytes.contains(32)
        } ?? false
    }

    private static func cleaned(_ value: String) -> String {
        if isUnchangedASCII(value) { return value }
        let hint = #"(?:추천|권장|recommended|[a-z]|esc|shift\s*\+\s*tab)"#
        return value.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: #"[‘’ʼ]"#, with: "'", options: .regularExpression)
            .replacingOccurrences(of: "(?i)(?:\\s*(?:\\(" + hint + "\\)|\\[" + hint + "\\]))+\\s*$", with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!。！")))
    }

    private static func affirmativeTail(cleaned text: String) -> String? {
        guard let prefix = text.range(of: "(?i)^(?:" + affirmativeWords + #")(?=$|[\s,，:：—–-])[\s,，:：—–-]*"#, options: .regularExpression) else { return nil }
        return String(text[prefix.upperBound...])
    }

    // These descriptions do not depend on a request. Normalize them once rather
    // than repeating regex/string work for every option in every permission menu.
    private static let permissionPhrases: [(compact: String, label: String)] = {
        let descriptions = [
            ("Allow", "Run the tool and continue."),
            ("Allow for this session", "Run the tool and remember this choice for this session."),
            ("Always allow", "Run the tool and remember this choice for future tool calls."),
            ("Allow and don't ask me again", "Run the tool and remember this choice for future tool calls."),
            ("Cancel", "Cancel this tool call.")
        ]
        return descriptions.flatMap { label, description in
            [label, cleaned(label + " " + description)].map { phrase in
                (compact: phrase.filter { !$0.isWhitespace }, label: label)
            }
        }
    }()

    /// Codex renders tool permission labels and descriptions in two columns. Match
    /// only complete known phrases. Terminal cells can wrap inside a word, so the
    /// added line-boundary space must not change those phrases' meaning.
    private static func permissionLabel(_ value: String) -> String {
        let text = cleaned(value)
        let compact = text.filter { !$0.isWhitespace }
        for phrase in permissionPhrases where compact.caseInsensitiveCompare(phrase.compact) == .orderedSame {
            return phrase.label
        }
        return text
    }

    static func isToolPermissionMenu(_ labels: [String]) -> Bool {
        let labels = labels.map { permissionLabel($0).lowercased() }
        let known: Set<String> = ["allow", "allow for this session", "always allow", "allow and don't ask me again",
                                  "cancel", "deny", "don't allow", "do not allow"]
        // Tool capabilities determine which permission scopes are offered. Two,
        // three and four rows are valid; an unrelated task is never a scope.
        return (2...4).contains(labels.count) && labels.allSatisfy(known.contains)
            && singleApprovalIndex(labels) == 0
    }

    private static func isCurrentPermission(_ tail: String) -> Bool {
        tail.isEmpty || tail.range(of: #"(?i)^(?:proceed|continue|allow (?:once|this (?:request|time)(?: only)?)|(?:just )?this (?:once|time only)|for this request only|이번(?: 요청)?만(?:\s*(?:허용|승인|진행)(?:하기|합니다|해 ?주세요)?)?|한\s*번만(?:\s*(?:허용|승인)(?:하기|합니다)?)?|(?:허용|승인|진행)(?:합니다|해 ?주세요)?)$"#, options: .regularExpression) != nil
    }

    private static func isRepeatedPermission(_ value: String) -> Bool {
        isRepeatedPermission(cleaned: cleaned(value))
    }

    private static func isRepeatedPermission(cleaned text: String) -> Bool {
        let english = #"(?i)^(?:and\s+)?(?:(?:don't|do not) ask(?: me)?(?: for (?:approval|permission))? again(?: (?:for:?|in|during) .+| this session)?|always allow(?: .+)?|(?:allow|approve) (?:all (?:edits|commands|changes) )?(?:for|during|in) (?:this|the) (?:session|project|folder)|allow all (?:edits|commands|changes)|allow reading from .+ (?:from this project|during this session))$"#
        // Claude Code also offers its permission modes; each changes only later prompts.
        let mode = #"(?i)^(?:and\s+)?(?:(?:switch to|use) auto mode(?: · .+)?|switch to (?:default|accept edits|auto|don't ask|plan mode|bypass permissions)(?: \([^)]*\))? for this session)$"#
        let scope = #"(?:앞으로|이후(?:에도|부터)?|이(?:번)?\s*(?:세션|프로젝트|폴더|명령)(?:에서(?:는)?|\s*동안(?:에는)?|에\s*대해서(?:는)?)?)"#
        let korean = "^(?:" + scope + #"\s*)?(?:(?:다시|매번)\s*)?묻지\s*않(?:기|음|습니다|아도\s*됩니다|고\s*(?:허용|승인)(?:하기|합니다)?)$"#
        let allow = "^(?:" + scope + #"\s*(?:(?:항상|자동으로|계속)\s*)?|(?:항상|자동으로|계속)\s*)(?:허용|승인)(?:하기|합니다|해\s*주세요)?$"#
        return [english, mode, korean, allow].contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    private static func isSessionPermission(cleaned text: String) -> Bool {
        text.range(of: #"(?i)^(?:allow|approve) (?:for|during|in) (?:this|the) session$"#, options: .regularExpression) != nil
    }

    /// Prefer one request. If it is not offered, an explicit session-only Allow
    /// is permitted. Never fall back to a permanent permission or a task choice.
    static func singleApprovalIndex(_ labels: [String], descriptions: [String] = []) -> Int? {
        guard labels.count >= 2 else { return nil }
        var current: [Int] = [], sessionOnly: [Int] = [], denials = 0
        for (index, label) in labels.enumerated() {
            if isPlainNonPermissionWord(label) { return nil }
            let label = permissionLabel(label)
            // These predicates inspect the same normalized label. Keep
            // permissionLabel's separate first pass: cleaning is not idempotent
            // for every nested hint and punctuation combination.
            let text = cleaned(label)
            if isDenial(cleaned: text) { denials += 1; continue }
            if isSessionPermission(cleaned: text) { sessionOnly.append(index); continue }
            if isRepeatedPermission(cleaned: text) { continue }
            guard let tail = affirmativeTail(cleaned: text) else { return nil }
            if isRepeatedPermission(tail) || isRepeatedPermission("allow " + tail) { continue }
            guard isCurrentPermission(tail) || isCurrentPermission("allow " + tail) else { return nil }
            // Claude may put the scope in the description beneath a plain Yes label.
            if descriptions.indices.contains(index), isRepeatedPermission(descriptions[index]) { continue }
            current.append(index)
        }
        guard denials == 1 else { return nil }
        if current.count == 1 { return current[0] }
        return current.isEmpty && sessionOnly.count == 1 ? sessionOnly[0] : nil
    }

    public func updatedInput(_ input: JSONObject) -> JSONObject {
        var updated = input
        updated["answers"] = [question: answer]
        return updated
    }
}
