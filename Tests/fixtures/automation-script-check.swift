import Foundation
import Darwin
import AutoApproveCore

@main struct AutomationScriptCheck {
    static func main() throws {
        let decomposed = "한글 e\u{301} 🧪 \"literal\" $() `quoted`\n"
        let text = String(repeating: decomposed, count: 12_000)
        let literal = String(decoding: try JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]), as: UTF8.self)
        let body = "(() => " + literal + ")()"
        for _ in 0..<4 {
            let result = try AutomationScript.run(body, app: "합성 검사", denied: .permissionDenied)
            precondition(result.utf8.elementsEqual(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8), "Standard input must preserve complete decomposed script text beyond argv limits")
        }
        do {
            _ = try AutomationScript.run("throw new Error('-1743')", app: "합성 검사", denied: .permissionDenied)
            preconditionFailure("Permission denial was lost")
        } catch TerminalAdapterError.permissionDenied {}
        do {
            _ = try AutomationScript.run("throw new Error('합성 실패')", app: "합성 검사", denied: .permissionDenied)
            preconditionFailure("Script failure was ignored")
        } catch { precondition(error.localizedDescription.contains("합성 실패")) }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-owned-timeout-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = directory.appendingPathComponent("worker.sh")
        let pidFile = directory.appendingPathComponent("pid")
        // Builtins only: no descendants whose pipe inheritance could affect this test.
        try Data("trap '' TERM\nprintf '%s' \"$$\" > \"$1\"\nwhile :; do :; done\n".utf8).write(to: worker)
        let began = ProcessInfo.processInfo.systemUptime
        do {
            _ = try CommandRunner.run("/bin/sh", [worker.path, pidFile.path], timeout: 2)
            preconditionFailure("A SIGTERM-ignoring owned helper must time out")
        } catch { precondition(error.localizedDescription.contains("초과")) }
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
        precondition(Darwin.kill(pid, 0) == -1 && errno == ESRCH, "The owned timed-out child must be reaped")
        precondition(elapsed < 3.5, "Teardown must remain bounded after the two-second timeout")
        print("{\"repeatedLargeScripts\":4,\"scriptBytes\":\(body.utf8.count),\"unicodeBytesPreserved\":true,\"permissionAndFailurePreserved\":true,\"ownedIgnoringSIGTERMReaped\":true,\"timeoutSeconds\":\(elapsed),\"terminalInputs\":0}")
    }
}
