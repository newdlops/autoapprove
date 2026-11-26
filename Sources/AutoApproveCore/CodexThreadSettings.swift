import Foundation

final class CodexThreadSettingsConnection {
    private var connections: [String: CodexQueueConnection] = [:]
    private var offline = Set<String>()

    func read(home: String, id: String) -> JSONObject? {
        guard !offline.contains(home) else { return nil }
        do {
            let connection: CodexQueueConnection
            if let existing = connections[home] { connection = existing }
            else {
                connection = try CodexQueueConnection(home: home)
                connections[home] = connection
            }
            let result = try connection.request("thread/read", ["threadId": id, "includeTurns": false], classifyError: true)
            return result["thread"] as? JSONObject
        } catch {
            if !(error is CodexControlRPCError) { offline.insert(home) }
            return nil
        }
    }
}
