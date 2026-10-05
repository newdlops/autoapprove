import Foundation
import AutoApproveCore

@main struct CodexQueueTransportFixture {
    static func main() async throws {
        let target = CodexReplyTarget(executable: "/unused", home: CommandLine.arguments[1], threadID: CommandLine.arguments[2])
        if CommandLine.arguments.contains("--expect-unavailable") {
            do { _ = try await CodexQueueTransport.live.list(target) }
            catch {
                guard error.localizedDescription.contains("로컬 서버를 찾지 못했습니다") else { throw error }
                print("{\"nonSocketRefused\":true}"); return
            }
            throw AppError.message("A non-socket control link was accepted")
        }
        let list = try await CodexQueueTransport.live.list(target)
        if CommandLine.arguments.contains("--read-only") {
            print("{\"listCount\":\(list.count)}"); return
        }
        let conversations = try await CodexQueueTransport.live.conversations(target, "/fixture")
        try await CodexQueueTransport.live.validate(target, "/fixture")
        var refusedChangedFolder = false
        do { try await CodexQueueTransport.live.validate(target, "/different") }
        catch { refusedChangedFolder = true }
        let deleted = try await CodexQueueTransport.live.delete(target, ["first", "second"])
        let value: JSONObject = ["ids":list.map(\.id), "text":list.first?.text ?? "", "attachments":list.last?.attachments ?? 0,
                                 "removed":deleted.removed, "partialError":deleted.error != nil,
                                 "conversations":conversations.map(\.id), "changedFolderRefused":refusedChangedFolder]
        print(String(decoding:try JSONSerialization.data(withJSONObject:value,options:.sortedKeys),as:UTF8.self))
    }
}
