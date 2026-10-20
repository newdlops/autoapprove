import Foundation

/// Automatic questions have two explicit policies: confirm a permission, or
/// retain a model that the question itself identifies as the current model.
public struct AutomaticQuestionDecision {
    public enum Kind: Equatable, Sendable { case confirmation, keepCurrentModel }
    public let question: String
    public let answer: String
    public let kind: Kind

    public static func detect(_ question: QueuedQuestion) -> Self? {
        detect(["questions": [["question": question.title, "multiSelect": question.multiSelect ?? false,
                                "options": question.options.map { ["label": $0] }]]])
    }

    public static func detect(_ input: JSONObject) -> Self? {
        if let answers = input["answers"] {
            guard let answers = answers as? JSONObject, answers.isEmpty else { return nil }
        }
        guard let questions = input["questions"] as? [JSONObject], questions.count == 1,
              let item = questions.first, let title = item["question"] as? String,
              let options = item["options"] as? [JSONObject] else { return nil }
        if let multi = item["multiSelect"] { guard let value = multi as? Bool, !value else { return nil } }
        let labels = options.compactMap { $0["label"] as? String }
        guard labels.count == options.count else { return nil }
        if let index = currentModelIndex(question: title, options: labels,
                descriptions: options.map { $0["description"] as? String ?? "" }) {
            return Self(question: title, answer: labels[index], kind: .keepCurrentModel)
        }
        // Model changes are never an ordinary affirmative confirmation.
        guard !isModelChange(title), !isModelPicker(title),
              let confirmation = YesNoConfirmation.detect(input) else { return nil }
        return Self(question: confirmation.question, answer: confirmation.answer, kind: .confirmation)
    }

    public func updatedInput(_ input: JSONObject) -> JSONObject {
        var result = input; result["answers"] = [question: answer]; return result
    }

    static func mentionsModel(_ text: String) -> Bool {
        text.contains("모델") || modelWords.contains { text.range(of: $0, options: .caseInsensitive) != nil }
    }
    private static let modelWords = ["model", "gpt-", "claude", "sonnet ", "opus ", "haiku "]

    static func isModelHeading(_ text: String) -> Bool {
        let value = text.lowercased()
        return value.hasPrefix("select model") || value.hasPrefix("select a model") || value.hasPrefix("choose model")
            || value.hasPrefix("choose a model") || value.hasPrefix("model selection")
            || value.hasPrefix("모델 선택") || value.hasPrefix("모델을 선택")
    }

