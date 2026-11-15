import Foundation
import AutoApproveCore

private final class UpdateRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var total: Int { lock.lock(); defer { lock.unlock() }; return count }
    func received() { lock.lock(); defer { lock.unlock() }; count += 1 }
}

extension ApprovalTests {
    @MainActor func testGitHubAppUpdatePreferencesAndChecks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("github-updates-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let requests = UpdateRequests()
        let services = PublishedUpdateServices { request, _ in
            requests.received()
            try expectEqual(request.url?.absoluteString, "https://api.github.com/repos/newdlops/autoapprove/releases/latest")
            return PublishedUpdateReply(status: 200, body: Data(#"{"draft":false,"prerelease":false,"tag_name":"v0.0.1","assets":[]}"#.utf8))
        }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [] }, publishedUpdateServices: services)
        defer { engine.stop() }
        try expect(engine.appUpdates.automatic)
        try engine.appUpdates.setAutomatic(false)
        try expectEqual(requests.total, 0, "Turning automatic updates off must not contact GitHub")
        await engine.appUpdates.check()
        try expectEqual(engine.appUpdates.status.latestVersion, "0.0.1")
        try expectEqual(engine.appUpdates.status.canSync, false)
        await engine.appUpdates.check()
        try expectEqual(requests.total, 1, "Repeated checks share the release cache")
        let reopened = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [] }, publishedUpdateServices: services)
        defer { reopened.stop() }
        try expectEqual(reopened.appUpdates.automatic, false, "The user's opt-out survives an app restart")
        try reopened.setNetworkIsolation(true)
        await reopened.appUpdates.check()
        try expectEqual(requests.total, 1, "Network isolation prevents GitHub requests")
        try expectEqual(reopened.appUpdates.status.phase, "paused")

        let failure = try ApprovalEngine(paths: AppPaths(directory: directory.appendingPathComponent("failure")), processReader: { [] },
            publishedUpdateServices: PublishedUpdateServices { _, _ in PublishedUpdateReply(status: 503, body: Data()) })
        defer { failure.stop() }
        try failure.appUpdates.setAutomatic(false)
        await failure.appUpdates.check()
        try expectEqual(failure.appUpdates.status.phase, "failed")
        try expectNil(failure.appUpdates.status.latest)
    }
}
