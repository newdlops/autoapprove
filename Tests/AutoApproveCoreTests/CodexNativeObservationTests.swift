#if DEBUG
import Foundation
import Darwin
@testable import AutoApproveCore

private final class NativeObservationServer {
    let root = URL(fileURLWithPath: "/private/tmp/aa-native-read-" + UUID().uuidString)
    var path: String { root.appendingPathComponent("s").path }
    let worker: Task<Data, Error>
    init(response: @escaping @Sendable (String) -> Data) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AppError.message("Owned native listener failed") }
        var transferred = false
        defer { if !transferred { close(fd) } }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(root.appendingPathComponent("s").path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 1) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            throw AppError.message("Owned native listener setup failed")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent("s").path)
        worker = Task.detached {
            defer { close(fd) }
            let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
            var client: Int32 = -1
            while DispatchTime.now().uptimeNanoseconds < deadline {
                client = accept(fd, nil, nil)
                if client >= 0 { break }
                usleep(1000)
            }
            guard client >= 0 else { throw AppError.message("Owned native listener timed out") }
            defer { close(client) }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var time = timeval(tv_sec: 2, tv_usec: 0), one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout.size(ofValue: time)))
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout.size(ofValue: time)))
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
            var request = Data()
            while request.count < 1024 {
                var byte: UInt8 = 0
                guard recv(client, &byte, 1, 0) == 1 else { throw AppError.message("Owned request incomplete") }
                if byte == 10 { break }
                request.append(byte)
            }
            let object = try JSONSerialization.jsonObject(with: request) as! [String: String]
            guard object.count == 1, let nonce = object["nonce"], nonce.count == 32 else {
                throw AppError.message("Owned request was not observation-only")
            }
            var reply = response(nonce); reply.append(10)
            reply.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.send(client, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                    if count <= 0 { break }
                    offset += count
                }
            }
            return request
        }
        transferred = true
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}

extension ApprovalTests {
    func testNativeObservationReadsOwnedPrivateSocketAndRejectsAliases() async throws {
        let server = try NativeObservationServer { Data("{\"nonce\":\"\($0)\"}".utf8) }
        let alias = server.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: server.path)
        do { _ = try await CodexNativeObservation.query(path: alias.path); throw AppError.message("Alias unexpectedly accepted") }
        catch { try expect(!error.localizedDescription.contains("unexpectedly accepted")) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.root.path)
        do { _ = try await CodexNativeObservation.query(path: server.path); throw AppError.message("Public parent unexpectedly accepted") }
        catch { try expect(!error.localizedDescription.contains("unexpectedly accepted")) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.root.path)
        let observed = try await CodexNativeObservation.query(path: server.path)
        try expectEqual(observed.peer.identity.pid, UInt32(getpid()))
        let reply = try JSONSerialization.jsonObject(with: observed.data) as! [String: String]
        try expectEqual(reply["nonce"], observed.nonce)
        _ = try await server.worker.value
    }

    func testNativeObservationBoundsOversizedResponse() async throws {
        let server = try NativeObservationServer { _ in Data(repeating: 120, count: 1_048_578) }
        do { _ = try await CodexNativeObservation.query(path: server.path); throw AppError.message("Oversized response unexpectedly accepted") }
        catch { try expect(!error.localizedDescription.contains("unexpectedly accepted")) }
        _ = try await server.worker.value
    }

    func testNativeObservationCancellationClosesPendingRead() async throws {
        let (signal, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let server = try NativeObservationServer { _ in
            continuation.yield(()); Thread.sleep(forTimeInterval: 0.4)
            return Data("{}".utf8)
        }
        let request = Task { try await CodexNativeObservation.query(path: server.path) }
        defer { request.cancel() }
        let ready = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = signal.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask { try? await Task.sleep(nanoseconds: 2_000_000_000); return false }
            let ready = await group.next() ?? false
            group.cancelAll()
            return ready
        }
        try expect(ready)
        let start = DispatchTime.now().uptimeNanoseconds
        request.cancel()
        do { _ = try await request.value; throw AppError.message("Cancelled observation returned a response") }
        catch { try expect(error is CancellationError) }
        try expect(DispatchTime.now().uptimeNanoseconds - start < 1_000_000_000)
        _ = try await server.worker.value
    }

    func testNativeObservationUsesOneWholeReadDeadline() async throws {
        let server = try NativeObservationServer { _ in
            Thread.sleep(forTimeInterval: 3)
            return Data("{}".utf8)
        }
        let start = DispatchTime.now().uptimeNanoseconds
        do { _ = try await CodexNativeObservation.query(path: server.path); throw AppError.message("Late response unexpectedly accepted") }
        catch { try expect(!error.localizedDescription.contains("unexpectedly accepted")) }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        try expect(elapsed >= 1_500_000_000 && elapsed < 4_000_000_000)
        _ = try await server.worker.value
    }
}

