import Foundation

package enum ClaudeMCPRegistration {
    package static func repair(executable: String, cwd: String, environment: [String: String],
                               relay: String? = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("autoapprove").path) throws {
        guard cwd.hasPrefix("/") else { throw AppError.message("Claude 프로젝트의 작업 폴더를 확인하지 못했습니다.") }
        var childEnvironment = ProcessInfo.processInfo.environment
        childEnvironment["CLAUDE_CONFIG_DIR"] = environment["CLAUDE_CONFIG_DIR"]
        func run(_ args: [String]) throws -> CommandResult {
            try CommandRunner.run(executable, ["mcp"] + args, timeout: 10, environment: childEnvironment,
                                  inheritEnvironment: false, outputLimit: 65536, errorLimit: 65536, directory: URL(fileURLWithPath: cwd))
        }
        let lookup = try run(["get", "autoapprove"])
        if lookup.status == 0 { return }
        let diagnostic = lookup.error + lookup.output
        guard diagnostic.contains("No MCP server named \"autoapprove\"") || diagnostic.contains("No MCP server found with name: autoapprove") else {
            throw AppError.message("현재 프로젝트의 Claude MCP 등록을 조회하지 못했습니다.")
        }
        guard let relay, FileManager.default.isExecutableFile(atPath: relay) else {
            throw AppError.message("설치된 앱의 AutoApprove MCP 실행 파일을 찾지 못했습니다.")
        }
        _ = try run(["add", "--transport", "stdio", "--scope", "user", "autoapprove", "--", relay, "mcp"])
        guard try run(["get", "autoapprove"]).status == 0 else {
            throw AppError.message("이 Claude 설정 홈에 AutoApprove MCP 서버를 등록하지 못했습니다.")
        }
    }
}
