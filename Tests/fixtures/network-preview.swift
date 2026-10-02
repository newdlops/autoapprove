// Isolated real HTTP/Bonjour servers with synthetic processes and terminal transports.
// Never reads or sends input to a user's terminal.
import Foundation
import Darwin
import AutoApproveCore

private final class PreviewScreens: @unchecked Sendable {
    private let lock = NSLock()
    var screens: [String: String] = [:]
    func read(_ tty: String) -> String { lock.lock(); defer { lock.unlock() }; return screens[tty] ?? "" }
    func input(_ target: ScreenTarget, _ expected: String, _ input: RemoteTerminalInput) -> TerminalDelivery {
        lock.lock(); defer { lock.unlock() }
        guard screens[target.tty] == expected else { return .screenChanged }
        screens[target.tty, default: ""] += "\n[검증용 입력] " + (input.kind == .text ? input.text : input.kind.rawValue)
        return .sent
    }
}

@main struct RemotePreview {
    static func fixtureAppearance(_ screen: String) -> TerminalAppearance {
        // Explicit synthetic cell attributes, not production keyword highlighting.
        let text = screen as NSString
        let samples: [(String, String, String?, Bool, Bool)] = [
            ("$ pnpm test", "#87d7ff", nil, true, false),
            ("✓ 12 checks passed · 합성 출력", "#d97757", nil, true, false),
            ("warning: 재연결 상태 검증 예시", "#b1b9f9", nil, false, true),
            ("error: 오류 강조 검증 예시", "#87d7ff", "#303030", false, false),
            ("+ 갱신 후", "#a6e3a1", nil, false, false),
            ("- 갱신 전", "#f38ba8", nil, false, false)]
        let runs = samples.compactMap { sample -> TerminalAppearance.Run? in
            let range = text.range(of: sample.0)
            guard range.location != NSNotFound else { return nil }
            return .init(offset: range.location, length: range.length, fg: sample.1, bg: sample.2,
                         bold: sample.3 ? true : nil, underline: sample.4 ? true : nil)
        }.sorted { $0.offset < $1.offset }
        return TerminalAppearance(runs: runs)
    }
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let label = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "A"
        let directOnly = CommandLine.arguments.contains("--direct-only")
        let state = PreviewScreens()
        let records = ProcessDiscovery.parse((0..<6).map { index in
            "\(82000 + index) 1 ttys0\(80 + index) \(82000 + index) \(82000 + index) Mon Sep 21 09:00:0\(index) 2026 /usr/local/bin/codex"
        }.joined(separator: "\n"))
        let transport = CodexReplyTransport(prepare: { _, question in CodexReplyTarget(executable: "/fixture/codex", home: directory.path, threadID: question.threadID) }, send: { _, _ in UUID().uuidString })
        let adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map {
            TerminalScreen(tty: $0.tty, contents: state.read($0.tty), title: "검증용 \(label) · " + $0.tty,
                appearance: Self.fixtureAppearance(state.read($0.tty)))
        }) }, approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, input: { target, expected, _, input in state.input(target, expected, input) })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), questionTransport: transport,
            claudeRegistryReader: { _ in [] }, processReader: { records }, screenAdapters: [.terminal: adapter])
        try engine.start(poll: false)
        var sessions = ProcessDiscovery.sessions(records)
        sessions[0].id += "+한글 검증"
        for index in sessions.indices {
            sessions[index].terminal = .terminal
            sessions[index].cwd = "/Users/qa/projects/" + ["autoapprove", "결제-서비스", "아주-긴-프로젝트-이름-네트워크-협력-터미널-화면-검증", "api-server", "문서-정리", "배포-작업"][index]
            state.screens[sessions[index].tty] = "AutoApprove 웹 검증 · 합성 데이터 · \(label)\n\n프로젝트: \(sessions[index].cwd)\n브랜치: feature/network-sessions\n\n✓ 연결된 터미널의 현재 화면\n실제 사용자 터미널에 입력하지 않습니다.\n\n$ pnpm test\n✓ 12 checks passed · 합성 출력\nwarning: 재연결 상태 검증 예시\nerror: 오류 강조 검증 예시\n@@ -1,2 +1,2 @@\n- 갱신 전\n+ 갱신 후\n<img src=x onerror=alert(1)> · 문자로만 표시\n\n› \n? for shortcuts"
        }
        engine.updateDiscovery(sessions, records: records); await engine.connectTerminal()
        for index in sessions.indices {
            try engine.setCustomization(sessions[index].id, value: SessionCustomization(title: index == 2 ? "긴 표시 이름과 여러 단어가 있는 터미널 · 좁은 휴대폰 화면에서도 전체 이름을 확인합니다" : "검증용 \(label) · " + ["웹 관리 구현", "질문 응답 대기", "긴 텍스트 검증", "API 회귀 검사", "문서 정리", "배포 준비"][index]))
        }
        try engine.setAutomatic(sessions[3].id, enabled: true)
        engine.updateGitBranches(sessions.map { GitBranchUpdate(sessionID: $0.id, cwd: $0.cwd, state: .init(kind: .branch, name: "feature/network-sessions")) })
        let question = QueuedQuestion(id: "fixture-question-" + label, threadID: UUID().uuidString, title: "어떤 환경에서 네트워크 연결을 확인할까요? 검증용 질문이며 실제 작업에는 영향을 주지 않습니다.", options: ["개인 핫스팟에서 확인", "같은 Wi-Fi에서 확인", "긴 선택지의 줄바꿈과 선택 영역이 작은 휴대폰 화면에서도 유지되는지 확인"])
        engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: sessions[1].id, questions: [question], threadID: question.threadID)])
        let nodeIDFile = directory.appendingPathComponent("preview-node-id")
        let nodeID = (try? String(contentsOf: nodeIDFile, encoding: .utf8)) ?? UUID().uuidString
        try nodeID.write(to: nodeIDFile, atomically: true, encoding: .utf8)
        var status = RemoteNetworkStatus()
        let web = RemoteNetworkService(engine: engine, nodeID: nodeID, name: "QA Mac \(label) · 검증용", bonjourEnabled: !directOnly, discoveryAddresses: {
            // Test only these isolated endpoints, never scan the user's actual LAN.
            guard directOnly, let data = try? Data(contentsOf: directory.deletingLastPathComponent().appendingPathComponent("direct-peers.json")) else { return [] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }, onStatus: { status = $0 })
        if directOnly { web.directDiscoveryInterval = 1 }
        try web.start(port: 0)
        for _ in 0..<100 {
            if status.ready { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard status.ready, let port = status.port else { throw AppError.message("검증용 웹 서버 포트를 열지 못했습니다: " + status.detail) }
        for _ in 0..<100 {
            if directOnly || status.urls.contains(where: { URL(string: $0)?.host?.hasPrefix("autoapprove-") == true }) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let info: JSONObject = ["id": nodeID, "name": "QA Mac \(label) · 검증용", "url": "http://127.0.0.1:\(port)",
                                "namedURL": status.urls.first(where: { URL(string: $0)?.host?.hasPrefix("autoapprove-") == true }) ?? ""]
        print(String(decoding: try JSONSerialization.data(withJSONObject: info), as: UTF8.self)); fflush(stdout)
        while !Task.isCancelled { try await Task.sleep(nanoseconds: 1_000_000_000) }
        web.stop(); engine.stop()
    }
}