    private static func isModelChange(_ title: String) -> Bool {
        guard mentionsModel(title), !isKeepingModel(title) else { return false }
        return title.range(of: #"(?i)\b(?:switch|change|replace|upgrade)\s+(?:to\s+)?(?:(?:a|the)\s+)?(?:(?:different|another|new|current)\s+)?(?:model|(?:gpt|claude)[-_/][a-z0-9._+/-]+|(?:claude\s+)?(?:sonnet|opus|haiku)\s+[0-9.]+)\b|\b(?:use|try)\s+(?:(?:a|the)\s+)?(?:(?:different|another|new)\s+model|(?:gpt|claude)[-_/][a-z0-9._+/-]+|(?:claude\s+)?(?:sonnet|opus|haiku)\s+[0-9.]+)\b|\b(?:don't|do not)\s+(?:keep|retain|continue using|use)\s+(?:the\s+)?(?:current|existing|same)\s+model\b|(?:모델(?:을)?\s*|(?:gpt|claude)[-_/][a-z0-9._+/-]+\s*(?:으로|로)\s*)(?:(?:변경|전환|교체)\s*(?:할까요|하시겠습니까|하겠습니까|할래요)|바꿀까요|바꾸시겠습니까|바꾸겠습니까)"#, options: .regularExpression) != nil
    }

    private static func isModelPicker(_ title: String) -> Bool {
        guard mentionsModel(title) else { return false }
        return title.range(of: #"(?i)\b(?:which|what|select|choose|pick)\b[^\n?]{0,100}\bmodel\b|어떤\s*모델|모델\s*(?:선택|고르)"#, options: .regularExpression) != nil
    }

    private static func isKeepingModel(_ title: String) -> Bool {
        guard mentionsModel(title) else { return false }
        if title.range(of: #"(?i)\b(?:don't|do not)\s+(?:keep|retain|continue using|use)\b"#, options: .regularExpression) != nil { return false }
        return title.range(of: #"(?i)\b(?:keep(?: using)?|retain|continue using|stay with|use)\s+(?:the\s+)?(?:current|existing|same)\s+model\b|\b(?:don't|do not)\s+(?:switch|change|replace)\s+(?:the\s+)?(?:current\s+|existing\s+|same\s+)?model\b|(?:현재|기존|같은)\s*모델(?:을)?\s*(?:그대로\s*)?(?:계속\s*)?(?:유지|사용)"#, options: .regularExpression) != nil
    }

    private static func cleaned(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: #"[‘’ʼ]"#, with: "'", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s*(?:\((?:recommended|추천|권장)\)|\[(?:recommended|추천|권장)\])\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!。！")))
    }

    // These are model identifier shapes, not a preference list. A newer model
    // or the highlighted/recommended row is never inferred to be the old model.
    private static let modelName = #"(?i)^(?:(?:gpt|codex|claude)[-_/.][a-z0-9][a-z0-9._+/-]*|o[0-9][a-z0-9._+/-]*|(?:claude[ -])?(?:sonnet|opus|haiku)(?:[ -][0-9]+(?:[. -][0-9]+)*)?)$"#

    static func currentModelIndex(question: String, options: [String], descriptions: [String] = []) -> Int? {
        guard options.count >= 2, mentionsModel(question) else { return nil }
        let labels = options.map(cleaned)
        let retain = #"(?i)^(?:(?:no|아니오|아니요)\s*[,，:：]\s*)?(?:(?:keep|retain|use) (?:using )?(?:the )?(?:current|existing|same)(?: model)?|(?:the )?(?:current|existing|same) model|(?:continue|stay) (?:using|with) (?:the )?(?:current|existing|same) model|(?:don't|do not) change (?:the )?model|(?:현재|기존|같은|동일한)\s*모델(?:을)?(?:\s*(?:그대로\s*)?(?:유지|사용|계속 사용)(?:하기|합니다)?|\s*그대로)?|모델\s*변경\s*(?:없음|안 함|하지 않음))$"#
        let currentMarker = #"(?i)\s*(?:\((?:current|currently selected|현재|현재 모델|사용 중|사용중)\)|\[(?:current|currently selected|현재|현재 모델|사용 중|사용중)\])\s*$"#
        let currentDescription = #"(?i)^(?:(?:the )?(?:current|currently selected|existing) model|(?:현재|기존)\s*(?:사용\s*중인\s*)?모델)$"#
        var explicit: [Int] = []
        for (index, label) in labels.enumerated() {
            if label.range(of: retain, options: .regularExpression) != nil { explicit.append(index); continue }
            if let marker = label.range(of: currentMarker, options: .regularExpression),
               String(label[..<marker.lowerBound]).range(of: modelName, options: .regularExpression) != nil {
                explicit.append(index); continue
            }
            if descriptions.indices.contains(index),
               cleaned(descriptions[index]).range(of: currentDescription, options: .regularExpression) != nil,
               label.range(of: modelName, options: .regularExpression) != nil { explicit.append(index) }
        }
        if explicit.isEmpty, isModelChange(question) || isKeepingModel(question) {
            let input: JSONObject = ["questions": [["question": question, "options": options.enumerated().map { index, label -> JSONObject in
                ["label": label, "description": descriptions.indices.contains(index) ? descriptions[index] : ""]
            }]]]
            if let confirmation = YesNoConfirmation.detect(input) {
                if isKeepingModel(question), !isModelChange(question) {
                    explicit = options.indices.filter { options[$0] == confirmation.answer }
                } else { explicit = options.indices.filter { YesNoConfirmation.isDenial(options[$0]) } }
            }
        }
        // A title may name the old model while listing ordinary model names.
        if explicit.isEmpty {
            let pattern = #"(?i)(?:current model\s*[:=]|currently using|(?:현재|기존)\s*모델\s*[:=])\s*([a-z0-9][a-z0-9._+/-]*)"#
            if let expression = try? NSRegularExpression(pattern: pattern) {
                let matches = expression.matches(in: question, range: NSRange(question.startIndex..., in: question))
                if matches.count == 1, let range = Range(matches[0].range(at: 1), in: question) {
                    let name = String(question[range])
                    if name.range(of: modelName, options: .regularExpression) != nil {
                        explicit = labels.indices.filter { labels[$0].caseInsensitiveCompare(name) == .orderedSame }
                    }
                }
            }
        }
        guard explicit.count == 1, let index = explicit.first,
              labels.filter({ $0.caseInsensitiveCompare(labels[index]) == .orderedSame }).count == 1 else { return nil }
        return index
    }
}
