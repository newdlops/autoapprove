import Foundation

public struct WebQuestionField: Codable, Equatable, Sendable {
    public struct Option: Codable, Equatable, Sendable {
        public var label: String
        public var description: String?
    }
    public var id: String
    public var question: String
    public var options: [Option]
    public var multiSelect: Bool

    public static func parse(_ value: Any?) throws -> [Self] {
        guard let array = value as? [JSONObject], (1...8).contains(array.count) else {
            throw RemoteHTTPError(400, "질문은 1~8개를 지정해주세요.")
        }
        var titles = Set<String>(), ids = Set<String>()
        return try array.enumerated().map { index, item in
            guard let question = item["question"] as? String, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  question.utf8.count <= 8000, !question.contains("\0"), titles.insert(question).inserted else {
                throw RemoteHTTPError(400, "질문 내용이 비어 있거나 중복되었거나 너무 깁니다.")
            }
            let id = item["id"] as? String ?? String(index)
            guard !id.isEmpty, id.utf8.count <= 128, ids.insert(id).inserted else { throw RemoteHTTPError(400, "질문 ID가 올바르지 않습니다.") }
            guard item["options"] == nil || item["options"] is [JSONObject], item["multiSelect"] == nil || item["multiSelect"] is Bool else { throw RemoteHTTPError(400, "선택지 형식이 올바르지 않습니다.") }
            let supplied = item["options"] as? [JSONObject] ?? []
            guard supplied.count <= 16 else { throw RemoteHTTPError(400, "선택지가 너무 많습니다.") }
            var labels = Set<String>()
            let options = try supplied.map { option -> Option in
                guard let label = option["label"] as? String, !label.isEmpty, label.utf8.count <= 2000, !label.contains("\0"),
                      labels.insert(label).inserted else { throw RemoteHTTPError(400, "선택지 내용이 올바르지 않습니다.") }
                let description = option["description"] as? String
                guard description == nil || description!.utf8.count <= 4000 && !description!.contains("\0") else { throw RemoteHTTPError(400, "선택지 설명이 너무 깁니다.") }
                return Option(label: label, description: description)
            }
            return Self(id: id, question: question, options: options, multiSelect: item["multiSelect"] as? Bool ?? false)
        }
    }

    /// Validate explicit selections separately from free text; never accept a default on the user's behalf.
    public static func answers(_ value: Any?, for fields: [Self]) throws -> [String: String] {
        guard let supplied = value as? [String: JSONObject], Set(supplied.keys) == Set(fields.map(\.id)) else {
            throw RemoteHTTPError(400, "모든 질문에 답변해주세요.")
        }
        var result: [String: String] = [:]
        for field in fields {
            let answer = supplied[field.id]!
            guard let choices = answer["choices"] as? [String], let text = answer["text"] as? String,
                  Set(choices).count == choices.count, field.multiSelect || choices.count <= 1,
                  choices.allSatisfy({ choice in field.options.contains { $0.label == choice } }),
                  text.utf8.count <= 8000, !text.contains("\0") else { throw RemoteHTTPError(400, "선택지 또는 추가 답변을 확인해주세요.") }
            let composed = [choices.joined(separator: ", "), text.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }.joined(separator: "\n")
            guard !composed.isEmpty, composed.utf8.count <= 16_000 else { throw RemoteHTTPError(400, "각 질문의 선택지를 고르거나 답변을 입력해주세요.") }
            result[field.question] = composed
        }
        return result
    }
}

public struct WebQuestionRequest: Codable, Equatable, Sendable {
    public var id: String
    public var sessionID: String?
    public var title: String
    public var questions: [WebQuestionField]
    public var expiresAt: Date
    public var phase: String
    public var answers: [String: String]?
}

@MainActor public final class WebQuestionInbox {
    private struct Entry { var owner: String; var request: WebQuestionRequest }
    private var entries: [String: Entry] = [:]
    public init() {}
    public func pending(at now: Date = Date()) -> [WebQuestionRequest] {
        expire(at: now)
        return entries.values.map(\.request).filter { $0.phase == "waiting" }.sorted { $0.expiresAt < $1.expiresAt }
    }
    public func create(_ object: JSONObject, owner: String, at now: Date = Date()) throws -> WebQuestionRequest {
        expire(at: now)
        guard entries.count < 128 else { throw RemoteHTTPError(409, "질문이 너무 많습니다. 기존 질문을 먼저 정리해주세요.") }
        let fields = try WebQuestionField.parse(object["questions"])
        let title = object["title"] as? String ?? "응답이 필요한 질문"
        guard !title.isEmpty, title.utf8.count <= 1000 else { throw RemoteHTTPError(400, "질문 제목이 올바르지 않습니다.") }
        let request = WebQuestionRequest(id: UUID().uuidString, sessionID: object["sessionID"] as? String, title: title, questions: fields,
            expiresAt: now.addingTimeInterval(600), phase: "waiting")
        entries[request.id] = Entry(owner: owner, request: request)
        return request
    }
    public func get(_ id: String, owner: String, at now: Date = Date()) throws -> WebQuestionRequest {
        expire(at: now)
        guard let entry = entries[id], entry.owner == owner else { throw RemoteHTTPError(404, "이 MCP 연결의 질문을 찾지 못했습니다.") }
        return entry.request
    }
    public func answer(_ id: String, answers: Any?, at now: Date = Date()) throws {
        expire(at: now)
        guard var entry = entries[id], entry.request.phase == "waiting", entry.request.expiresAt > now else { throw RemoteHTTPError(409, "질문이 이미 처리되었거나 만료되었습니다.") }
        entry.request.answers = try WebQuestionField.answers(answers, for: entry.request.questions)
        entry.request.phase = "answered"; entries[id] = entry
    }
    public func cancel(owner: String) {
        for id in entries.keys where entries[id]?.owner == owner && entries[id]?.request.phase == "waiting" { entries[id]?.request.phase = "cancelled" }
    }
    public func clear() { entries.removeAll() }
    private func expire(at now: Date) {
        for id in entries.keys {
            guard let entry = entries[id] else { continue }
            if entry.request.expiresAt.addingTimeInterval(600) <= now { entries.removeValue(forKey: id) }
            else if entry.request.expiresAt <= now && entry.request.phase == "waiting" { entries[id]?.request.phase = "expired" }
        }
    }
}
