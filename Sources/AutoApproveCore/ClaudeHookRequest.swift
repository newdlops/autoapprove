import Foundation
import CryptoKit

/// The UI can answer only while the original synchronous Claude hook is alive.
public struct ClaudeApproval: Codable, Equatable, Identifiable {
    public var id: String
    public var summary: String
    public var answer: String
    public var isQuestion: Bool
    public var sending: Bool
    public var expiresAt: Date
    public var automaticAt: Date?
    public var questions: [WebQuestionField]? = nil
    public var systemCommandRisk: SystemCommandRisk? = nil
    public var buttonTitle: String { systemCommandRisk != nil ? "안전한 방법으로 계속" : isQuestion ? (answer.count > 32 ? String(answer.prefix(31)) + "…" : answer) : "허용" }
}

struct ClaudeHookReceipt: Codable {
    var id: String
    var fingerprint: String
    var sessionID: String
    var logicalID: String?
    var createdAt: Date
    var expiresAt: Date
    /// nil keeps the hook open; {} hands it back to Claude's original UI.
    var response: String?
    var audit: AuditEvent?
    var acknowledged = false
}

/// Validate the complete wire identity before reading a receipt. Saved replies
/// and ACKs do not need to rebuild questions, summaries or command analysis.
struct ClaudeHookEnvelope {
    private static let hexadecimalDigits = Array("0123456789abcdef".utf8)
    let payload: JSONObject
    let id: String
    let fingerprint: String
    let sessionID: String
    let expiresAt: Date
    let event: String
    let providerID: String
    var isQuestion: Bool { payload["tool_name"] as? String == "AskUserQuestion" }

