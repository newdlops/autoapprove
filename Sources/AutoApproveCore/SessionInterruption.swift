import Foundation

public struct SessionInterruption: Codable, Equatable {
    public enum Kind: String, Codable {
        case capacity, transport, api, authentication, configuration
        public var title: String {
            switch self {
            case .capacity: return "모델 용량 부족"
            case .transport: return "연결 오류"
            case .api: return "API 오류"
            case .authentication: return "인증 오류"
            case .configuration: return "설정 확인 필요"
            }
        }
        public var retryable: Bool { self != .authentication && self != .configuration }
        public static func claudeFailure(_ error: String) -> Kind {
            switch error {
            case "authentication_failed", "oauth_org_not_allowed", "cloud_credential_error": return .authentication
            case "billing_error", "account_on_hold", "invalid_request", "model_not_found": return .configuration
            case "rate_limit", "overloaded", "server_error", "max_output_tokens": return .api
            default: return .transport
            }
        }
    }
    public var id: String
    public var kind: Kind
    public var detail: String
    public var date: Date
    public var processEnded: Bool = false
    public var resumedSessionID: String?
    public var recoveredAt: Date?
    public var resumeUncertain: Bool?
    public var resumeIdentity: String?
    public var recoveryStatus: String?
    public var recoveryDetail: String?
    public var needsAttention: Bool { recoveredAt == nil }
    public init(id: String, kind: Kind, detail: String, date: Date = Date()) {
        self.id = id; self.kind = kind; self.detail = String(detail.prefix(600)); self.date = date
    }
}
