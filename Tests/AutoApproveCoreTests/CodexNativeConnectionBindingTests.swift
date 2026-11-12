#if DEBUG
import Foundation
import Darwin
@testable import AutoApproveCore

private struct NativeBindingFixture {
    typealias Object = [String: Any]
    let kernel: CodexNativeKernelPeer
    let tuiNonce = String(repeating: "a", count: 32)
    let serverNonce = String(repeating: "b", count: 32)
    let threadID = "00000000-0000-4000-8000-000000000007"
    init() throws {
        var sockets: [Int32] = [-1, -1]
        try expectEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { close(sockets[0]); close(sockets[1]) }
        kernel = try .connectedSocket(sockets[0])
    }
    func payloads() throws -> (Object, Object) {
        let peer = try JSONSerialization.jsonObject(with: JSONEncoder().encode(kernel.identity)) as! Object
        let nonce = "dGhlIHNhbXBsZSBub25jZQ=="
        let tui: Object = ["schemaVersion": 1, "producer": "autoapprove-native-tui-prototype",
            "cliVersion": "0.167.1", "nonce": tuiNonce, "pid": kernel.identity.pid,
            "stores": ["primary": [threadID], "active": [], "displayedWidget": [], "channels": [],
                "listeners": [], "navigation": [], "sideThreads": [], "sideParents": [],
                "abandonedSides": [], "speechReplay": [], "transcriptReplay": [], "replayOrder": [],
                "backgroundVoice": [], "backgroundVoiceError": [], "temporaryRequests": [],
                "pendingTitles": [], "overviewInput": [], "overviewBlankSessions": [],
                "overviewRequests": [], "pendingProfiles": [], "catalogReferences": []],
            "retainedInputs": [:], "currentWidget": ["hasDraft": false, "hasProtectedRequest": false,
                "hasQueuedInput": false, "hasActiveView": false],
            "pending": ["voiceOwner": false, "primaryEvents": false, "threadSwitches": 0,
                "dynamicTools": 0, "startupThread": false, "resumePicker": false,
                "workingDirectory": false, "worktreeStart": false, "worktreeCreation": false,
                "worktreeCreated": false, "worktreeTransition": false, "worktreeAttach": false,
                "newSessionDraft": false],
            "channelStates": [:],
            "processIdentity": peer, "backendBindingComplete": true, "membershipComplete": false,
            "admissionGranted": false, "displayedBackend": ["logicalBackendId": "owned-backend",
                "ownershipVerified": false, "transport": ["connectionNonce": nonce, "serverPeer": peer]],
            "retainedBackends": [["logicalBackendId": "owned-backend", "displayed": true,
                "listening": true, "pendingServerRequests": 0, "ownershipVerified": false,
                "connection": ["logicalBackendId": "owned-backend", "ownershipVerified": false,
                    "transport": ["connectionNonce": nonce, "serverPeer": peer]]]]]
        let server: Object = ["schemaVersion": 1, "producer": "autoapprove-native-server-prototype",
            "cliVersion": "0.167.1", "nonce": serverNonce, "pid": kernel.identity.pid,
            "serverGeneration": "00000000-0000-4000-8000-000000000001",
            "consistentRevision": false, "membershipComplete": false, "admissionGranted": false,
            "subscriptions": ["revision": 1, "initializedConnectionIDs":[7],"byConnection":["7":[threadID]],
                "subscribers":[threadID:[7]]],
            "connections": [["connectionID": 7, "initialized": true, "nativePeerIdentified": true,
                "nativePeer": peer, "nativeConnectionNonce": nonce, "clientInventoryBound": false]]]
        return (tui, server)
    }
    func bind(_ tui: Object, _ server: Object) throws -> CodexNativeDisplayedConnection {
        try .validate(tui: JSONSerialization.data(withJSONObject: tui),
            server: JSONSerialization.data(withJSONObject: server), expectedTUINonce: tuiNonce,
            expectedServerNonce: serverNonce, tuiSocketPeer: kernel, serverSocketPeer: kernel)
    }
}

