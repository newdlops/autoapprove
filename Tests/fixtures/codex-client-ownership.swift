import Foundation
@testable import AutoApproveCore

// Only the fresh anonymous server created by codex-client-ownership-check.mjs.
@main struct ClientOwnershipCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw AppError.message("Owned home and server PID required") }
        let home = CommandLine.arguments[1]
        guard home.hasPrefix("/private/tmp/aa-owner-"), let pid = Int32(CommandLine.arguments[2]) else {
            throw AppError.message("Owned fixture identity required")
        }
        let a = try CodexQueueConnection(home: home)
        let b = try CodexQueueConnection(home: home)
        let observer = try CodexQueueConnection(home: home)
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw AppError.message(message) }
        }
        for connection in [a, b, observer] {
            try require(try connection.peerProcessID() == pid, "Wrong native server peer")
            let account = try connection.request("account/read", ["refreshToken": false])
            try require(account["account"] is NSNull, "Anonymous fixture required")
        }
        let start = try a.request("thread/start", ["model": "fixture-model", "modelProvider": "fixture",
            "cwd": home, "ephemeral": false, "approvalPolicy": "never", "sandbox": "read-only"])
        guard let row = start["thread"] as? JSONObject, let id = row["id"] as? String,
              UUID(uuidString: id) != nil else { throw AppError.message("Owned thread missing") }
        let before = try b.request("thread/loaded/list", ["limit": 100])
        try require(before["data"] as? [String] == [id], "Unsubscribed client cannot see server-wide loaded list")
        let notSubscribed = try b.request("thread/unsubscribe", ["threadId": id])
        try require(notSubscribed["status"] as? String == "notSubscribed", "Loaded list was mistaken for client subscription")

        // Empty threads have no persisted rollout in 0.166. Materialize one local,
        // synthetic turn before resume; this is not a retry of an ambiguous RPC.
        _ = try a.request("turn/start", ["threadId": id,
            "input": [["type": "text", "text": "Owned synthetic ownership context only.", "text_elements": []]]])
        var materialized = false
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let read = try a.request("thread/read", ["threadId": id, "includeTurns": true])
            if let thread = read["thread"] as? JSONObject,
               (thread["status"] as? JSONObject)?["type"] as? String == "idle",
               let turns = thread["turns"] as? [JSONObject], !turns.isEmpty {
                materialized = true
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        try require(materialized, "Owned synthetic turn did not materialize")
        let joined = try b.request("thread/resume", ["threadId": id, "excludeTurns": true])
        try require((joined["thread"] as? JSONObject)?["id"] as? String == id, "Second connection did not join same UUID")
        // Match the TUI's /side fork presentation: an ephemeral fork is also
        // part of that client's affected set, despite having no saved rollout.
        let fork = try a.request("thread/fork", ["threadId": id, "ephemeral": true, "excludeTurns": true])
        guard let side = fork["thread"] as? JSONObject, let sideID = side["id"] as? String else {
            throw AppError.message("Owned side fork missing")
        }
        try require(sideID != id && side["ephemeral"] as? Bool == true, "Side fork identity missing")
        let shared = try observer.request("thread/read", ["threadId": id, "includeTurns": false])
        guard let current = shared["thread"] as? JSONObject else { throw AppError.message("Shared thread missing") }
        let removeA = try a.request("thread/unsubscribe", ["threadId": id])
        try require(removeA["status"] as? String == "unsubscribed", "Original subscriber missing")
        let after = try observer.request("thread/loaded/list", ["limit": 100])
        try require(Set(after["data"] as? [String] ?? []) == Set([id, sideID]), "Remaining subscribers lost loaded threads")
        let removeB = try b.request("thread/unsubscribe", ["threadId": id])
        try require(removeB["status"] as? String == "unsubscribed", "Second subscriber missing")
        let removeSide = try a.request("thread/unsubscribe", ["threadId": sideID])
        try require(removeSide["status"] as? String == "unsubscribed", "Side subscriber missing")
        let report: JSONObject = ["verified": true, "anonymous": true, "connections": 3,
            "sharedUUID": true, "loadedListIsNotSubscriptionInventory": true,
            "sideForkEphemeral": true, "sideForkParentMatchesRoot": side["parentThreadId"] as? String == id,
            "sideForkSessionMatchesRoot": side["sessionId"] as? String == id,
            "sideForkForkedFromMatchesRoot": side["forkedFromId"] as? String == id,
            "threadFields": current.keys.sorted(), "userSessionsTouched": false, "daemonRestarted": false]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }
}
