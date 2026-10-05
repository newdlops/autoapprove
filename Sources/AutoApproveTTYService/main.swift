import Foundation
import Darwin
import TerminalInputSupport

private final class ConnectionHandler: NSObject, TerminalInputServiceProtocol {
    let caller: UInt32
    let router: TTYInputRouter
    init(caller: UInt32, router: TTYInputRouter) { self.caller = caller; self.router = router }
    func status(withReply reply: @escaping (Int32) -> Void) { reply(Int32(geteuid())) }
    func deliver(_ packet: Data, withReply reply: @escaping (Data) -> Void) {
        router.deliver(packet, caller: caller, withReply: reply)
    }
}
private final class ServiceListener: NSObject, NSXPCListenerDelegate {
    let router = TTYInputRouter()
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // NSXPC validates the publisher-bound requirement before this delegate.
        // The UID is kernel supplied, not a field in the user's request packet.
        guard connection.effectiveUserIdentifier != 0 else { return false }
        connection.exportedInterface = NSXPCInterface(with: TerminalInputServiceProtocol.self)
        connection.exportedObject = ConnectionHandler(caller: connection.effectiveUserIdentifier, router: router)
        connection.activate()
        return true
    }
}

guard geteuid() == 0 else {
    fputs("AutoApproveTTYService requires its explicitly installed system service.\n", stderr)
    exit(1)
}
do {
    let requirement = try TTYInputSigning.peerRequirements(ownIdentifiers: [TTYInputConfiguration.helperIdentifier],
        peerIdentifiers: [TTYInputConfiguration.appIdentifier, TTYInputConfiguration.cliIdentifier])
    let delegate = ServiceListener()
    let listener = NSXPCListener(machServiceName: TTYInputConfiguration.service)
    listener.setConnectionCodeSigningRequirement(requirement)
    listener.delegate = delegate
    listener.activate()
    withExtendedLifetime(delegate) { RunLoop.current.run() }
} catch {
    fputs("AutoApproveTTYService: publisher verification failed.\n", stderr)
    exit(1)
}