extension ApprovalTests {
    func testNativeConnectionReadsKernelWitnessAndExactAssociation() throws {
        let fixture = try NativeBindingFixture()
        try expectEqual(fixture.kernel.identity.pid, UInt32(getpid()))
        try expectEqual(fixture.kernel.identity.effectiveUid, getuid())
        try expect(fixture.kernel.identity.auditPidVersion != 0)
        try expectThrows(CodexNativeKernelPeer.connectedSocket(-1))
        let (tui, server) = try fixture.payloads()
        let binding = try fixture.bind(tui, server)
        try expectEqual(binding.connectionID, 7)
        try expectEqual(binding.connectionNonce, "dGhlIHNhbXBsZSBub25jZQ==")
        try expectEqual(binding.tuiPeer, fixture.kernel.identity)
        try expectEqual(binding.serverPeer, fixture.kernel.identity)
        try expectEqual(binding.tuiReferencedThreadIDs,[fixture.threadID])
        try expectEqual(binding.serverSubscriptionRevision,1)
        try expect(!binding.tuiHasDraft && !binding.tuiHasQuestion && !binding.tuiHasQueuedInput && !binding.tuiHasActiveWork)
        var idle=tui
        var stores=idle["stores"] as! NativeBindingFixture.Object
        stores["channels"]=[fixture.threadID];idle["stores"]=stores
        var channel:NativeBindingFixture.Object=["logicalBackendId":NSNull(),"readable":true,
            "attachment":"Live","hasPendingDelivery":false,"active":true,"hasActiveTurn":false,
            "hasPendingInterrupt":false,"hasBufferedEvents":true,"hasProtectedRequest":false,"input":NSNull()]
        idle["channelStates"]=[fixture.threadID:channel]
        let displayedIdle=try fixture.bind(idle,server)
        try expectEqual(displayedIdle.tuiChannelThreadIDsByBackend["owned-backend"],[fixture.threadID])
        try expect(!displayedIdle.tuiHasActiveWork)
        channel["hasActiveTurn"]=true;idle["channelStates"]=[fixture.threadID:channel]
        try expect(try fixture.bind(idle,server).tuiHasActiveWork)
    }

    func testNativeConnectionRejectsStaleProxyDuplicateAndAuthorityClaims() throws {
        typealias Mutation = (inout NativeBindingFixture.Object, inout NativeBindingFixture.Object) -> Void
        let fixture = try NativeBindingFixture()
        let mutations: [Mutation] = [
            { tui, _ in tui["nonce"] = String(repeating: "c", count: 32) },
            { _, server in server["nonce"] = String(repeating: "c", count: 32) },
            { _, server in server["error"] = "subscription-snapshot-timeout" },
            { tui, _ in
                var peer = tui["processIdentity"] as! NativeBindingFixture.Object
                peer["auditPidVersion"] = fixture.kernel.identity.auditPidVersion &+ 1
                tui["processIdentity"] = peer
            },
            { _, server in
                var rows = server["connections"] as! [NativeBindingFixture.Object]
                var peer = rows[0]["nativePeer"] as! NativeBindingFixture.Object
                peer["pid"] = fixture.kernel.identity.pid &+ 1
                rows[0]["nativePeer"] = peer; server["connections"] = rows
            },
            { tui, _ in
                var backend = tui["displayedBackend"] as! NativeBindingFixture.Object
                var transport = backend["transport"] as! NativeBindingFixture.Object
                var peer = transport["serverPeer"] as! NativeBindingFixture.Object
                peer["auditPidVersion"] = fixture.kernel.identity.auditPidVersion &+ 1
                transport["serverPeer"] = peer; backend["transport"] = transport
                tui["displayedBackend"] = backend
            },
            { _, server in
                let rows = server["connections"] as! [NativeBindingFixture.Object]
                server["connections"] = rows + rows
            },
            { _, server in
                var rows = server["connections"] as! [NativeBindingFixture.Object]
                var second = rows[0]; second["connectionID"] = 8; rows.append(second)
                server["connections"] = rows
            },
            { _, server in
                var rows = server["connections"] as! [NativeBindingFixture.Object]
                rows[0]["initialized"] = 1; server["connections"] = rows
            },
            { tui, _ in tui["membershipComplete"] = true },
            { tui, _ in tui["backendBindingComplete"] = false },
            { tui, _ in
                var rows = tui["retainedBackends"] as! [NativeBindingFixture.Object]
                rows.append(rows[0]); tui["retainedBackends"] = rows
            },
            { _, server in server["admissionGranted"] = true },
            { tui, _ in tui["cliVersion"] = "0.166.0" },
            { tui, _ in
                var backend = tui["displayedBackend"] as! NativeBindingFixture.Object
                backend["ownershipVerified"] = true; tui["displayedBackend"] = backend
            }
        ]
        for mutate in mutations {
            var (tui, server) = try fixture.payloads()
            mutate(&tui, &server)
            try expectThrows(fixture.bind(tui, server))
        }
    }
}
#endif
