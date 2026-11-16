import Foundation

/// Private restoration evidence, written with the restart plan before exits.
/// It contains process identities and paths, never authentication material.
struct CodexCohortRestartContext:Codable {
    let planID:UUID
    let selectedSessionID:String
    let launch:CodexSessionLaunch
    let originalServer:CodexNativePeerIdentity
    let originals:[UUID:SessionExitRecovery]
    var scope:[CodexMigrationThread]
    var movingThreads:Set<String>
    var originalGoals:[String:CodexGoal]
    var transfers:[String:UUID]
    var quiesced:Bool?
    var archivedPaths:[String:String]?
    var quiesceSeen:Set<String>?
    /// A standalone writer can join an existing server without restarting its
    /// unrelated clients. Missing on older plans means the shared-server flow.
    var restartServer:Bool?=nil
    /// Saved before exit so orphaned tool/MCP hosts cannot keep an independent
    /// rollout writer alive or reconnect during server handoff.
    var processTree:[UUID:[ProcessRecord]]?=nil
    /// Automatic idle enrollment may discard a captured, effect-free proposal
    /// after controller death and prepare again from a fresh screen. A manual
    /// proposal, or an old record without this marker, requires explicit action.
    var automaticEnrollment:Bool?=nil
    static func key(_ id:UUID)->String {"codexCohortContext:"+id.uuidString.lowercased()}
}
