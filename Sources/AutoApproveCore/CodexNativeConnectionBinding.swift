import Foundation
import Darwin
import CNativePeer

struct CodexNativePeerIdentity: Codable, Equatable, Sendable {
    let source: String
    let pid: UInt32
    let effectiveUid: UInt32
    let effectiveGid: UInt32
    let auditPidVersion: UInt32
}

/// A kernel witness cannot be constructed by decoding an observation response.
struct CodexNativeKernelPeer: Equatable, Sendable {
    let identity: CodexNativePeerIdentity
    private init(_ value: aa_native_peer_identity) {
        identity = .init(source: "macos-audit-token", pid: value.pid,
            effectiveUid: value.effective_uid, effectiveGid: value.effective_gid,
            auditPidVersion: value.audit_pid_version)
    }
    static func connectedSocket(_ fd: Int32) throws -> Self {
        var value = aa_native_peer_identity()
        guard aa_native_peer_from_socket(fd, &value) == 0 else {
            throw AppError.message("Codex 연결의 실제 프로세스를 확인하지 못했습니다.")
        }
        return Self(value)
    }
}

/// Proves only one displayed transport association. It grants no migration,
/// retained-thread ownership, complete census or stable-revision permission.
struct CodexNativeDisplayedConnection: Equatable, Sendable {
    let serverGeneration: String
    let connectionID: UInt64
    let logicalBackendID: String
    let connectionNonce: String
    let serverConnectionIDs:Set<UInt64>
    let serverThreadIDsByConnection:[UInt64:Set<String>]
    let serverSubscriptionRevision:UInt64?
    let tuiActiveThreadIDs:Set<String>
    let tuiChannelThreadIDsByBackend:[String:Set<String>]
    let tuiHasDraft:Bool,tuiHasQuestion:Bool,tuiHasQueuedInput:Bool,tuiHasActiveWork:Bool
    let tuiPeer: CodexNativePeerIdentity
    let serverPeer: CodexNativePeerIdentity
    /// Thread references from this authenticated TUI snapshot are conservative
    /// membership hints, not a complete cross-process ownership census.
    let tuiReferencedThreadIDs: Set<String>

    private init(serverGeneration: String, connectionID: UInt64, logicalBackendID: String,
        connectionNonce: String, serverConnectionIDs:Set<UInt64>,serverThreadIDsByConnection:[UInt64:Set<String>],serverSubscriptionRevision:UInt64?,tuiActiveThreadIDs:Set<String>,tuiChannelThreadIDsByBackend:[String:Set<String>],tuiHasDraft:Bool,tuiHasQuestion:Bool,tuiHasQueuedInput:Bool,tuiHasActiveWork:Bool,tuiPeer: CodexNativePeerIdentity, serverPeer: CodexNativePeerIdentity,
        tuiReferencedThreadIDs:Set<String>) {
        self.serverGeneration = serverGeneration; self.connectionID = connectionID
        self.logicalBackendID = logicalBackendID; self.connectionNonce = connectionNonce
        self.serverConnectionIDs=serverConnectionIDs
        self.serverThreadIDsByConnection=serverThreadIDsByConnection
        self.serverSubscriptionRevision=serverSubscriptionRevision
        self.tuiActiveThreadIDs=tuiActiveThreadIDs
        self.tuiChannelThreadIDsByBackend=tuiChannelThreadIDsByBackend
        self.tuiHasDraft=tuiHasDraft;self.tuiHasQuestion=tuiHasQuestion
        self.tuiHasQueuedInput=tuiHasQueuedInput;self.tuiHasActiveWork=tuiHasActiveWork
        self.tuiPeer = tuiPeer; self.serverPeer = serverPeer
        self.tuiReferencedThreadIDs=tuiReferencedThreadIDs
    }

    func migrationClient(identity:CodexMigrationClientID,home:String)->CodexMigrationClient {
        .init(identity:identity,home:home,threadIDs:tuiReferencedThreadIDs.sorted(),
              hasDraft:tuiHasDraft,hasQuestion:tuiHasQuestion,
              hasQueuedInput:tuiHasQueuedInput,hasIndependentWork:tuiHasActiveWork)
    }
    func migrationClient(process:ProcessRecord,home:String)throws->CodexMigrationClient {
        guard process.agent == .codex,process.pid>0,UInt32(process.pid)==tuiPeer.pid,
              !process.started.isEmpty,!process.tty.isEmpty,process.tty != "??" else {
            throw AppError.message("Codex 창과 실제 프로세스의 연결이 바뀌었습니다.")
        }
        return migrationClient(identity:.init(pid:process.pid,started:process.started,tty:"/dev/"+process.tty),home:home)
    }

