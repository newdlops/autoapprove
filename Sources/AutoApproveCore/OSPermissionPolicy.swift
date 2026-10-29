import Foundation

public enum OSPermissionKind:String,Codable,CaseIterable,Sendable {
    case automation,accessibility,screenRecording,camera,microphone,files,localNetwork,fullDiskAccess,appManagement,other,authentication
    public static var automaticCases:[Self] {allCases.filter {$0 != .authentication}}
    public var title:String {
        switch self {
        case .automation:return "다른 앱 제어"
        case .accessibility:return "손쉬운 사용·기기 제어"
        case .screenRecording:return "화면 기록"
        case .camera:return "카메라"
        case .microphone:return "마이크"
        case .files:return "파일·폴더 접근"
        case .localNetwork:return "로컬 네트워크"
        case .fullDiskAccess:return "전체 디스크 접근"
        case .appManagement:return "앱 관리"
        case .authentication:return "Mac 사용자 인증"
        case .other:return "기타 OS 접근 권한"
        }
    }
    public static func detect(_ text:String)->Self? {
        let s=text.lowercased()
        let tests:[(Self,[String])] = [
            (.fullDiskAccess,["full disk access","전체 디스크 접근"]),(.appManagement,["app management","앱 관리"]),
            (.screenRecording,["screen recording","record your screen","screen and audio","화면 기록","화면 녹","화면 및 시스템 오디오","화면과 오디오"]),
            (.accessibility,["accessibility","손쉬운 사용","device control and data access","기기 제어"]),
            (.automation,["would like to control","wants to control","wants access to control","제어하려고","제어하도록","제어할 수 있도록"]),
            (.camera,["access the camera","access your camera","카메라에 접근","카메라를 사용"]),
            (.microphone,["access the microphone","access your microphone","마이크에 접근","마이크를 사용"]),
            (.localNetwork,["local network","로컬 네트워크"]),
            (.files,["access files in","documents folder","downloads folder","desktop folder","폴더에 있는 파일","폴더의 파일","파일에 접근"]),
            (.authentication,["administrator","password","touch id","keychain","관리자","암호","키체인"])
        ]
        if let kind=tests.first(where:{$0.1.contains(where:s.contains)})?.0 {return kind}
        if ["would like to access","wants to access","would like to use","wants to use","접근하려고","사용하려고"].contains(where:s.contains) {return .other}
        return nil
    }
}

/// A stable code requirement identifies an app across builds; a display name never grants access.
public struct OSPermissionTarget:Codable,Equatable,Identifiable,Sendable {
    public var id:String
    public var name:String
    public var bundleID:String
    public var path:String
    public var requirement:String
    public var pid:Int32
    public var started:String
    public init(name:String,bundleID:String,path:String,requirement:String,pid:Int32,started:String) {
        self.name=name;self.bundleID=bundleID;self.path=path;self.requirement=requirement;self.pid=pid;self.started=started
        id=PromptDetector.fingerprint(bundleID+"\u{0}"+path+"\u{0}"+requirement)
    }
    public var isSharedController:Bool {
        ["com.apple.Terminal","com.googlecode.iterm2","com.microsoft.VSCode","com.openai.chat","com.openai.codex","local.autoapprove.mac","com.anthropic.claudefordesktop","com.anthropic.claude","com.google.Chrome","com.google.Chrome.canary","org.mozilla.firefox","com.microsoft.edgemac","com.apple.Safari","com.brave.Browser"].contains(bundleID)
        || bundleID.lowercased().contains("computer-use") || bundleID.lowercased().contains("computeruse")
    }
    public func matches(_ other:Self)->Bool {id==other.id && bundleID==other.bundleID && path==other.path && requirement==other.requirement}
}

public struct OSPermissionPolicy:Codable,Equatable,Sendable {
    public var allowed:[OSPermissionKind] = []
    public var targets:[OSPermissionTarget] = []
    public init(allowed:[OSPermissionKind]=[],targets:[OSPermissionTarget]=[]) {self.allowed=Array(Set(allowed)).sorted {$0.rawValue<$1.rawValue};self.targets=targets}
    public var isEnabled:Bool {!allowed.isEmpty}
    public func permits(_ request:OSPermissionRequest)->Bool {
        guard !request.isManagementApp,let target=request.requester else {return false}
        return allowed.contains(request.kind) && targets.contains { $0.matches(target) }
    }
}

