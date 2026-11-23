import Foundation

/// Rebuilds the command that reopens the same conversation with the options the CLI was started with.
/// Only options whose meaning is known are carried over; prompts and conversation selectors are dropped,
/// and an unknown option stops the restart instead of being guessed.
public enum SessionRestartCommand {
    /// Typed into a restarted session, so work the restart interrupted goes on without the user visiting every tab.
    /// A question that was waiting for the user stays a question: this line is never an approval.
    public static let resumePrompt = "세션을 다시 시작했습니다. 다시 시작하기 전에 진행하던 작업이 있으면 이어서 진행하세요. " +
        "제 답이나 승인을 기다리던 일은 이 입력을 승인으로 보지 말고 다시 물어보세요. 이어갈 작업이 없으면 다른 작업을 하지 말고 '이어갈 작업 없음'이라고만 답하세요."

    public static func installedLauncher(agent: AgentKind, path: String?, runningExecutable: String, userHome: String?) -> String? {
        guard agent != .shell else { return nil }
        func currentCodex(_ candidate: String) -> String? {
            guard agent == .codex, candidate.hasPrefix("/") else { return nil }
            let file = URL(fileURLWithPath: candidate)
            let bin = file.deletingLastPathComponent()
            let releases = bin.deletingLastPathComponent().deletingLastPathComponent()
            let package = releases.deletingLastPathComponent()
            guard file.lastPathComponent == "codex", bin.lastPathComponent == "bin",
                  releases.lastPathComponent == "releases", ["standalone", "app-server-daemon"].contains(package.lastPathComponent),
                  package.deletingLastPathComponent().lastPathComponent == "packages" else { return nil }
            return package.appendingPathComponent("current/bin/codex").path
        }
        var candidates = (path ?? "").split(separator: ":").filter { $0.hasPrefix("/") }.map {
            URL(fileURLWithPath: String($0)).appendingPathComponent(agent.rawValue).path
        }
        if let userHome, userHome.hasPrefix("/") {
            candidates.append(URL(fileURLWithPath: userHome).appendingPathComponent(".local/bin/" + agent.rawValue).path)
        }
        if let current = currentCodex(runningExecutable) { candidates.append(current) }
        for candidate in candidates {
            let file = URL(fileURLWithPath: currentCodex(candidate) ?? candidate)
            guard !file.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  (try? file.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  FileManager.default.isExecutableFile(atPath: file.path) else { continue }
            return file.path
        }
        return nil
    }

    public struct Plan: Equatable {
        public var arguments: [String]
        /// Original arguments that are not passed again, such as an initial prompt.
        public var dropped: [String]
        public var command: String { arguments.map(HookInstaller.quote).joined(separator: " ") }
        /// For a shell that did not start the CLI, such as a new tab: return to the CLI's folder and restore
        /// the configuration home the CLI was started with.
        public func command(cwd: String?, environment: [String: String]) -> String {
            let assignments = ["CLAUDE_CONFIG_DIR", "CODEX_HOME", ClaudePromptBridge.key].compactMap { name in environment[name].map { HookInstaller.quote(name + "=" + $0) } }
            let launch = (assignments.isEmpty ? "" : "env " + assignments.joined(separator: " ") + " ") + command
            guard let cwd, !cwd.isEmpty else { return launch }
            return "cd -- " + HookInstaller.quote(cwd) + " && " + launch
        }
    }

    private struct Rules {
        var value: Set<String>
        var variadic: Set<String> = []
        var flag: Set<String>
        var dropFlag: Set<String> = []
        var dropValue: Set<String> = []
        var dropOptionalValue: Set<String> = []
        var dropVariadic: Set<String> = []
        var refuse: Set<String> = []
    }

    private static let claude = Rules(
        value: ["--model", "--permission-mode", "--settings", "--append-system-prompt", "--system-prompt", "--fallback-model",
                "--agent", "--agents", "--effort", "--setting-sources", "--permission-prompts", "--plugin-dir", "--autocompact",
                "--name", "-n", "--debug-file", "--max-budget-usd", "--system-prompt-snapshot"],
        variadic: ["--add-dir", "--allowedTools", "--allowed-tools", "--disallowedTools", "--disallowed-tools", "--mcp-config", "--tools", "--betas"],
        flag: ["--dangerously-skip-permissions", "--allow-dangerously-skip-permissions", "--verbose", "--ide", "--chrome", "--no-chrome",
               "--strict-mcp-config", "--brief", "--disable-slash-commands", "--safe-mode", "--restricted", "--bare", "--ax-screen-reader",
               "--exclude-dynamic-system-prompt-sections", "--forward-subagent-text"],
        dropFlag: ["-c", "--continue", "--fork-session", "--bg", "--background", "--tmux"],
        dropValue: ["--session-id"],
        dropOptionalValue: ["-r", "--resume", "-w", "--worktree", "--from-pr", "--teleport"],
        dropVariadic: ["--file"],
        refuse: ["-p", "--print", "--desktop", "--cloud", "--environment", "--remote-control", "-d", "--debug"])

    private static let codex = Rules(
        value: ["-c", "--config", "-m", "--model", "-p", "--profile", "-s", "--sandbox", "-a", "--ask-for-approval", "-C", "--cd",
                "--add-dir", "--enable", "--disable", "--local-provider", "--remote", "--remote-auth-token-env"],
        flag: ["--oss", "--search", "--no-alt-screen", "--no-daemon", "--full-auto", "--dangerously-bypass-approvals-and-sandbox",
               "--dangerously-bypass-hook-trust", "--approve-for-me", "--strict-config"],
        dropFlag: ["--last", "--all", "--include-non-interactive", "--worktree"],
        dropVariadic: ["-i", "--image"])

    /// `argv` is the original argument list without the executable path.
    public static func plan(agent: AgentKind, executable: String, argv: [String], conversationID: String) throws -> Plan {
        guard let id = UUID(uuidString: conversationID)?.uuidString.lowercased() else { throw AppError.message("대화 ID를 확인하지 못했습니다.") }
        guard executable.hasPrefix("/"), !executable.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw AppError.message("CLI 실행 파일 경로를 확인하지 못했습니다.")
        }
        if agent == .agy {
            var options: [String] = [], index = 0
            while index < argv.count {
                let token = argv[index]
                index += 1
                if token == "--sandbox" { options.append(token); continue }
                if ["-c", "--continue"].contains(token) { continue }
                let parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(parts.first ?? "")
                guard ["--conversation", "--model", "--effort", "--agent", "--add-dir"].contains(name),
                      parts.count == 2 || index < argv.count else {
                    throw AppError.message("현재 agy 실행 옵션을 보존할 수 없어 자동으로 다시 시작하지 않습니다.")
                }
                let value = parts.count == 2 ? String(parts[1]) : argv[index]
                if parts.count != 2 { index += 1 }
                guard !value.isEmpty, !value.hasPrefix("-"), !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                      name != "--conversation" || UUID(uuidString: value) != nil else {
                    throw AppError.message("agy 실행 옵션 값을 확인하지 못했습니다.")
                }
                if name != "--conversation" { options += [name, value] }
            }
            return Plan(arguments: [executable] + options + ["--conversation", id], dropped: [])
        }
        var tokens = argv
        if agent == .codex, let first = tokens.firstIndex(where: { !$0.hasPrefix("-") }) {
            // A subcommand can only come before any of its own options' values, so check the first bare word
            // after skipping known option values.
            var index = 0, subcommand: Int?
            while index < tokens.count {
                let token = tokens[index], name = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
                if !token.hasPrefix("-") { subcommand = index; break }
                index += codex.value.contains(name) && !token.contains("=") ? 2 : 1
            }
            if let subcommand {
                if tokens[subcommand] == "resume" { tokens.remove(at: subcommand) }
                else if subcommand == first, ["exec", "e", "login", "logout", "mcp", "apply", "a", "cloud", "app-server", "proto", "completion", "debug", "sandbox"].contains(tokens[subcommand]) {
                    throw AppError.message("대화형이 아닌 Codex 명령(\(tokens[subcommand]))은 다시 시작하지 않습니다.")
                }
            }
        }
        let rules = agent == .codex ? codex : claude
        var kept: [String] = [], dropped: [String] = [], index = 0
        func values(from start: Int) -> Int { var end = start; while end < tokens.count, !tokens[end].hasPrefix("-") { end += 1 }; return end }
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" { dropped += tokens[index...]; break }
            guard token.hasPrefix("-"), token.count > 1 else { dropped.append(token); index += 1; continue }
            let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
            let name = parts[0], inline = parts.count == 2
            if rules.refuse.contains(name) { throw AppError.message("다시 시작할 때 그대로 적용할 수 없는 실행 옵션(\(name))이 있습니다.") }
            if rules.flag.contains(name) { kept.append(token); index += 1; continue }
            if rules.dropFlag.contains(name) { dropped.append(token); index += 1; continue }
            if rules.value.contains(name) {
                if inline { kept.append(token); index += 1; continue }
                guard index + 1 < tokens.count else { throw AppError.message("실행 옵션 \(name)의 값을 확인하지 못했습니다.") }
                kept += [token, tokens[index + 1]]; index += 2; continue
            }
            if rules.variadic.contains(name) {
                let end = inline ? index + 1 : values(from: index + 1)
                guard inline || end > index + 1 else { throw AppError.message("실행 옵션 \(name)의 값을 확인하지 못했습니다.") }
                kept += tokens[index..<end]; index = end; continue
            }
            if rules.dropValue.contains(name) { let end = inline ? index + 1 : min(index + 2, tokens.count); dropped += tokens[index..<end]; index = end; continue }
            if rules.dropOptionalValue.contains(name) {
                let end = !inline && index + 1 < tokens.count && !tokens[index + 1].hasPrefix("-") ? index + 2 : index + 1
                dropped += tokens[index..<end]; index = end; continue
            }
            if rules.dropVariadic.contains(name) { let end = inline ? index + 1 : values(from: index + 1); dropped += tokens[index..<end]; index = end; continue }
            throw AppError.message("알 수 없는 실행 옵션(\(name))이 있어 다시 시작하지 않습니다.")
        }
        let arguments = agent == .codex ? [executable, "resume"] + kept + [id] : [executable] + kept + ["--resume", id]
        return Plan(arguments: arguments, dropped: dropped)
    }
}

