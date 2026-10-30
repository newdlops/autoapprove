import Foundation
import AutoApproveCore

@main struct ConversationTransportCheck {
    static func main() async throws {
        let args=CommandLine.arguments,target=CodexReplyTarget(executable:"",home:args[1],threadID:args[2])
        if args.contains("--expect-error") {
            do {_ = try await CodexConversationTransport.live.read(target,"/fixture",nil);throw AppError.message("Invalid history accepted")}
            catch let error as RemoteHTTPError where error.status==409 {print("{\"rejected\":true}");return}
            catch let error as AppError {guard !error.localizedDescription.contains("Invalid history accepted") else {throw error};print("{\"rejected\":true}");return}
        }
        let page=try await CodexConversationTransport.live.read(target,"/fixture",nil)
        guard page.messages.map(\.id)==["user","progress","answer"],page.nextCursor=="older",page.messages[2].text=="한글🙂 <img src=x onerror=alert(1)>" else {throw AppError.message("Display history differs")}
        let older=try await CodexConversationTransport.live.read(target,"/fixture",page.nextCursor)
        guard older.messages.map(\.id)==["earliest"],older.nextCursor==nil else {throw AppError.message("Older messages differ")}
        print("{\"verified\":true,\"messages\":4}")
    }
}
