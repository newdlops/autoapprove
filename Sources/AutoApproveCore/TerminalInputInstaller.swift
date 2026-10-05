import Foundation
import Security
import ServiceManagement
import TerminalInputSupport

/// Explicit Mac setup. Remote reads and input never register or install a service.
public enum TerminalInputInstaller {
    public static let plistName = TTYInputConfiguration.service + ".plist"
    public static let bundleProgram = "Contents/MacOS/" + TTYInputConfiguration.helperName

    public enum RegistrationState: Equatable, Sendable {
        case notRegistered, enabled, requiresApproval, missingBundle
    }
    public enum Result: Equatable, Sendable {
        case alreadyConnected, registered, requiresApproval
        public var message: String {
            switch self {
            case .alreadyConnected: return "기존 직접 입력 연결을 확인했습니다. 같은 원본 터미널을 계속 사용합니다."
            case .registered: return "직접 입력 서비스를 등록했습니다. 연결 상태를 확인하고 있습니다."
            case .requiresApproval: return "시스템 설정 → 일반 → 로그인 항목 및 확장 프로그램에서 AutoApprove의 백그라운드 실행을 허용해주세요."
            }
        }
    }

    public struct Environment: Sendable {
        var validate: @Sendable (URL, String) throws -> Void
        var connected: @Sendable () -> Bool
        var legacyInstalled: @Sendable () -> Bool
        var state: @Sendable () -> RegistrationState
        var registrationPolicy: @Sendable (URL, String) throws -> Void
        var register: @Sendable () throws -> Void
        var refresh: @Sendable () -> Void
        static var live: Self {
            .init(validate: { try validatePackage($0, $1) }, connected: { TerminalInputClient.shared.refreshNow().available },
                legacyInstalled: { FileManager.default.fileExists(atPath: TTYInputConfiguration.helperPath)
                    || FileManager.default.fileExists(atPath: TTYInputConfiguration.plistPath) },
                state: { registrationState }, registrationPolicy: { try validateRegistrationPolicy($0, $1) },
                register: { try SMAppService.daemon(plistName: plistName).register() },
                refresh: { TerminalInputClient.shared.refreshIfNeeded(force: true) })
        }
    }