struct OSPermissionPolicyEnvelope:Codable {var source:String;var policy:OSPermissionPolicy}

public struct OSPermissionRequest:Codable,Equatable,Identifiable,Sendable {
    public enum Action:String,Codable,Sendable {case allow,openSettings,enableSetting,manual}
    public enum Phase:String,Codable,Sendable {case waiting,approving,submitted,settings,resolved,uncertain}
    public var id:String
    public var kind:OSPermissionKind
    public var requester:OSPermissionTarget?
    public var ownerPID:Int32
    public var ownerStarted:String
    public var ownerBundleID:String
    public var windowToken:String
    public var content:String
    public var action:Action
    public var actionToken:String
    public var sessionID:String?
    /// Host setup is manual and never belongs to a managed CLI session.
    public var managementApp:Bool?
    public var phase:Phase = .waiting
    public var detail:String = "이 요청을 처리할 세션과 권한 정책을 확인해주세요."
    public var observedAt:Date = Date()
    public init(kind:OSPermissionKind,requester:OSPermissionTarget?,ownerPID:Int32,ownerStarted:String,ownerBundleID:String,windowToken:String,content:String,action:Action,actionToken:String) {
        self.kind=kind;self.requester=requester;self.ownerPID=ownerPID;self.ownerStarted=ownerStarted;self.ownerBundleID=ownerBundleID;self.windowToken=windowToken;self.content=content;self.action=action;self.actionToken=actionToken
        managementApp=requester?.pid==ProcessInfo.processInfo.processIdentifier ? true:nil
        id=PromptDetector.fingerprint("\(ownerPID)\u{0}\(ownerStarted)\u{0}\(windowToken)\u{0}\(kind.rawValue)\u{0}\(requester?.id ?? "?")\u{0}\(content)\u{0}\(actionToken)")
    }
    public var isPending:Bool {phase != .resolved}
    public var isManagementApp:Bool {requester?.pid==ProcessInfo.processInfo.processIdentifier}
    public var immutableToken:String {id+"\u{0}"+(requester.map {"\($0.pid):\($0.started):\($0.id)"} ?? "?")}
}

public struct OSPermissionMonitorStatus:Codable,Equatable,Sendable {
    public var available:Bool
    public var detail:String
    public var requests:[OSPermissionRequest]
    public init(available:Bool=false,detail:String="OS 권한 연결을 확인하고 있습니다.",requests:[OSPermissionRequest]=[]) {self.available=available;self.detail=detail;self.requests=requests}
}

public enum OSPermissionDelivery:Equatable,Sendable {case sent,unavailable(String),uncertain(String)}

public enum OSPermissionPrompt {
    /// App-provided usage descriptions cannot override a different OS requester headline.
    public static func headline(_ text:String)->(name:String,kind:OSPermissionKind)? {
        let regex=try! NSRegularExpression(pattern:#"(?m)^[ \t]*[\"“‘「]([^\"”’」\n]{1,200})[\"”’」]([^\n]{1,700})$"#)
        let matches=regex.matches(in:text,range:NSRange(text.startIndex...,in:text)).compactMap {match -> (String,OSPermissionKind)? in
            guard let name=Range(match.range(at:1),in:text),let tail=Range(match.range(at:2),in:text),let kind=OSPermissionKind.detect(String(text[tail])) else {return nil}
            return (String(text[name]),kind)
        }
        let unique=Set(matches.map {$0.0+"\u{0}"+$0.1.rawValue})
        guard unique.count==1,let first=matches.first else {return nil};return (first.0,first.1)
    }
}

public struct OSPermissionServices:Sendable {
    public var scan:@Sendable ([OSPermissionTarget]) throws -> OSPermissionMonitorStatus
    public var approve:@MainActor @Sendable (OSPermissionRequest,@MainActor ()->Bool)->OSPermissionDelivery
    public init(scan:@escaping @Sendable ([OSPermissionTarget]) throws -> OSPermissionMonitorStatus,approve:@escaping @MainActor @Sendable (OSPermissionRequest,@MainActor ()->Bool)->OSPermissionDelivery) {self.scan=scan;self.approve=approve}
    public static let inactive=Self(scan:{_ in .init(available:false,detail:"격리된 실행 환경입니다.")},approve:{_,_ in .unavailable("OS 입력 연결이 없습니다.")})
}
