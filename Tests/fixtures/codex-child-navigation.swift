import Foundation
@testable import AutoApproveCore

// Only the owned PTY harness supplies frames and receives keys. No host UI is accessed.
private func bridge(_ object: [String: Any]) throws -> [String: Any] {
    let data = try JSONSerialization.data(withJSONObject: object)
    FileHandle.standardOutput.write(data + Data([10]))
    guard let line = readLine(), let reply = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
        throw AppError.message("Owned PTY bridge closed")
    }
    if let error = reply["error"] as? String { throw AppError.message(error) }
    return reply
}
@main struct ChildNavigationFixture {
    static func main() async throws {
        let target = ScreenTarget(tty: "/dev/owned-fixture")
        let adapter = ScreenHostAdapter(screens: { _ in
            let raw = try bridge(["method": "read"])["screen"] as! String
            return TerminalSnapshot(screens: [.init(tty: target.tty, contents: raw)])
        }, approve: { _, expected, _ in
            let result = try bridge(["method": "approve", "expected": expected])
            return TerminalDelivery(rawValue: result["delivery"] as! String)!
        }, reveal: { _ in nil }, input: { _, expected, _, input in
            let result = try bridge(["method": "input", "expected": expected, "kind": input.kind.rawValue, "bytes": input.bytes])
            return TerminalDelivery(rawValue: result["delivery"] as! String)!
        })
        let initial = try bridge(["method": "read"])["screen"] as! String
        let result = try await CodexChildApprovalNavigation.approve(target: target, initial: initial,
            parentThreadID: CommandLine.arguments[1], adapter: adapter, valid: { true })
        _ = try bridge(["method": "result", "delivery": result.delivery.rawValue, "approved": result.approved])
    }
}
