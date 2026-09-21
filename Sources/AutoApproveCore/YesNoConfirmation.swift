import Foundation

/// A single, explicit yes/no confirmation, independent of the question's wording.
/// This does not choose between projects, plans, environments or multiple answers.
public struct YesNoConfirmation {
    public let question: String
    public let answer: String

    public static func detect(_ input: JSONObject) -> YesNoConfirmation? {
        if let answers = input["answers"] {
            guard let answers = answers as? JSONObject, answers.isEmpty else { return nil }
        }
        guard let questions = input["questions"] as? [JSONObject], questions.count == 1,
              let item = questions.first, let question = item["question"] as? String,
              !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let options = item["options"] as? [JSONObject], options.count == 2 else { return nil }
        if let multiSelect = item["multiSelect"] {
            guard let value = multiSelect as? Bool, !value else { return nil }
        }
        let labels = options.compactMap { $0["label"] as? String }
        guard labels.count == 2 else { return nil }
        func hasAnswer(_ label: String, words: String) -> Bool {
            // Accept explicit labels with a recommendation or description, never words
            // such as “예시”, “네트워크”, “Yesterday”, or an inferred preferred option.
            let text = label.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
            let pattern = "(?i)^(?:" + words + #")(?:\s*[.!。！]?\s*|\s*\((?:추천|권장|recommended)\)\s*|\s*[,，:：—–-]\s*\S[\s\S]*)$"#
            return text.range(of: pattern, options: .regularExpression) != nil
        }
        let yes = labels.indices.filter { hasAnswer(labels[$0], words: "예|네|yes") }
        let no = labels.indices.filter { hasAnswer(labels[$0], words: "아니오|아니요|no") }
        guard yes.count == 1, no.count == 1, yes[0] != no[0] else { return nil }
        return YesNoConfirmation(question: question, answer: labels[yes[0]])
    }

    public func updatedInput(_ input: JSONObject) -> JSONObject {
        var updated = input
        updated["answers"] = [question: answer]
        return updated
    }
}