enum NativeConnectionProbe {
    private static func selected(_ pair:CodexNativeRuntimePair,threadID:String)async throws {
        try await Task.detached {
            let lease=try CodexNativeSelectedInputLease(path:pair.serverControlSocket,expected:pair.connection,threadIDs:[threadID])
            defer{lease.close()}
            try lease.status();try lease.renew()
            let reply:[String:Any]=["paused":true,"threadIds":[threadID],"migrationAuthorized":false]
            try FileHandle.standardOutput.write(contentsOf:JSONSerialization.data(withJSONObject:reply)+Data([10]))
            var input=pollfd(fd:STDIN_FILENO,events:Int16(POLLIN),revents:0)
            guard poll(&input,1,5000)>0,readLine()=="release" else{throw AppError.message("Owned selected release command missing")}
            try lease.release()
            try FileHandle.standardOutput.write(contentsOf:Data("{\"released\":true,\"migrationAuthorized\":false}\n".utf8))
        }.value
    }
    private static func operate(_ binding:CodexNativeDisplayedConnection,path:String)async throws {
        try await Task.detached {
            let hold=try CodexNativeTerminalInputHold(path:path,expected:binding)
            defer{hold.close()}
            try hold.pause();try hold.status();try hold.renew()
            try FileHandle.standardOutput.write(contentsOf:Data("{\"paused\":true,\"migrationAuthorized\":false}\n".utf8))
            var input=pollfd(fd:STDIN_FILENO,events:Int16(POLLIN),revents:0)
            guard poll(&input,1,5000)>0,readLine()=="release" else{throw AppError.message("Owned release command missing")}
            try hold.release()
            try FileHandle.standardOutput.write(contentsOf:Data("{\"released\":true,\"migrationAuthorized\":false}\n".utf8))
        }.value
    }
    @MainActor static func runIfRequested() async -> Bool {
        let inputHold = CommandLine.arguments.firstIndex(of: "--native-terminal-input-hold")
        let runtimeHold=CommandLine.arguments.firstIndex(of:"--native-runtime-input-hold")
        let runtimeSelected=CommandLine.arguments.firstIndex(of:"--native-runtime-selected-input-lease")
        let runtime=runtimeSelected ?? runtimeHold ?? CommandLine.arguments.firstIndex(of:"--native-runtime-resolve")
        guard let index = runtime ?? inputHold ?? CommandLine.arguments.firstIndex(of: "--native-binding-observe") else { return false }
        do {
            if runtime != nil {
                guard index+4<CommandLine.arguments.count,let tuiPID=Int32(CommandLine.arguments[index+3]),
                      let serverPID=Int32(CommandLine.arguments[index+4]) else{throw AppError.message("Owned root home and PIDs required")}
                let pair=try await CodexNativeRuntimePair.resolve(root:CommandLine.arguments[index+1],home:CommandLine.arguments[index+2],tuiPID:tuiPID,serverPID:serverPID)
                if runtimeSelected != nil {
                    guard index+5<CommandLine.arguments.count else{throw AppError.message("Owned selected thread ID required")}
                    try await selected(pair,threadID:CommandLine.arguments[index+5])
                }else if runtimeHold != nil {try await operate(pair.connection,path:pair.tuiControlSocket)}
                else {
                    let result:[String:Any]=["verified":true,"connectionID":pair.connection.connectionID,
                        "tuiPID":pair.connection.tuiPeer.pid,"serverPID":pair.connection.serverPeer.pid,
                        "tuiInventorySocket":pair.tuiInventorySocket,"serverInventorySocket":pair.serverInventorySocket,
                        "tuiControlSocket":pair.tuiControlSocket,"serverControlSocket":pair.serverControlSocket,
                        "membershipComplete":false,"migrationAuthorized":false]
                    print(String(decoding:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),as:UTF8.self))
                }
                return true
            }
            guard index + 2 < CommandLine.arguments.count else { throw AppError.message("Two owned observation paths required") }
            let binding = try await CodexNativeDisplayedConnection.observe(
                tuiSocket: CommandLine.arguments[index + 1], serverSocket: CommandLine.arguments[index + 2])
            if inputHold != nil {
                guard index + 3 < CommandLine.arguments.count else { throw AppError.message("Owned hold socket required") }
                let path = CommandLine.arguments[index + 3]
                try await operate(binding,path:path)
                return true
            }
            let result: [String: Any] = ["verified": true, "connectionID": binding.connectionID,
                "tuiPID": binding.tuiPeer.pid, "serverPID": binding.serverPeer.pid,
                "membershipComplete": false, "migrationAuthorized": false]
            print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
        } catch {
            print("{\"verified\":false,\"migrationAuthorized\":false}")
            exit(1)
        }
        return true
    }
}
#endif
