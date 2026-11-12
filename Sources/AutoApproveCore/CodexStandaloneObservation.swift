import Foundation

/// A standalone TUI has no shared Unix transport to pair. Its private runtime
/// registration and kernel socket peer still prove the displayed conversation.
enum CodexStandaloneObservation {
    static func displays(home:String,pid:Int32,threadID:String) async throws->Bool {
        let hints=try await Task.detached(priority:.utility) {
            try CodexNativeRuntimeRegistry.candidates(root:CodexNativeRuntimeRoot.path,pid:pid,role:.tui,home:home)
        }.value
        let hint=try await CodexNativeRuntimeRegistry.live(hints,role:.tui)
        let observation=try await CodexNativeObservation.query(path:hint.inventorySocket)
        guard observation.peer.identity==hint.claimedPeer,
              let object=try JSONSerialization.jsonObject(with:observation.data) as? JSONObject,
              object["nonce"] as? String==observation.nonce,(object["pid"] as? NSNumber)?.uint32Value==UInt32(pid),
              let stores=object["stores"] as? [String:[String]],
              let primary=stores["primary"],let active=stores["active"],let displayed=stores["displayedWidget"] else{return false}
        return Set(primary)==[threadID] && Set(active+displayed)==[threadID]
    }
}
