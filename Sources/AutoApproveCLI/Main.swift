import Foundation
import AutoApproveCore

@main struct AutoApproveCLI {
    static func printJSON(_ object: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
    }
    @MainActor static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        var home: URL?
        if let index = arguments.firstIndex(of: "--home"), arguments.indices.contains(index + 1) {
            home = URL(fileURLWithPath: arguments[index + 1]); arguments.removeSubrange(index...index + 1)
        }
        let paths = AppPaths(directory: home)
        let command = arguments.first ?? "help"
        do {
            switch command {
            case "scan":
                let records = try ProcessDiscovery.read()
                var sessions = ProcessDiscovery.sessions(records)
                let directories = ProcessDiscovery.workingDirectories(pids: sessions.map(\.pid))
                for index in sessions.indices { sessions[index].cwd = directories[sessions[index].pid] ?? "" }
                let data = try JSONEncoder().encode(sessions)
                try printJSON(JSONSerialization.jsonObject(with: data))
            case "doctor":
                let versions: [String: Any] = [
                    "socket": paths.socket,
                    "appRunning": (try? SocketClient.request(path: paths.socket, message: ["method": "status"])) != nil,
                    "claudeHookInstalled": HookInstaller.isInstalled(),
                    "codexSharedSocketExists": FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/app-server-control/app-server-control.sock").path)
                ]
                try printJSON(versions)
            case "status": try printJSON(SocketClient.request(path: paths.socket, message: ["method": "status"]))
            case "pause", "resume": try printJSON(SocketClient.request(path: paths.socket, message: ["method": "pause", "params": ["paused": command == "pause"]]))
            case "enable", "disable":
                guard arguments.count == 2 else { throw AppError.message("세션 ID를 지정해주세요. autoapprove status로 확인할 수 있습니다.") }
                try printJSON(SocketClient.request(path: paths.socket, message: ["method": "automatic", "params": ["sessionID": arguments[1], "enabled": command == "enable"]]))
            case "serve":
                let engine = try ApprovalEngine(paths: paths)
                try engine.start()
                print("AutoApprove bridge: \(paths.socket)")
                while !Task.isCancelled { try await Task.sleep(nanoseconds: 1_000_000_000) }
                engine.stop()
            case "hook":
                do {
                    let input = FileHandle.standardInput.readDataToEndOfFile()
                    guard input.count <= 1_000_000, var payload = try JSONSerialization.jsonObject(with: input) as? JSONObject else { print("{}"); return }
                    if let records = try? ProcessDiscovery.read(), let agent = ProcessDiscovery.ancestors(of: getppid(), records: records).first(where: { $0.agent == .claude }) {
                        payload["agentPID"] = agent.pid; payload["agentStarted"] = agent.started
                        payload["tty"] = agent.tty == "??" ? "" : "/dev/" + agent.tty
                    }
                    let response = ClaudeHookClient.run(payload: payload, path: paths.socket)
                    try printJSON(response)
                } catch { print("{}") } // A missing app or timed-out bridge preserves Claude's original permission flow.
            case "install-claude", "remove-claude":
                let executable = URL(fileURLWithPath: CommandLine.arguments[0], relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardized.path
                let backup = try HookInstaller.install(executable: command == "install-claude" ? executable : nil, home: paths.directory.path)
                print(command == "install-claude" ? "Claude 훅을 설치했습니다. 다음 세션 이벤트에서 연결됩니다." : "AutoApprove 훅만 제거했습니다.")
                if let backup { print("기존 설정 백업: \(backup.path)") }
            default:
                print("""
                AutoApprove — local terminal approval manager

                  autoapprove scan          Claude Code·Codex 세션 탐색 (읽기 전용)
                  autoapprove doctor        연결 상태 확인
                  autoapprove status        앱의 세션 및 승인 내역
                  autoapprove serve         UI 없이 로컬 엔진 실행
                  autoapprove enable ID     연결된 세션 자동 승인 켜기
                  autoapprove disable ID    자동 승인 끄기
                  autoapprove pause         전체 자동 승인 일시정지
                  autoapprove resume        전체 자동 승인 재개
                  autoapprove install-claude Claude 훅 설치 (기존 설정 백업)
                  autoapprove remove-claude  AutoApprove 훅만 제거

                --home PATH로 별도 테스트 데이터 경로를 지정할 수 있습니다.
                """)
            }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
