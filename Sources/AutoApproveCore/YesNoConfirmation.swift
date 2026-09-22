import Foundation

/// A single yes/no decision, optionally with repeated-permission choices.
/// This does not choose between projects, plans, environments or multiple answers.
public struct YesNoConfirmation {
    public let question: String
    public let answer: String
    private static let affirmativeWords = "예|네|yes|allow"
    private static let denialWords = "아니오|아니요|no|deny|don't allow|do not allow"

    public static func detect(_ question: QueuedQuestion) -> YesNoConfirmation? {
        detect(["questions": [[
            "question": question.title,
            "options": question.options.map { ["label": $0] }
        ]]])
    }

    public static func detect(_ input: JSONObject) -> YesNoConfirmation? {
        if let answers = input["answers"] {
            guard let answers = answers as? JSONObject, answers.isEmpty else { return nil }
        }
        guard let questions = input["questions"] as? [JSONObject], questions.count == 1,
              let item = questions.first, let question = item["question"] as? String,
              !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let options = item["options"] as? [JSONObject], options.count >= 2 else { return nil }
        if let multiSelect = item["multiSelect"] {
            guard let value = multiSelect as? Bool, !value else { return nil }
        }
        let labels = options.compactMap { $0["label"] as? String }
        guard labels.count == options.count else { return nil }
        if labels.count > 2 {
            guard let index = singleApprovalIndex(labels, descriptions: options.map { $0["description"] as? String ?? "" }) else { return nil }
            // Hook answers identify an option by its label, not by its position.
            let answer = labels[index].precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard labels.filter({ $0.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == answer }).count == 1 else { return nil }
            return YesNoConfirmation(question: question, answer: labels[index])
        }
        let yes = labels.indices.filter { index in
            let label = cleaned(labels[index])
            guard let tail = affirmativeTail(label),
                  !isRepeatedPermission(tail), !isRepeatedPermission("allow " + tail),
                  !isRepeatedPermission(options[index]["description"] as? String ?? "") else { return false }
            return hasAnswer(label, words: affirmativeWords) || isCurrentPermission(tail) || isCurrentPermission("allow " + tail)
        }
        let no = labels.indices.filter { hasAnswer(cleaned(labels[$0]), words: denialWords) }
        guard yes.count == 1, no.count == 1, yes[0] != no[0] else { return nil }
        return YesNoConfirmation(question: question, answer: labels[yes[0]])
    }

    private static func hasAnswer(_ label: String, words: String) -> Bool {
        let text = label.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "(?i)^(?:" + words + #")(?:\s*[.!。！]?\s*|\s*\((?:추천|권장|recommended)\)\s*|\s*[,，:：—–-]\s*\S[\s\S]*)$"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func cleaned(_ value: String) -> String {
        let hint = #"(?:추천|권장|recommended|[a-z]|esc|shift\s*\+\s*tab)"#
        return value.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: #"[‘’ʼ]"#, with: "'", options: .regularExpression)
            .replacingOccurrences(of: "(?i)(?:\\s*(?:\\(" + hint + "\\)|\\[" + hint + "\\]))+\\s*$", with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!。！")))
    }

    private static func affirmativeTail(_ label: String) -> String? {
        let text = cleaned(label)
        guard let prefix = text.range(of: #"(?i)^(?:yes|예|네|allow)(?=$|[\s,，:：—–-])[\s,，:：—–-]*"#, options: .regularExpression) else { return nil }
        return String(text[prefix.upperBound...])
    }

    private static func isCurrentPermission(_ tail: String) -> Bool {
        tail.isEmpty || tail.range(of: #"(?i)^(?:proceed|continue|allow (?:once|this (?:request|time)(?: only)?)|(?:just )?this (?:once|time only)|for this request only|이번(?: 요청)?만(?:\s*(?:허용|승인|진행)(?:하기|합니다|해 ?주세요)?)?|한\s*번만(?:\s*(?:허용|승인)(?:하기|합니다)?)?|(?:허용|승인|진행)(?:합니다|해 ?주세요)?)$"#, options: .regularExpression) != nil
    }

    private static func isRepeatedPermission(_ value: String) -> Bool {
        let text = cleaned(value)
        let english = #"(?i)^(?:and\s+)?(?:(?:don't|do not) ask(?: me)?(?: for (?:approval|permission))? again(?: (?:for|in|during) .+| this session)?|always allow(?: .+)?|(?:allow|approve) (?:all (?:edits|commands|changes) )?(?:for|during|in) (?:this|the) (?:session|project|folder)|allow all (?:edits|commands|changes))$"#
        let scope = #"(?:앞으로|이후(?:에도|부터)?|이(?:번)?\s*(?:세션|프로젝트|폴더|명령)(?:에서(?:는)?|\s*동안(?:에는)?|에\s*대해서(?:는)?)?)"#
        let korean = "^(?:" + scope + #"\s*)?(?:(?:다시|매번)\s*)?묻지\s*않(?:기|음|습니다|아도\s*됩니다|고\s*(?:허용|승인)(?:하기|합니다)?)$"#
        let allow = "^(?:" + scope + #"\s*(?:(?:항상|자동으로|계속)\s*)?|(?:항상|자동으로|계속)\s*)(?:허용|승인)(?:하기|합니다|해\s*주세요)?$"#
        return [english, korean, allow].contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// Every extra affirmative option must change only the future permission scope.
    /// A unique current-request answer is required; task/environment alternatives remain manual.
    static func singleApprovalIndex(_ labels: [String], descriptions: [String] = []) -> Int? {
        guard labels.count >= 2 else { return nil }
        var current: [Int] = [], denials = 0
        for (index, label) in labels.enumerated() {
            if hasAnswer(cleaned(label), words: denialWords) { denials += 1; continue }
            if isRepeatedPermission(label) { continue }
            guard let tail = affirmativeTail(label) else { return nil }
            if isRepeatedPermission(tail) || isRepeatedPermission("allow " + tail) { continue }
            guard isCurrentPermission(tail) || isCurrentPermission("allow " + tail) else { return nil }
            // Claude may put the scope in the description beneath a plain Yes label.
            if descriptions.indices.contains(index), isRepeatedPermission(descriptions[index]) { continue }
            current.append(index)
        }
        guard current.count == 1, denials == 1 else { return nil }
        return current[0]
    }

    public func updatedInput(_ input: JSONObject) -> JSONObject {
        var updated = input
        updated["answers"] = [question: answer]
        return updated
    }
}
