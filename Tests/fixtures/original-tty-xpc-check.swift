// Signed transport fixture. It never opens a TTY or invokes the C writer.
import Foundation
import Darwin
import TerminalInputSupport

private final class Log: @unchecked Sendable {
    let path: String
    let lock = NSLock()
    init(_ path: String) { self.path = path }
    func record(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        let file = try! FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? file.close() }
        _ = try! file.seekToEnd(); try! file.write(contentsOf: Data((message + "\n").utf8))
    }
}
private final class Handler: NSObject, TerminalInputServiceProtocol {
    let caller: UInt32, log: Log
    let router: TTYInputRouter
    init(caller: UInt32, log: Log, router: TTYInputRouter) { self.caller = caller; self.log = log; self.router = router }
    func status(withReply reply: @escaping (Int32) -> Void) { log.record("status:\(caller)"); reply(Int32(geteuid())) }
    func deliver(_ packet: Data, withReply reply: @escaping (Data) -> Void) { router.deliver(packet, caller: caller, withReply: reply) }
}
private final class Delegate: NSObject, NSXPCListenerDelegate {
    let log: Log
    let router: TTYInputRouter
    init(_ log: Log) {
        self.log = log
        router = TTYInputRouter(write: { packet, caller in
            log.record("bytes:\(caller):\(packet.bytes.base64EncodedString())")
            return TTYInputReply(error: 0, written: packet.bytes.count)
        })
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        connection.exportedInterface = NSXPCInterface(with: TerminalInputServiceProtocol.self)
        connection.exportedObject = Handler(caller: connection.effectiveUserIdentifier, log: log, router: router)
        connection.activate(); return true
    }
}
private final class Reply<Value>: @unchecked Sendable {
    let signal = DispatchSemaphore(value: 0), lock = NSLock()
    var result: Result<Value, Error>?
    func finish(_ result: Result<Value, Error>) {
        lock.lock(); defer { lock.unlock() }; guard self.result == nil else { return }
        self.result = result; signal.signal()
    }
    func wait() throws -> Value {
        guard signal.wait(timeout: .now() + 3) == .success else { throw NSError(domain: "XPCFixture.Timeout", code: 1) }
        lock.lock(); defer { lock.unlock() }; return try result!.get()
    }
}
@main struct Check {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        precondition(geteuid() != 0, "This transport fixture must remain unprivileged")
        if arguments[0] == "serve" {
            let requirement = arguments.count > 3 ? arguments[3] : try TTYInputSigning.peerRequirements(
                ownIdentifiers: [TTYInputConfiguration.helperIdentifier],
                peerIdentifiers: [TTYInputConfiguration.appIdentifier, TTYInputConfiguration.cliIdentifier])
            let delegate = Delegate(Log(arguments[2]))
            let listener = NSXPCListener(machServiceName: arguments[1])
            listener.setConnectionCodeSigningRequirement(requirement)
            listener.delegate = delegate; listener.activate()
            withExtendedLifetime(delegate) { RunLoop.current.run() }; return
        }
        let expected = arguments[2] == "accept"
        let requirement = arguments.count > 3 ? arguments[3] : try TTYInputSigning.peerRequirements(
            ownIdentifiers: [TTYInputConfiguration.appIdentifier, TTYInputConfiguration.cliIdentifier, TTYInputConfiguration.helperIdentifier],
            peerIdentifiers: [TTYInputConfiguration.helperIdentifier])
        let connection = NSXPCConnection(machServiceName: arguments[1], options: [])
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: TerminalInputServiceProtocol.self)
        connection.activate(); defer { connection.invalidate() }
        let status = Reply<Int32>()
        let proxy = connection.remoteObjectProxyWithErrorHandler { status.finish(.failure($0)) } as! TerminalInputServiceProtocol
        proxy.status { status.finish(.success($0)) }
        do {
            let uid = try status.wait()
            guard expected else { throw NSError(domain: "XPCFixture.UntrustedPeerAccepted", code: 1) }
            precondition(uid == Int32(geteuid()))
        } catch {
            if expected || (error as NSError).domain == "XPCFixture.UntrustedPeerAccepted" { throw error }
            print("PASS: unauthenticated peer refused"); return
        }
        let identity = TTYInputIdentity(pid: 91, processGroup: 91, uid: getuid(), effectiveUID: geteuid(), device: 42,
            startSeconds: 1, startMicroseconds: 2)
        let request = TTYInputRequest(identity: identity, tty: "/dev/ttys123", bytes: Data("한글🙂\u{1b}[D\r".utf8),
            deadline: TTYInputConfiguration.uptime + 2)
        let delivered = Reply<Data>()
        let sender = connection.remoteObjectProxyWithErrorHandler { delivered.finish(.failure($0)) } as! TerminalInputServiceProtocol
        sender.deliver(try JSONEncoder().encode(request)) { delivered.finish(.success($0)) }
        let response = try JSONDecoder().decode(TTYInputReply.self, from: delivered.wait())
        precondition(response.error == 0 && response.written == request.bytes.count)
        print("PASS: publisher-bound peer and exact UTF-8 packet accepted")
    }
}
