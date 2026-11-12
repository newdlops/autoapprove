import Foundation
@testable import AutoApproveCore

@main struct SelectedCoordinatorFixture {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count==7 else{throw AppError.message("Expected source destination sourceSocket destinationSocket threadID binary")}
        let args=CommandLine.arguments,thread=args[5]
        let slot=try CodexGoalTransferStore.captureSlot(home:args[1],threadID:thread)
        let target=try CodexGoalTransferStore.captureSlot(home:args[2],threadID:thread)
        let sourcePeer=try CodexNativeLineConnection(path:args[3])
        let targetPeer=try CodexNativeLineConnection(path:args[4])
        defer{sourcePeer.close();targetPeer.close()}
        func endpoint(home:String,identity:String,pid:UInt32,socket:String)->CodexMigrationEndpoint {
            .init(home:home,physicalHomeID:identity,serverID:"owned-\(pid)",socketID:socket,
                cliIdentity:args[6],cliVersion:"0.167.1",account:.init(provider:"fixture",email:nil,authenticated:true))
        }
        let source=endpoint(home:slot.sourceHome,identity:slot.homeIdentity,pid:sourcePeer.peer.identity.pid,socket:args[3])
        let destination=endpoint(home:target.sourceHome,identity:target.homeIdentity,pid:targetPeer.peer.identity.pid,socket:args[4])
        let goal=try CodexSessionAttachment.goalIfPresent(home:source.home,threadID:thread)
        let client=CodexMigrationClient(identity:.init(pid:123,started:"owned-fixture-client",tty:"/dev/fixture"),home:source.home,threadIDs:[thread])
        let conversation=CodexMigrationThread(id:thread,home:source.home,parentID:nil,turnID:nil,
            goalRevision:goal?.instanceID,configurationID:"owned-fixture-settings",resumable:true,goalStatus:goal?.status)
        let request=CodexSessionMigrationRequest(id:UUID().uuidString.lowercased(),source:source,destination:destination,clients:[client],threads:[conversation])
        let journal=try CodexMigrationJournal(store:AuditStore(path:URL(fileURLWithPath:source.home).deletingLastPathComponent().appendingPathComponent("coordinator.sqlite").path))
        let coordinator=CodexSessionMigrationCoordinator(journal:journal,services:.init(observe:{_ in
            .init(source:source,destination:destination,clients:[client],threads:[conversation],completeClients:true,completeThreads:true)
        }))
        _=try await coordinator.prepare(request)
        let sourceLease=try CodexNativeSelectedInputLease(path:args[3],expectedServerPeer:sourcePeer.peer.identity,threadIDs:[thread])
        let destinationLease=try CodexNativeSelectedInputLease(path:args[4],expectedServerPeer:targetPeer.peer.identity,threadIDs:[thread])
        defer{sourceLease.close();destinationLease.close()}
        var shutdown=try await coordinator.beginSelectedShutdown(id:request.id,lease:sourceLease)
        while shutdown.state=="pending" {
            try sourceLease.renew();try destinationLease.renew()
            try await Task.sleep(for:.milliseconds(50))
            shutdown=try sourceLease.shutdownStatus()
        }
        guard shutdown.state=="stopped" else{throw AppError.message("Owned shutdown failed")}
        func ownership(path:String,peer:CodexNativePeerIdentity)throws->CodexNativeOwnershipObservation {
            try CodexNativeSelectedInputLease.observeOwnership(path:path,expectedServerPeer:peer,threadIDs:[thread])
        }
        _=try coordinator.retireSelectedSource(id:request.id,lease:sourceLease,
            ownership:ownership(path:args[3],peer:sourcePeer.peer.identity))
        _=try coordinator.acceptSelectedIncoming(id:request.id,lease:destinationLease,
            ownership:ownership(path:args[4],peer:targetPeer.peer.identity))
        _=try coordinator.activateImportedSessions(id:request.id,lease:destinationLease)
        let completed=try coordinator.complete(id:request.id,
            source:ownership(path:args[3],peer:sourcePeer.peer.identity),destination:ownership(path:args[4],peer:targetPeer.peer.identity))
        guard completed.stage == .completed,try journal.owner(threadID:thread)?.home.path==destination.home,
              try coordinator.activeStates().isEmpty else{throw AppError.message("Owned completion was not durable")}
        print("coordinator-completed "+request.id)
    }
}
