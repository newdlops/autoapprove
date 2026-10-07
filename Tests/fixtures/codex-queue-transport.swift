import Foundation
import AutoApproveCore
import Darwin

@main struct CodexQueueTransportFixture {
    static func main() async throws {
        let target = CodexReplyTarget(executable: "/unused", home: CommandLine.arguments[1], threadID: CommandLine.arguments[2])
        if CommandLine.arguments.contains("--home-socket-proof") {
            let path = URL(fileURLWithPath: target.home).appendingPathComponent("app-server-control/app-server-control.sock").resolvingSymlinksInPath().path
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw AppError.message("Could not create isolated socket") }
            defer { Darwin.close(fd) }
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let bytes = Array(path.utf8) + [0]
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
            let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard connected == 0,
                  CodexServerLocation.connectedHome(pid: getpid(), hints: [target.home]) == URL(fileURLWithPath: target.home).resolvingSymlinksInPath().path,
                  CodexServerLocation.connectedHome(pid: getpid(), hints: [target.home + "/unrelated"]) == nil,
                  CodexServerLocation.connectedHome(pid: 2_000_000_000, hints: [target.home]) == nil else { throw AppError.message("Socket home binding failed") }
            print("{\"kernelPeerBound\":true}"); return
        }
        if CommandLine.arguments.contains("--enqueue") || CommandLine.arguments.contains("--expect-unconfirmed") {
            let message = String(repeating: "한글🧪\t\n", count: 5_000)
            do {
                let id = try await CodexReplyTransport.live.send(target, message)
                guard !CommandLine.arguments.contains("--expect-unconfirmed") else { throw AppError.message("An unconfirmed write was accepted") }
                print("{\"queueID\":\"\(id)\",\"bytes\":\(message.utf8.count)}"); return
            } catch {
                guard CommandLine.arguments.contains("--expect-unconfirmed") else { throw error }
                print("{\"unconfirmedRefused\":true}"); return
            }
        }
        if CommandLine.arguments.contains("--expect-unavailable") {
            do { _ = try await CodexQueueTransport.live.list(target) }
            catch {
                guard error.localizedDescription.contains("로컬 서버를 찾지 못했습니다") else { throw error }
                print("{\"nonSocketRefused\":true}"); return
            }
            throw AppError.message("A non-socket control link was accepted")
        }
        let list = try await CodexQueueTransport.live.list(target)
        if CommandLine.arguments.contains("--read-only") {
            print("{\"listCount\":\(list.count)}"); return
        }
        let conversations = try await CodexQueueTransport.live.conversations(target, "/fixture")
        try await CodexQueueTransport.live.validate(target, "/fixture")
        var refusedChangedFolder = false
        do { try await CodexQueueTransport.live.validate(target, "/different") }
        catch { refusedChangedFolder = true }
        let deleted = try await CodexQueueTransport.live.delete(target, ["first", "second"])
        let value: JSONObject = ["ids":list.map(\.id), "text":list.first?.text ?? "", "attachments":list.last?.attachments ?? 0,
                                 "removed":deleted.removed, "partialError":deleted.error != nil,
                                 "conversations":conversations.map(\.id), "changedFolderRefused":refusedChangedFolder]
        print(String(decoding:try JSONSerialization.data(withJSONObject:value,options:.sortedKeys),as:UTF8.self))
    }
}
