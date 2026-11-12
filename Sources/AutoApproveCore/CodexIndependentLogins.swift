import Foundation

public struct CodexStandaloneSession:Equatable,Identifiable,Sendable {
    public let sessionID:String,home:String,executable:String,project:String,started:String,tty:String
    public let pid:Int32
    public var id:String {sessionID}
    init(session:AgentSession,home:String,executable:String) {
        sessionID=session.id;self.home=home;self.executable=executable;project=session.project
        started=session.started;tty=session.tty;pid=session.pid
    }
}

/// A per-session login home, deliberately absent from the shared group picker.
public struct CodexIndependentLogin:Equatable,Identifiable,Sendable {
    public let id:UUID,name:String,home:String,homeIdentity:String,createdAt:Date
    init(_ value:CodexLoginGroup) {
        id=value.id;name=value.name;home=value.home;homeIdentity=value.homeIdentity;createdAt=value.createdAt
    }
}

/// Reuses the private, identity-checked home registry without enrolling a
/// detached account as a shared login group. Creation never copies credentials.
struct CodexIndependentLoginStore:Sendable {
    let directory:URL
    private var homes:CodexLoginGroupStore {.init(directory:directory)}
    func list()throws->[CodexIndependentLogin] {try homes.list().map(CodexIndependentLogin.init)}
    func create(name:String)throws->CodexIndependentLogin {
        .init(try homes.create(name:name,daemonAutoStart:false))
    }
    func validate(home:String)throws {try homes.validate(home:home)}
    func contains(home:String)throws->Bool {
        let selected=try CodexAccountTransitionTarget.canonicalHome(home)
        return try list().contains{try CodexAccountTransitionTarget.canonicalHome($0.home)==selected}
    }
}
