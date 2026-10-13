import Foundation

/// A local approval guard, not a claim to understand arbitrary executable code.
public struct SystemCommandRisk: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case persistence, security, settings, privileged }
    public var kind: Kind
    public var evidence: String
    public var title: String {
        switch kind {
        case .persistence: return "시스템 자동 실행 변경"
        case .security: return "보안·접근 권한 변경"
        case .settings: return "시스템 설정·파일 변경"
        case .privileged: return "관리자 권한 실행"
        }
    }
    public var detail: String { title + " 요청을 감지했습니다. 이 변경을 승인하는 대신 같은 대화에 안전한 대안을 안내합니다." }
    public var alternative: String {
        "이미 실행 중인 프로그램의 타이머나 프로젝트 안에서 명시적으로 실행하는 작업으로 목적을 달성합니다. 시스템 자동 실행 등록과 보안 설정 변경은 하지 않습니다."
    }
    /// A denial explains how to continue; it never asks the agent to bypass an OS,
    /// endpoint-security, sandbox or corporate-network restriction.
    public var guidance: String {
        "이 시스템 변경은 실행하지 마세요. 원래 목표는 멈추지 말고 안전한 방법으로 계속 진행하세요. LaunchAgent·LaunchDaemon·cron 등 자동 실행 등록, 시스템 경로 수정, 관리자 권한 상승, 보안 도구·권한·VPN 정책 변경이나 우회는 하지 마세요. 예약·반복 작업은 이미 실행 중인 프로그램의 타이머 또는 프로젝트 내부에서 명시적으로 실행하는 작업으로 구현하고, 별도 상주 서비스는 만들지 마세요. 안전하게 가능한 작업부터 계속하고 제한과 대안을 보고하세요."
    }
    public func denial(event: String) -> JSONObject {
        Self.denial(event: event, message: title + " 요청을 AutoApprove가 거절했습니다. " + guidance)
    }
    static func denial(event: String, message: String) -> JSONObject {
        let output: JSONObject = event == "PreToolUse"
            ? ["hookEventName": event, "permissionDecision": "deny", "permissionDecisionReason": message]
            : ["hookEventName": event, "decision": ["behavior": "deny", "message": message, "interrupt": false]]
        return ["hookSpecificOutput": output]
    }

    public static func detect(_ text: String, cwd: String = "") -> SystemCommandRisk? {
        let text = text.precomposedStringWithCanonicalMapping
        let command = commandText(text)
        // Only complete, simple read-only commands get this exception. Compound
        // shell input still goes through all mutation checks.
        if isReadOnly(command) { return nil }
        if matches(command, #"(?i)\blaunchctl\s+(?:bootstrap|bootout|load|unload|enable|disable|kickstart|submit|setenv|unsetenv|config)\b|\bcrontab\s+|\b(?:systemctl|service)\s+(?:enable|disable|start|stop|restart)\b"#) {
            return Self(kind: .persistence, evidence: "자동 실행 서비스 등록·해제 또는 실행 제어")
        }
        let protectedStartup = #"(?i)(?:(?:~|\$(?:HOME|\{HOME\}))[/\\]+Library[/\\]+(?:LaunchAgents|LaunchDaemons|StartupItems|PrivilegedHelperTools)|(?:^|[\s\"'=])(?:/Users/[^/\r\n]+)?/Library/(?:LaunchAgents|LaunchDaemons|StartupItems|PrivilegedHelperTools)|(?:^|[\s\"'=])/etc/(?:cron|systemd)|(?:~|\$(?:HOME|\{HOME\}))[/\\]+\.config[/\\]+autostart)"#
        let write = #"(?i)\b(?:cp|mv|rm|install|tee|touch|mkdir|chmod|chown|ln|write_bytes|write_text|writeFile|copyFile|copyfile|copy2|copy|replace|rename|unlink|remove)\b|>>?|--install|--register|등록|설치|생성|수정|삭제"#
        let compact = text.filter { !$0.isWhitespace }
        let wrapped = text.replacingOccurrences(of: #"\n[ \t]*"#, with: "", options: .regularExpression)
        let computedHome = matches(command, #"(?i)(?:python[\w/.-]*|node|ruby|osascript)\s+(?:-[ce]|--eval)\b"#)
            && matches(command, #"Path\.home\(|NSHomeDirectory\(|expanduser\(|(?:HOME|home_dir|homeDirectory)"#)
            && matches(command, #"LaunchAgents|LaunchDaemons|PrivilegedHelperTools"#)
        if (computedHome || matches(text, protectedStartup) || matches(wrapped, protectedStartup) || matches(compact, protectedStartup)), (matches(text, write) || matches(compact, #"--install|--register|write_bytes|write_text|writeFile|copyFile|등록|설치|생성|수정|삭제"#)) {
            return Self(kind: .persistence, evidence: "자동 실행 항목 또는 관리자 입력 서비스 경로 변경")
        }
        if matches(text, #"(?i)\b(?:spctl|csrutil|tccutil)\s+(?:(?:authenticated-root)\s+)?(?:--master-disable|--global-disable|disable|reset)\b|\b(?:security|dscl)\s+(?:add-|delete-|authorizationdb|create|passwd)|\bchmod\s+(?:-\S+\s+)*(?:777|666)\b|with\s+administrator\s+privileges"#) {
            return Self(kind: .security, evidence: "보안 제어·계정·접근 권한 또는 관리자 승인 변경")
        }
        if matches(command, #"(?i)(?:^|[\s;&|])(?:/usr/bin/|/bin/)?sudo\b"#) {
            return Self(kind: .privileged, evidence: "sudo를 통한 관리자 권한 명령")
        }
        if matches(command, #"(?i)\b(?:defaults\s+(?:write|delete)\b|pmset\s+-[abcu](?:\s|$)|networksetup\s+-set[A-Za-z]+|systemsetup\s+-set[A-Za-z]+)"#) ||
            (matches(text, #"(?:^|[\s\"'=])(?:(?:/private)?/etc/|/System/|/Library/(?:Preferences|Security)/)"#) && matches(command, write)) {
            return Self(kind: .settings, evidence: "Mac 전역 설정 또는 시스템 파일 쓰기")
        }
        // Script filenames hide the operation from the terminal permission text.
        // Inspect a bounded local installer source without running it. Restrict
        // this to explicit installation flags and a file within the request's cwd.
        if matches(command, #"(?i)--(?:install|register)|\binstall_[^\s]+\.py\b"#),
           let script = localScript(command, cwd: cwd),
           (matches(script, protectedStartup) || (matches(script, #"Path\.home\(|NSHomeDirectory\(|expanduser\(|(?:HOME|home_dir|homeDirectory)"#) && matches(script, #"LaunchAgents|LaunchDaemons|PrivilegedHelperTools|\.config/autostart"#))),
           matches(script, write) {
            return Self(kind: .persistence, evidence: "설치 스크립트가 시스템 자동 실행 경로를 변경합니다")
        }
        return nil
    }

    public static func detect(tool: String, input: JSONObject, summary: String = "", cwd: String = "") -> SystemCommandRisk? {
        if ["Read", "Glob", "Grep", "LS"].contains(tool) { return nil }
        if let command = input["command"] as? String {
            if isReadOnly(command) { return nil }
            return detect(command + (summary.isEmpty ? "" : "\n" + summary), cwd: cwd)
        }
        // File-edit hooks name the destination. Source code containing a system
        // path is not itself a write to that system path.
        if ["Write", "Edit", "MultiEdit"].contains(tool), let path = input["file_path"] as? String ?? input["path"] as? String {
            return detect("write_text " + path, cwd: cwd)
        }
        let encoded = (try? JSONSerialization.data(withJSONObject: input, options: [.withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        let operation = ["Write", "Edit", "MultiEdit"].contains(tool) ? "write_text " : ""
        return detect(operation + encoded + "\n" + summary, cwd: cwd)
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
    private static func commandText(_ text: String) -> String {
        let rows = text.components(separatedBy: .newlines)
        if let first = rows.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("$ ") }) {
            return rows[first...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).dropFirst(2).description
        }
        return text
    }
    private static func isReadOnly(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !matches(value, #"[;&|`\n\r]|\$\(|[<>]"#) else { return false }
        return matches(value, #"^(?:(?:/usr/bin/|/bin/)?(?:cat|stat|ls|head|tail)\s+|(?:/usr/bin/)?plutil\s+-(?:p|lint)\s+|(?:/bin/)?launchctl\s+(?:print|list|help)\b|(?:/usr/bin/)?(?:crontab\s+-l\b|defaults\s+read|pmset\s+-g|networksetup\s+-get|systemsetup\s+-get))"#)
    }
    private static func localScript(_ command: String, cwd: String) -> String? {
        let command = command.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        guard !cwd.isEmpty, let range = command.range(of: #"(?:[A-Za-z0-9_./-]+\.(?:py|sh|mjs|js))(?=\s|['\"]|$)"#, options: .regularExpression) else { return nil }
        let path = String(command[range]), base = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL
        let file = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(base.path + "/"), let stream = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? stream.close() }
        guard let bytes = try? stream.read(upToCount: 131_073), bytes.count <= 131_072 else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
}