    public static var registrationState: RegistrationState {
        guard Bundle.main.bundleIdentifier == TTYInputConfiguration.appIdentifier,
              FileManager.default.fileExists(atPath: Bundle.main.bundleURL
                .appendingPathComponent("Contents/Library/LaunchDaemons/" + plistName).path) else { return .missingBundle }
        switch SMAppService.daemon(plistName: plistName).status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .missingBundle
        @unknown default: return .missingBundle
        }
    }

    public static func prepare(app: URL, ownIdentifier: String = TTYInputConfiguration.appIdentifier) throws -> String {
        try validatePackage(app, ownIdentifier)
        let plan: [String: Any] = ["registration": "SMAppService", "application": app.path,
            "plist": "Contents/Library/LaunchDaemons/" + plistName,
            "program": bundleProgram, "approval": "macOS Login Items", "administratorShell": false]
        return String(decoding: try JSONSerialization.data(withJSONObject: plan, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }

    @discardableResult public static func install(app: URL = Bundle.main.bundleURL,
        ownIdentifier: String = TTYInputConfiguration.appIdentifier) throws -> Result {
        try install(app: app, ownIdentifier: ownIdentifier, environment: .live)
    }

    static func install(app: URL, ownIdentifier: String, environment: Environment) throws -> Result {
        try environment.validate(app, ownIdentifier)
        // Reuse a healthy signed service, including the existing legacy service.
        // Never stop it, replace its files, or request administrator privileges here.
        if environment.connected() { return .alreadyConnected }
        switch environment.state() {
        case .requiresApproval: return .requiresApproval
        case .enabled:
            environment.refresh()
            return .registered
        case .notRegistered, .missingBundle: break
        }
        guard !environment.legacyInstalled() else {
            throw AppError.message("기존 직접 입력 서비스에 연결하지 못했습니다. 서비스의 서명과 실행 상태를 확인해야 합니다. Mac 연결 설정에서 연결을 다시 확인해주세요.")
        }
        guard environment.state() != .missingBundle else {
            throw AppError.message("새 직접 입력 연결은 패키징된 AutoApprove 앱의 연결 설정에서 등록해주세요.")
        }
        try environment.registrationPolicy(app, ownIdentifier)
        try environment.register()
        let next = environment.state()
        environment.refresh()
        switch next {
        case .requiresApproval: return .requiresApproval
        case .enabled: return .registered
        case .notRegistered, .missingBundle:
            throw AppError.message("macOS에서 직접 입력 서비스 등록을 확인하지 못했습니다. 공증된 설치본과 로그인 항목 설정을 확인해주세요.")
        }
    }

    public static func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }

    static func validatePlist(_ data: Data) throws {
        guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              Set(values.keys) == Set(["Label", "BundleProgram", "MachServices", "UserName", "RunAtLoad", "KeepAlive", "ThrottleInterval"]),
              values["Label"] as? String == TTYInputConfiguration.service,
              values["BundleProgram"] as? String == bundleProgram,
              values["MachServices"] as? [String: Bool] == [TTYInputConfiguration.service: true],
              values["UserName"] as? String == "root",
              values["RunAtLoad"] as? Bool == true,
              values["KeepAlive"] as? [String: Bool] == ["SuccessfulExit": false],
              values["ThrottleInterval"] as? Int == 10 else {
            throw AppError.message("앱에 포함된 직접 입력 서비스 등록 정보가 올바르지 않습니다.")
        }
    }

    private static func validatePackage(_ app: URL, _ ownIdentifier: String) throws {
        guard [TTYInputConfiguration.appIdentifier, TTYInputConfiguration.cliIdentifier].contains(ownIdentifier),
              Bundle(url: app)?.bundleIdentifier == TTYInputConfiguration.appIdentifier else {
            throw AppError.message("패키징된 AutoApprove 설치본에서 직접 입력 연결을 설정해주세요.")
        }
        let source = app.appendingPathComponent(bundleProgram)
        guard FileManager.default.isExecutableFile(atPath: source.path) else {
            throw AppError.message("앱의 직접 입력 보조 도구가 없습니다. 최신 설치본이 필요합니다.")
        }
        try validatePlist(Data(contentsOf: app.appendingPathComponent("Contents/Library/LaunchDaemons/" + plistName)))
        let requirement = try TTYInputSigning.peerRequirement(ownIdentifier: ownIdentifier, peerIdentifier: TTYInputConfiguration.helperIdentifier)
        try checkSignature(source, requirement: requirement, nested: false)
    }

    private static func validateRegistrationPolicy(_ app: URL, _ ownIdentifier: String) throws {
        guard ownIdentifier == TTYInputConfiguration.appIdentifier,
              Bundle.main.bundleURL.resolvingSymlinksInPath() == app.resolvingSymlinksInPath() else {
            throw AppError.message("새 직접 입력 연결은 AutoApprove 앱의 연결 설정에서 등록해주세요.")
        }
        // Apple requires notarized apps for SMAppService LaunchDaemons. Verify the
        // Developer ID chain locally; ServiceManagement enforces notarization and
        // administrator approval during registration.
        let requirement = "identifier \"\(TTYInputConfiguration.appIdentifier)\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        do { try checkSignature(app, requirement: requirement, nested: true) }
        catch { throw AppError.message("새 직접 입력 서비스 등록에는 Developer ID로 서명하고 Apple 공증을 받은 AutoApprove 설치본이 필요합니다. 현재 연결된 원본 세션은 유지됩니다.") }
    }

    private static func checkSignature(_ url: URL, requirement text: String, nested: Bool) throws {
        var code: SecStaticCode?, requirement: SecRequirement?
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | (nested ? kSecCSCheckNestedCode : 0))
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw AppError.message("직접 입력 서비스의 발행자 서명과 파일 무결성을 확인하지 못했습니다.")
        }
    }
}
