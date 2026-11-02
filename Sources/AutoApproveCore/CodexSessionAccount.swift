import Foundation

public struct CodexServerAccountIdentity: Equatable, Sendable {
    public var provider: String
    public var email: String?
    public var plan: String?
    public var authenticated: Bool
    public init(provider:String,email:String?=nil,plan:String?=nil,authenticated:Bool=true) {
        self.provider=provider;self.email=email;self.plan=plan;self.authenticated=authenticated
    }
    public static func decode(_ result:JSONObject) throws -> Self {
        guard let value=result["account"],!(value is NSNull) else {return .init(provider:"로그인되지 않음",authenticated:false)}
        guard let account=value as? JSONObject,let type=account["type"] as? String else {throw AppError.message("연결 서버의 계정 형식을 확인하지 못했습니다.")}
        func text(_ key:String) throws -> String? {
            guard let value=account[key],!(value is NSNull) else {return nil}
            guard let text=value as? String,!text.isEmpty,text.utf8.count<=512,!text.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else {throw AppError.message("연결 서버의 계정 표시를 확인하지 못했습니다.")}
            return text
        }
        switch type {
        case "chatgpt":return try .init(provider:"ChatGPT",email:text("email"),plan:text("planType"))
        case "apiKey":return .init(provider:"API 키")
        case "amazonBedrock":return .init(provider:"Amazon Bedrock")
        default:throw AppError.message("이 연결 서버의 계정 종류는 아직 표시할 수 없습니다.")
        }
    }
    static func read(home:String) async throws -> (Self,Int32) {
        try await Task.detached(priority:.utility) {
            try Task.checkCancellation()
            let connection=try CodexQueueConnection(home:home)
            let server=try connection.peerProcessID()
            let identity=try decode(connection.request("account/read",["refreshToken":false]))
            try Task.checkCancellation()
            return (identity,server)
        }.value
    }
}

public struct CodexSessionAccount: Equatable, Sendable {
    public var sessionID:String
    public var target:CodexAccountTransitionTarget
    public var identity:CodexServerAccountIdentity
    public var sharedSessions:Int
    public init(sessionID:String,target:CodexAccountTransitionTarget,identity:CodexServerAccountIdentity,sharedSessions:Int) {
        self.sessionID=sessionID;self.target=target;self.identity=identity;self.sharedSessions=sharedSessions
    }
    public var individual:Bool {sharedSessions==1}
}