    init?(_ payload: JSONObject, at now: Date) {
        guard payload["autoapproveProtocol"] as? Int == 1,
              let id = payload["requestID"] as? String, UUID(uuidString: id) != nil,
              let event = payload["hook_event_name"] as? String,
              let provider = payload["session_id"] as? String, !provider.isEmpty,
              let expiry = payload["autoapproveExpiresAt"] as? Double, expiry.isFinite,
              expiry > now.timeIntervalSince1970, expiry <= now.timeIntervalSince1970 + 610,
              let bytes = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return nil }
        self.payload = payload; self.id = id; self.event = event; providerID = provider
        fingerprint = Self.hexadecimal(SHA256.hash(data: bytes))
        let pid = (payload["agentPID"] as? NSNumber)?.int32Value ?? 0
        let started = payload["agentStarted"] as? String ?? ""
        sessionID = pid > 0 && !started.isEmpty ? "process:\(pid):\(started)" : "claude:\(provider)"
        expiresAt = Date(timeIntervalSince1970: expiry)
    }

    private static func hexadecimal(_ digest: SHA256.Digest) -> String {
        var bytes: [UInt8] = []
        // SHA-256 always returns 32 bytes; Digest exposes Sequence here, so
        // avoid materializing an intermediate array just to ask for its count.
        bytes.reserveCapacity(64)
        for byte in digest {
            bytes.append(hexadecimalDigits[Int(byte >> 4)])
            bytes.append(hexadecimalDigits[Int(byte & 0x0f)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

struct ClaudeHookRequest {
    let payload: JSONObject
    let id: String
    let fingerprint: String
    let sessionID: String
    let logicalID: String?
    let expiresAt: Date
    let response: JSONObject?
    let answer: String
    let summary: String
    let tool: String
    let inputJSON: String?
    let questions: [WebQuestionField]?
    var systemCommandRisk: SystemCommandRisk?
    var safetyResponse: JSONObject? {
        guard let risk = systemCommandRisk, let event = payload["hook_event_name"] as? String,
              ["PreToolUse", "PermissionRequest"].contains(event) else { return nil }
        return risk.denial(event: event)
    }
    var isQuestion: Bool { tool == "AskUserQuestion" }

    init?(_ payload: JSONObject, at now: Date) {
        guard let envelope = ClaudeHookEnvelope(payload, at: now) else { return nil }
        self.init(envelope)
    }
    init(_ envelope: ClaudeHookEnvelope) {
        let payload = envelope.payload, id = envelope.id, event = envelope.event, provider = envelope.providerID
        self.payload = payload; self.id = id
        fingerprint = envelope.fingerprint; sessionID = envelope.sessionID; expiresAt = envelope.expiresAt
        tool = payload["tool_name"] as? String ?? ""
        let input = payload["tool_input"] as? JSONObject ?? [:]
        let parsedQuestions = tool == "AskUserQuestion" && ["PreToolUse", "PermissionRequest"].contains(event) && (input["answers"] as? JSONObject)?.isEmpty != false
            ? try? WebQuestionField.parse(input["questions"]) : nil
        questions = parsedQuestions
        summary = QuestionDetector.hookSummary(tool: tool, input: input, message: payload["message"] as? String)
        let risk = ["PreToolUse", "PermissionRequest"].contains(event)
            ? SystemCommandRisk.detect(tool: tool, input: input, summary: summary, cwd: payload["cwd"] as? String ?? "") : nil
        systemCommandRisk = risk
        let answerValue: String
        let responseValue: JSONObject?
        if tool == "AskUserQuestion", ["PreToolUse", "PermissionRequest"].contains(event), let yes = YesNoConfirmation.detect(input) {
            answerValue = yes.answer
            if event == "PreToolUse" {
                responseValue = ["hookSpecificOutput": ["hookEventName": event, "permissionDecision": "allow", "updatedInput": yes.updatedInput(input)]]
            } else {
                responseValue = ["hookSpecificOutput": ["hookEventName": event, "decision": ["behavior": "allow", "updatedInput": yes.updatedInput(input)]]]
            }
        } else if event == "PermissionRequest", !["AskUserQuestion", "ExitPlanMode", "EnterPlanMode"].contains(tool), !tool.isEmpty {
            answerValue = "허용"
            responseValue = ["hookSpecificOutput": ["hookEventName": event, "decision": ["behavior": "allow"]]]
        } else { answerValue = ""; responseValue = nil }
        answer = answerValue; response = responseValue
        // Only actionable requests are written to the audit trail. Routine
        // PreToolUse/PostToolUse events are frequent and never store this field;
        // avoid pretty-printing and allocating their full tool input each time.
        let needsAuditInput = event == "PermissionRequest" || responseValue != nil || parsedQuestions != nil || risk != nil
        inputJSON = needsAuditInput
            ? (try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) }
            : nil
        if responseValue != nil || parsedQuestions != nil || risk != nil {
            let toolID = (payload["tool_use_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            logicalID = sessionID + ":" + provider + ":" + toolID
        } else { logicalID = nil }
    }
}

/// Retry only this helper invocation. Never print the private bridge envelope to Claude.
public enum ClaudeHookClient {
    public static func run(payload: JSONObject, path: String) -> JSONObject {
        var payload = payload
        payload["requestID"] = UUID().uuidString
        payload["autoapproveProtocol"] = 1
        let decision = ["PreToolUse", "PermissionRequest"].contains(payload["hook_event_name"] as? String ?? "")
        let deadline = Date().addingTimeInterval(decision ? 600 : 8)
        payload["autoapproveExpiresAt"] = deadline.timeIntervalSince1970
        var lastContact = Date(), waiting = false
        while Date() < deadline {
            do {
                let result = try SocketClient.request(path: path, message: ["method": waiting ? "hookWait" : "hook", "params": payload], timeout: waiting ? 20 : decision ? 5 : 2)
                // Older apps return the normal hook JSON, including an empty object.
                guard let bridge = result["autoapproveBridge"] as? JSONObject else { return result }
                lastContact = Date()
                if let response = bridge["response"] as? JSONObject {
                    // A receipt means the helper received the exact saved response.
                    _ = try? SocketClient.request(path: path, message: ["method": "hookAck", "params": payload], timeout: 2)
                    return response
                }
                guard bridge["waiting"] as? Bool == true else { return [:] }
                waiting = decision && bridge["waitSupported"] as? Bool == true
                if waiting { continue }
            } catch {
                waiting = false
                // Allow a short app restart; leave the original Claude flow available if it stays down.
                if Date().timeIntervalSince(lastContact) >= (decision ? 20 : 4) { return [:] }
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return [:]
    }
}
