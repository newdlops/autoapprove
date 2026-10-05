import Foundation
import Darwin

public struct QuestionReply: Codable, Equatable {
    public enum Phase: String, Codable { case sending, queued, failed, uncertain, cancelled }
    public var phase: Phase
    public var answer: String
    public var message: String
    public var queueID: String?
    public var canRetry: Bool { phase == .failed || phase == .cancelled }
    public init(phase: Phase, answer: String, message: String, queueID: String? = nil) {
        self.phase = phase; self.answer = answer; self.message = message; self.queueID = queueID
    }
}

public struct CodexReplyTarget: Sendable {
    public var executable: String
    public var home: String
    public var threadID: String
    public var automaticReplyUnavailableReason: String?
    public init(executable: String, home: String, threadID: String, automaticReplyUnavailableReason: String? = nil) {
        self.executable = executable; self.home = home; self.threadID = threadID
        self.automaticReplyUnavailableReason = automaticReplyUnavailableReason
    }
}

public struct CodexReplyTransport: Sendable {
    public var prepare: @Sendable (AgentSession, QueuedQuestion) async throws -> CodexReplyTarget
    public var prepareMessage: @Sendable (AgentSession) async throws -> CodexReplyTarget
    public var queueHome: @Sendable (AgentSession) async throws -> CodexReplyTarget
    public var prepareQueue: @Sendable (AgentSession, String) async throws -> CodexReplyTarget
    public var send: @Sendable (CodexReplyTarget, String) async throws -> String
    public init(prepare: @escaping @Sendable (AgentSession, QueuedQuestion) async throws -> CodexReplyTarget,
                send: @escaping @Sendable (CodexReplyTarget, String) async throws -> String,
                prepareMessage: @escaping @Sendable (AgentSession) async throws -> CodexReplyTarget = { try await messageTarget($0) },
                queueHome: (@Sendable (AgentSession) async throws -> CodexReplyTarget)? = nil,
                prepareQueue: (@Sendable (AgentSession, String) async throws -> CodexReplyTarget)? = nil) {
        self.prepare = prepare; self.send = send; self.prepareMessage = prepareMessage
        self.queueHome = queueHome ?? prepareMessage
        self.prepareQueue = prepareQueue ?? { session, thread in
            let target = try await prepareMessage(session)
            guard target.threadID == thread else { throw RemoteHTTPError(409, "Codex 대화가 바뀌었습니다. 현재 목록을 다시 확인해주세요.") }
            return target
        }
    }
    /// An explicitly selected queue conversation is validated through the server.
    /// Its home comes only from this live CLI's own open, user-owned data files.
    public static func selectedQueueTarget(_ session: AgentSession, threadID: String = "") async throws -> CodexReplyTarget {
        try await Task.detached(priority: .utility) {
            guard threadID.isEmpty || UUID(uuidString: threadID) != nil,
                  try ProcessDiscovery.read().contains(where: { $0.key == session.id && $0.agent == .codex && "/dev/" + $0.tty == session.tty }) else {
                throw RemoteHTTPError(409, "Codex 실행이나 대화 선택을 다시 확인해주세요.")
            }
            let files = try CommandRunner.run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(session.pid), "-Fpn"], timeout: 4)
            var homes = Set<String>()
            for path in CodexThreadLocation.openFiles(files.output)[session.pid] ?? [] {
                let url = URL(fileURLWithPath: path)
                // Daemon-backed CLIs keep only the log database open locally.
                guard ["state_5.sqlite", "thread_history_1.sqlite", "queue_1.sqlite", "logs_2.sqlite"].contains(url.lastPathComponent),
                      let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                      attributes[.type] as? FileAttributeType == .typeRegular,
                      (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { continue }
                homes.insert(url.deletingLastPathComponent().resolvingSymlinksInPath().path)
            }
            guard homes.count == 1, let home = homes.first else { throw RemoteHTTPError(409, "이 Codex 실행의 로컬 서버 위치를 확인하지 못했습니다.") }
            var buffer = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(session.pid, &buffer, UInt32(buffer.count)) > 0 else { throw AppError.message("Codex 실행 파일을 찾지 못했습니다.") }
            let executable = String(cString: buffer)
            guard URL(fileURLWithPath: executable).lastPathComponent == "codex", FileManager.default.isExecutableFile(atPath: executable) else { throw AppError.message("Codex 실행을 확인하지 못했습니다.") }
            return CodexReplyTarget(executable: executable, home: home, threadID: threadID)
        }.value
    }
    public static func messageTarget(_ session: AgentSession) async throws -> CodexReplyTarget {
        try await Task.detached(priority: .utility) {
            let records = try ProcessDiscovery.read()
            guard records.contains(where: { $0.key == session.id && $0.agent == .codex && "/dev/" + $0.tty == session.tty }) else {
                throw AppError.message("이 Codex 실행이 종료되었거나 바뀌었습니다.")
            }
            let files = try CommandRunner.run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(session.pid), "-Fpn"], timeout: 4)
            let location = try CodexThreadLocation.locate(paths: CodexThreadLocation.openFiles(files.output)[session.pid] ?? [])
            var buffer = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(session.pid, &buffer, UInt32(buffer.count)) > 0 else { throw AppError.message("Codex 실행 파일을 찾지 못했습니다.") }
            let executable = String(cString: buffer)
            guard URL(fileURLWithPath: executable).lastPathComponent == "codex", FileManager.default.isExecutableFile(atPath: executable) else {
                throw AppError.message("Codex 메시지 대기열을 확인하지 못했습니다.")
            }
            return CodexReplyTarget(executable: executable, home: URL(fileURLWithPath: location.database).deletingLastPathComponent().path, threadID: location.threadID)
        }.value
    }
    public static let live = CodexReplyTransport(prepare: { session, question in
        try await Task.detached(priority: .utility) {
            let records = try ProcessDiscovery.read()
            guard records.contains(where: { $0.key == session.id && $0.agent == .codex && "/dev/" + $0.tty == session.tty }) else {
                throw AppError.message("이 Codex 세션이 종료되었거나 바뀌었습니다. 목록을 새로고침해주세요.")
            }
            let files = try CommandRunner.run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(session.pid), "-Fpn"], timeout: 4)
            let location = try CodexThreadLocation.locate(paths: CodexThreadLocation.openFiles(files.output)[session.pid] ?? [])
            let questions = try CodexHistoryReader().read(location)
            guard location.threadID == question.threadID,
                  let current = questions.first(where: { $0.isSameRequest(as: question) }) else {
                throw AppError.message("질문이 이미 처리됐거나 대화가 바뀌었습니다. 목록을 새로고침해주세요.")
            }
            let automaticReplyUnavailableReason: String?
            if questions.filter({ $0.titleIdentity == question.titleIdentity }).count > 1 {
                automaticReplyUnavailableReason = "같은 문구의 질문이 여러 개여서 자동 응답을 멈췄습니다. 직접 확인해주세요."
            } else if current.hasLaterUserMessage == true {
                automaticReplyUnavailableReason = "질문 이후 사용자 메시지가 있어 자동 응답을 멈췄습니다. 이미 답했는지 확인해주세요."
            } else { automaticReplyUnavailableReason = nil }
            var buffer = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(session.pid, &buffer, UInt32(buffer.count)) > 0 else {
                throw AppError.message("이 세션의 Codex 실행 파일을 찾지 못했습니다. 터미널에서 답해주세요.")
            }
            let executable = String(cString: buffer)
            guard URL(fileURLWithPath: executable).lastPathComponent == "codex",
                  FileManager.default.isExecutableFile(atPath: executable) else {
                throw AppError.message("Codex 응답 경로를 확인하지 못했습니다. 터미널에서 답해주세요.")
            }
            return CodexReplyTarget(executable: executable,
                home: URL(fileURLWithPath: location.database).deletingLastPathComponent().path, threadID: question.threadID,
                automaticReplyUnavailableReason: automaticReplyUnavailableReason)
        }.value
    }, send: { target, message in
        try await Task.detached(priority: .utility) {
            // Arguments are passed directly, never through a shell. Queue only the
            // answer; leave the running turn and terminal composer alone.
            let result = try CommandRunner.run(target.executable,
                ["queue", "--thread", target.threadID, "--message", message], timeout: 12,
                environment: ["CODEX_HOME": target.home])
            return try receipt(output: result.output, status: result.status, threadID: target.threadID)
        }.value
    }, queueHome: { try await selectedQueueTarget($0) }, prepareQueue: { try await selectedQueueTarget($0, threadID: $1) })

    public static func message(question: QueuedQuestion, answer: String) throws -> String {
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw AppError.message("선택지를 고르거나 답변을 입력해주세요.") }
        guard answer.utf8.count <= 32_000, question.title.utf8.count <= 32_000,
              !answer.contains("\0"), !question.title.contains("\0") else { throw AppError.message("답변이 너무 길거나 전송할 수 없는 문자가 있습니다.") }
        let quote = question.title.components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n")
        return quote + "\n\n" + answer
    }

    public static func receipt(output: String, status: Int32, threadID: String) throws -> String {
        let words = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
        guard status == 0, words.count == 6, words[0] == "Queued", words[1] == "message",
              UUID(uuidString: words[2]) != nil, words[3] == "for", words[4] == "thread",
              words[5] == threadID + "." else {
            throw AppError.message("Codex의 접수 결과를 확인하지 못했습니다. 중복 전송을 피하려면 터미널의 메시지 대기열을 확인해주세요.")
        }
        return words[2]
    }
}
