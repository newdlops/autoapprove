#if DEBUG
import Foundation
@testable import AutoApproveCore

private final class OfficialSupportAccess:@unchecked Sendable {
    private let lock=NSLock()
    private var total=0
    func touch(){lock.withLock{total+=1}}
    var count:Int{lock.withLock{total}}
}

extension ApprovalTests {
    func testOfficialUnsupportedOperationsDoNotContactSessionsOrServers() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("aa-official-support-"+UUID().uuidString)
        let paths=AppPaths(directory:directory),access=OfficialSupportAccess()
        let servers=CodexManagedServerServices(inspect:{_,_ in
            access.touch();throw AppError.message("Unexpected server inspection")
        },prepare:{_,_ in
            access.touch();throw AppError.message("Unexpected server preparation")
        })
        let engine=try ApprovalEngine(paths:paths,processReader:{
            access.touch();throw AppError.message("Unexpected process discovery")
        },codexManagedServers:servers)
        defer{engine.stop();try? FileManager.default.removeItem(at:directory)}
        let operations:[@MainActor () async throws->Void]=[
            {_ = try await engine.prepareStandaloneCodexSessionMove(sessionID:"unobserved",destinationHome:"/unobserved")},
            {_ = try await engine.prepareCodexSessionMove(sessionID:"unobserved",destinationHome:"/unobserved")},
            {_ = try await engine.performCodexSessionMove(id:"unobserved")},
            {_ = try await engine.executeCodexSessionMigration(id:"unobserved")}
        ]
        for operation in operations {
            do {try await operation();throw AppError.message("Unsupported move was accepted")}
            catch {try expectEqual(error.localizedDescription,CodexFeatureSupport.sessionMoveUnavailable)}
        }
        do {_ = try await engine.codexSessionServerLink(sessionID:"unobserved");throw AppError.message("Unsupported inventory was accepted")}
        catch {try expectEqual(error.localizedDescription,CodexFeatureSupport.connectionInventoryUnavailable)}
        try expectEqual(access.count,0,"Unsupported operations must fail before discovery or server preparation")
    }
}
#endif
