import Foundation
@testable import AutoApproveCore

// Called only with the two private homes owned by the native live fixture.
@main struct SelectedImportFixture {
    static func main() throws {
        guard [5,6].contains(CommandLine.arguments.count) else{throw AppError.message("Expected source destination requestID manifest [observation]")}
        let source=CommandLine.arguments[1],destination=CommandLine.arguments[2],request=CommandLine.arguments[3]
        let files=try JSONDecoder().decode([CodexNativeArchivedFile].self,
            from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[4])))
        let ids=Array(Set(files.map(\.threadId))).sorted()
        guard let first=ids.first else{throw AppError.message("Empty import scope")}
        let sourceSlot=try CodexGoalTransferStore.captureSlot(home:source,threadID:first)
        let destinationSlot=try CodexGoalTransferStore.captureSlot(home:destination,threadID:first)
        let refs=try CodexGoalTransferSlotStore.capture(home:sourceSlot.sourceHome,homeIdentity:sourceSlot.homeIdentity,
            requestID:request,threadIDs:ids)
        _=try CodexNativeSelectedArchiveImport.install(requestID:request,sourceHome:sourceSlot.sourceHome,
            sourceHomeIdentity:sourceSlot.homeIdentity,destinationHome:destinationSlot.sourceHome,
            destinationHomeIdentity:destinationSlot.homeIdentity,files:files,goalSlots:refs,threadIDs:ids)
        if CommandLine.arguments.count==6 {
            let observation=try JSONDecoder().decode(CodexNativeImportObservation.self,
                from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[5])))
            let slots=try refs.map{try CodexGoalTransferSlotStore.load($0,home:sourceSlot.sourceHome,
                homeIdentity:sourceSlot.homeIdentity,requestID:request,threadIDs:Set(ids))}
            try observation.validate(requestID:request,home:destinationSlot.homeIdentity,revision:1,sourceRevision:1,slots:slots)
        }
        print(String(decoding:try JSONEncoder().encode(refs),as:UTF8.self))
    }
}