/// One session in a "restart all sessions" request.
public struct SessionRestartItem: Codable, Equatable, Identifiable {
    public enum Phase: String, Codable {
        /// Waiting until the session is idle with an empty input box.
        case waiting, exiting, launching, confirming, done, failed, cancelled
        public var isFinished: Bool { [.done, .failed, .cancelled].contains(self) }
    }
    public var id: String
    public var title: String
    public var phase: Phase
    public var message: String
    public enum Operation: String, Codable { case restart, resumeWork, recoverMCP, restartForMCP }
    public var operation: Operation?
    public var isMCPRecovery: Bool { operation == .recoverMCP || operation == .restartForMCP }
    public var newSessionID: String?
    public var updatedAt: Date
    public init(id: String, title: String, phase: Phase, message: String, at date: Date = Date()) {
        self.id = id; self.title = title; self.phase = phase; self.message = message; updatedAt = date
    }
}

public struct SessionRestartProgress: Codable, Equatable {
    public var items: [SessionRestartItem]
    public var startedAt: Date
    public init(items: [SessionRestartItem], startedAt: Date = Date()) { self.items = items; self.startedAt = startedAt }
    public var isActive: Bool { items.contains { !$0.phase.isFinished } }
    public func count(_ phase: SessionRestartItem.Phase) -> Int { items.filter { $0.phase == phase }.count }
}