    private struct Transport: Decodable, Equatable {
        let connectionNonce: String
        let serverPeer: CodexNativePeerIdentity
    }
    private struct Backend: Decodable, Equatable {
        let logicalBackendId: String
        let transport: Transport
        let ownershipVerified: Bool
    }
    private struct RetainedBackend: Decodable {
        let logicalBackendId: String
        let displayed: Bool
        let listening: Bool
        let pendingServerRequests: Int
        let connection: Backend?
        let ownershipVerified: Bool
    }
    private struct TUI: Decodable {
        let schemaVersion: Int, producer: String, cliVersion: String, nonce: String
        let pid: UInt32
        let processIdentity: CodexNativePeerIdentity
        let stores: [String:[String]]
        let retainedInputs:[String:InputObservation]
        let currentWidget:WidgetObservation
        let pending:PendingObservation
        let channelStates:[String:ChannelObservation]
        let displayedBackend: Backend
        let retainedBackends: [RetainedBackend]
        let backendBindingComplete: Bool, membershipComplete: Bool, admissionGranted: Bool
    }
    private struct ChannelObservation:Decodable {
        let logicalBackendId:String?
        let readable:Bool
        let attachment:String
        let hasPendingDelivery:Bool
        let active:Bool?,hasActiveTurn:Bool?,hasPendingInterrupt:Bool?,hasBufferedEvents:Bool?,hasProtectedRequest:Bool?
        let input:InputObservation?
    }
    private struct InputObservation:Decodable {
        let hasDraft:Bool,retainedQuestionState:Bool,startupInput:Bool,queuedInput:Bool,pendingSteers:Bool
        let unconfirmedInput:Bool,pendingStart:Bool,taskRunning:Bool,agentTurnRunning:Bool,reconnectPending:Bool
        let protectedBuffer:Bool,settingsPending:Bool
    }
    private struct WidgetObservation:Decodable {
        let hasDraft:Bool,hasProtectedRequest:Bool,hasQueuedInput:Bool,hasActiveView:Bool
    }
    private struct PendingObservation:Decodable {
        let voiceOwner:Bool,primaryEvents:Bool,threadSwitches:Int,dynamicTools:Int,startupThread:Bool
        let resumePicker:Bool,workingDirectory:Bool,worktreeStart:Bool,worktreeCreation:Bool
        let worktreeCreated:Bool,worktreeTransition:Bool,worktreeAttach:Bool,newSessionDraft:Bool
    }
    private struct Connection: Decodable {
        let connectionID: UInt64
        let initialized: Bool, nativePeerIdentified: Bool
        let nativePeer: CodexNativePeerIdentity?
        let nativeConnectionNonce: String?
        let clientInventoryBound: Bool
    }
    private struct Server: Decodable {
        let schemaVersion: Int, producer: String, cliVersion: String, nonce: String
        let pid: UInt32
        let serverGeneration: String
        let connections: [Connection]
        let subscriptions:Subscriptions
        let consistentRevision: Bool, membershipComplete: Bool, admissionGranted: Bool
        let error: String?
    }
    private struct Subscriptions:Decodable {
        let revision:UInt64?
        let initializedConnectionIDs:[UInt64]
        let byConnection:[String:[String]]
        let subscribers:[String:[UInt64]]
    }
    private static var failure: AppError {
        .message("Codex 창과 연결 서버의 동일 접속을 확인하지 못했습니다.")
    }
    private static let threadStores:Set<String>=[
        "primary","active","displayedWidget","channels","listeners","navigation","sideThreads",
        "sideParents","abandonedSides","speechReplay","transcriptReplay","replayOrder","backgroundVoice",
        "backgroundVoiceError","temporaryRequests","pendingTitles","overviewInput","overviewBlankSessions",
        "overviewRequests","pendingProfiles","catalogReferences"
    ]
    private static func challenge(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }
    private static func valid(_ backend: Backend, id: String, uid: UInt32) -> Bool {
        let nonce = backend.transport.connectionNonce
        guard backend.logicalBackendId == id, !backend.ownershipVerified,
              !id.isEmpty, id.utf8.count <= 128,
              !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              backend.transport.serverPeer.source == "macos-audit-token",
              backend.transport.serverPeer.pid > 0, backend.transport.serverPeer.effectiveUid == uid,
              backend.transport.serverPeer.auditPidVersion > 0,
              let decoded = Data(base64Encoded: nonce), decoded.count == 16,
              decoded.base64EncodedString() == nonce else { return false }
        return true
    }
    static func validate(tui: Data, server: Data, expectedTUINonce: String,
        expectedServerNonce: String, tuiSocketPeer: CodexNativeKernelPeer,
        serverSocketPeer: CodexNativeKernelPeer) throws -> Self {
        do {
            guard (1...1_048_576).contains(tui.count), (1...1_048_576).contains(server.count),
                  challenge(expectedTUINonce), challenge(expectedServerNonce) else { throw failure }
            let decoder = JSONDecoder()
            let client = try decoder.decode(TUI.self, from: tui)
            let host = try decoder.decode(Server.self, from: server)
            let owner = tuiSocketPeer.identity, backend = serverSocketPeer.identity
            let displayed = client.displayedBackend
            let nonce = displayed.transport.connectionNonce
            let retained = client.retainedBackends
            // Catalog rows can include every session in the server. They are
            // reloadable listings, not references owned by this TUI client.
            let referenced = Set(client.stores.filter{$0.key != "catalogReferences"}.values.flatMap{$0})
            let active=Set((client.stores["primary"] ?? [])+(client.stores["active"] ?? [])+(client.stores["displayedWidget"] ?? []))
            var channelThreads:[String:Set<String>]=[:]
            for (threadID,channel) in client.channelStates {
                // A channel records an explicit owner only after a backend
                // handoff. Until then it belongs to the displayed backend.
                let backendID=channel.logicalBackendId ?? displayed.logicalBackendId
                guard UUID(uuidString:threadID)?.uuidString.lowercased()==threadID,
                      !backendID.isEmpty,backendID.utf8.count<=128,
                      !backendID.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else{throw failure}
                channelThreads[backendID,default:[]].insert(threadID)
            }
            guard client.schemaVersion == 1, host.schemaVersion == 1,
                  client.producer == "autoapprove-native-tui-prototype",
                  host.producer == "autoapprove-native-server-prototype",
                  client.cliVersion == "0.167.1", host.cliVersion == client.cliVersion,
                  client.nonce == expectedTUINonce, host.nonce == expectedServerNonce,
                  host.error == nil,
                  client.pid == owner.pid, client.processIdentity == owner,
                  host.pid == backend.pid, displayed.transport.serverPeer == backend,
                  Set(client.stores.keys)==threadStores,
                  Set(client.retainedInputs.keys).isSubset(of:referenced),
                  Set(client.channelStates.keys)==Set(client.stores["channels"] ?? []),
                  client.channelStates.values.allSatisfy({$0.readable && !$0.hasPendingDelivery
                      && !$0.attachment.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains)
                      && $0.active != nil && $0.hasActiveTurn != nil && $0.hasPendingInterrupt != nil
                      && $0.hasBufferedEvents != nil && $0.hasProtectedRequest != nil}),
                  client.stores.values.allSatisfy({ ids in
                      ids.count<=4096 && Set(ids).count==ids.count && ids==ids.sorted()
                          && ids.allSatisfy({UUID(uuidString:$0)?.uuidString.lowercased()==$0})
                  }),
                  owner.effectiveUid == getuid(), backend.effectiveUid == getuid(),
                  client.backendBindingComplete, !client.membershipComplete, !client.admissionGranted,
                  !displayed.ownershipVerified, !host.consistentRevision,
                  !host.membershipComplete, !host.admissionGranted,
                  UUID(uuidString: host.serverGeneration)?.uuidString.lowercased() == host.serverGeneration,
                  !displayed.logicalBackendId.isEmpty, displayed.logicalBackendId.utf8.count <= 128,
                  !displayed.logicalBackendId.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  let decodedNonce = Data(base64Encoded: nonce), decodedNonce.count == 16,
                  decodedNonce.base64EncodedString() == nonce,
                  host.connections.count <= 4096,
                  Set(host.connections.map(\.connectionID)).count == host.connections.count,
                  Set(host.subscriptions.initializedConnectionIDs).count==host.subscriptions.initializedConnectionIDs.count,
                  Set(host.subscriptions.initializedConnectionIDs)==Set(host.connections.filter(\.initialized).map(\.connectionID)),
                  host.subscriptions.byConnection.count<=4096,host.subscriptions.subscribers.count<=4096
            else { throw failure }
            var threadIDsByConnection:[UInt64:Set<String>]=[:]
            for (rawID,ids) in host.subscriptions.byConnection {
                guard let id=UInt64(rawID),String(id)==rawID,
                      host.subscriptions.initializedConnectionIDs.contains(id),ids.count<=4096,
                      Set(ids).count==ids.count,ids==ids.sorted(),
                      ids.allSatisfy({UUID(uuidString:$0)?.uuidString.lowercased()==$0}) else{throw failure}
                threadIDsByConnection[id]=Set(ids)
            }
            guard host.subscriptions.subscribers.allSatisfy({threadID,ids in
                UUID(uuidString:threadID)?.uuidString.lowercased()==threadID && ids.count<=4096
                    && Set(ids).count==ids.count && ids==ids.sorted()
                    && ids.allSatisfy({host.subscriptions.initializedConnectionIDs.contains($0)
                        && threadIDsByConnection[$0]?.contains(threadID)==true})
            }),threadIDsByConnection.allSatisfy({connectionID,ids in
                ids.allSatisfy({host.subscriptions.subscribers[$0]?.contains(connectionID)==true})
            }) else{throw failure}
            let displayedRows = retained.filter(\.displayed)
            guard !retained.isEmpty,retained.count <= 64,displayedRows.count == 1,
                  displayedRows[0].logicalBackendId == displayed.logicalBackendId,
                  Set(retained.map(\.logicalBackendId)).count == retained.count,
                  retained.allSatisfy({ row in
                      row.pendingServerRequests >= 0 && !row.ownershipVerified
                          && row.connection.map { valid($0,id:row.logicalBackendId,uid:owner.effectiveUid) } == true
                  }),
                  valid(displayed,id:displayed.logicalBackendId,uid:owner.effectiveUid),
                  displayedRows[0].connection == displayed else { throw failure }
            let matches = host.connections.filter {
                $0.initialized && $0.nativePeerIdentified && !$0.clientInventoryBound
                && $0.nativePeer == owner && $0.nativeConnectionNonce == nonce
            }
            guard matches.count == 1 else { throw failure }
            let inputs=Array(client.retainedInputs.values)+client.channelStates.values.compactMap(\.input)
            let widget=client.currentWidget,pending=client.pending
            let hasDraft=widget.hasDraft || inputs.contains(where:{$0.hasDraft})
            let hasQuestion=inputs.contains(where:{$0.retainedQuestionState})
            let hasQueuedInput=widget.hasQueuedInput || widget.hasProtectedRequest || inputs.contains(where:{
                $0.startupInput || $0.queuedInput || $0.pendingSteers || $0.unconfirmedInput
                    || $0.pendingStart || $0.protectedBuffer || $0.settingsPending
            })
            let hasActiveWork=widget.hasActiveView || inputs.contains(where:{
                $0.taskRunning || $0.agentTurnRunning || $0.reconnectPending
            }) || client.channelStates.values.contains(where:{
                // `active` selects the displayed channel; its replay buffer
                // retains history even while idle. Neither means work is running.
                $0.hasActiveTurn == true || $0.hasPendingInterrupt == true || $0.hasProtectedRequest == true
            }) || pending.voiceOwner || pending.primaryEvents || pending.threadSwitches>0
                || pending.dynamicTools>0 || pending.startupThread || pending.resumePicker
                || pending.workingDirectory || pending.worktreeStart || pending.worktreeCreation
                || pending.worktreeCreated || pending.worktreeTransition || pending.worktreeAttach
                || pending.newSessionDraft
            return Self(serverGeneration: host.serverGeneration, connectionID: matches[0].connectionID,
                logicalBackendID: displayed.logicalBackendId, connectionNonce: nonce,
                serverConnectionIDs:Set(host.connections.map(\.connectionID)),
                serverThreadIDsByConnection:threadIDsByConnection,
                serverSubscriptionRevision:host.subscriptions.revision,
                tuiActiveThreadIDs:active,
                tuiChannelThreadIDsByBackend:channelThreads,
                tuiHasDraft:hasDraft,tuiHasQuestion:hasQuestion,tuiHasQueuedInput:hasQueuedInput,tuiHasActiveWork:hasActiveWork,
                tuiPeer: owner, serverPeer: backend,tuiReferencedThreadIDs:referenced)
        } catch { throw failure }
    }
}
