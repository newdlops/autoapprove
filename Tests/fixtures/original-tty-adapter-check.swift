import Foundation
import Darwin
import TerminalInputSupport
#if DEBUG
@testable import AutoApproveCore
#else
import AutoApproveCore
#endif

private final class Sender: @unchecked Sendable {
    private let lock = NSLock()
    private var packets = [TTYInputRequest]()
    var outcome: TTYInputReply?
    var failure: Error?
    func send(_ request: TTYInputRequest) throws -> TTYInputReply {
        lock.lock(); defer { lock.unlock() }
        packets.append(request)
        if let failure { throw failure }
        return outcome ?? TTYInputReply(error: 0, written: request.bytes.count)
    }
    var requests: [TTYInputRequest] { lock.lock(); defer { lock.unlock() }; return packets }
}

#if DEBUG
private final class SetupProbe: @unchecked Sendable {
    var connected = false
    var legacy = false
    var state = TerminalInputInstaller.RegistrationState.notRegistered
    var next = TerminalInputInstaller.RegistrationState.requiresApproval
    var packageFailure = false
    var policyFailure = false
    var registrationFailure = false
    var registrations = 0
    var policyChecks = 0
    var refreshes = 0
    var environment: TerminalInputInstaller.Environment {
        .init(validate: { _, _ in if self.packageFailure { throw AppError.message("invalid package") } },
            connected: { self.connected }, legacyInstalled: { self.legacy }, state: { self.state },
            registrationPolicy: { _, _ in self.policyChecks += 1; if self.policyFailure { throw AppError.message("platform trust denied") } },
            register: { self.registrations += 1; if self.registrationFailure { throw AppError.message("registration failed") }; self.state = self.next },
            refresh: { self.refreshes += 1 })
    }
    func run() throws -> TerminalInputInstaller.Result {
        try TerminalInputInstaller.install(app: URL(fileURLWithPath: "/Applications/AutoApprove.app"),
            ownIdentifier: TTYInputConfiguration.appIdentifier, environment: environment)
    }
}
#endif

@main struct Check {
    static func main() throws {
        func check(_ condition: Bool) { precondition(condition) }
        let original = TTYInputIdentity(pid: 99, processGroup: 99, uid: getuid(), effectiveUID: geteuid(),
            device: 42, startSeconds: 1_700_000_000, startMicroseconds: 71)
        let target = ScreenTarget(tty: "/dev/ttys123", jobPIDs: [99], sourcePID: 99, sourceStarted: original.processStart, sourceIdentity: original)
        func environment(_ sender: Sender, identity: TTYInputIdentity = original, available: Bool = true) -> TerminalDeviceInput.Environment {
            .init(available: { available }, capture: { pid in precondition(pid == 99); return identity }, send: { try sender.send($0) })
        }
        func deliver(_ sender: Sender, input: RemoteTerminalInput, identity: TTYInputIdentity = original,
                     selected: ScreenTarget = target, available: Bool = true, agent: AgentKind = .codex, screen: String = "") throws -> TerminalDelivery {
            try TerminalDeviceInput.deliver(target: selected, agent: agent, input: input, screen: screen,
                environment: environment(sender, identity: identity, available: available))
        }
        func expectHTTP(_ status: Int, _ action: () throws -> Void) {
            do { try action(); preconditionFailure("Expected rejection") }
            catch let error as RemoteHTTPError { precondition(error.status == status) }
            catch { preconditionFailure("Unexpected rejection: \(error)") }
        }
        let characters = RemoteTerminalInput(kind: .characters, text: "한글é🙂", relay: true)
        let sender = Sender(), before = TTYInputConfiguration.uptime
        for input in [characters, .init(kind: .left, relay: true), .init(kind: .enter, relay: true), .init(kind: .interrupt, relay: true)] {
            try check(deliver(sender, input: input) == .sent)
        }
        precondition(sender.requests.map(\.bytes) == [Data("한글é🙂".utf8), Data([2]), Data([13]), Data([3])])
        precondition(sender.requests.allSatisfy { $0.identity == original && $0.tty == target.tty && $0.deadline > before && $0.deadline <= TTYInputConfiguration.uptime + 2.1 })
        precondition(Set(sender.requests.map(\.id)).count == 4)
        let editor = Sender(), claude = Sender(), menu = Sender()
        let keys: [RemoteTerminalInput.Kind] = [.left, .right, .up, .down, .home, .end, .delete, .backspace]
        let dialog = "Would you like to run the following command?\n› 1. Yes, proceed (y)\n  2. No, and tell Codex what to do differently (esc)\nPress enter to confirm or esc to cancel"
        for kind in keys {
            let input = RemoteTerminalInput(kind: kind, relay: true)
            try check(deliver(editor, input: input, screen: "› draft\n  model · context left") == .sent)
            try check(deliver(claude, input: input, agent: .claude) == .sent)
            try check(deliver(menu, input: input, screen: dialog) == .sent)
        }
        precondition(editor.requests.map(\.bytes) == [[2], [6], [16], [14], [1], [5], [27, 91, 51, 126], [127]].map { Data($0) })
        precondition(claude.requests.map(\.bytes) == keys.map { Data(RemoteTerminalInput(kind: $0).bytes.utf8) })
        precondition(menu.requests.map(\.bytes) == keys.map { kind in
            kind == .up ? Data([16]) : kind == .down ? Data([14]) : Data(RemoteTerminalInput(kind: kind).bytes.utf8)
        })
        for change in [
            { (value: inout TTYInputIdentity) in value.pid = 100 },
            { value in value.startSeconds += 1 },
            { value in value.startMicroseconds += 1 },
            { value in value.device += 1 },
            { value in value.uid += 1 },
            { value in value.effectiveUID += 1 },
            { value in value.foregroundGroup = 100 }
        ] {
            var invalid = original; change(&invalid)
            let rejected = Sender()
            try check(deliver(rejected, input: characters, identity: invalid) == .agentMissing)
            precondition(rejected.requests.isEmpty)
        }
        for selected in [ScreenTarget(tty: target.tty), ScreenTarget(tty: target.tty, jobPIDs: [], sourcePID: 99, sourceStarted: original.processStart),
                         ScreenTarget(tty: target.tty, jobPIDs: [99], sourcePID: 99, sourceStarted: "stale", sourceIdentity: original),
                         ScreenTarget(tty: target.tty, jobPIDs: [99], sourcePID: 99, sourceStarted: original.processStart)] {
            let rejected = Sender()
            try check(deliver(rejected, input: characters, selected: selected) == .agentMissing)
            precondition(rejected.requests.isEmpty)
        }
        let unavailable = Sender()
        expectHTTP(409) { _ = try deliver(unavailable, input: characters, available: false) }
        expectHTTP(409) { _ = try deliver(unavailable, input: characters, agent: .shell) }
        expectHTTP(400) { _ = try deliver(unavailable, input: .init(kind: .characters, text: String(repeating: "a", count: 8001), relay: true)) }
        precondition(unavailable.requests.isEmpty)
        for result in [TTYInputReply(error: ETIMEDOUT, written: 2), TTYInputReply(error: 0, written: 1),
                       TTYInputReply(error: 0, written: -1), TTYInputReply(error: 0, written: 8001),
                       TTYInputReply(error: EOPNOTSUPP, written: 0), TTYInputReply(error: EACCES, written: 0)] {
            let rejected = Sender(); rejected.outcome = result
            expectHTTP(409) { _ = try deliver(rejected, input: characters) }
            precondition(rejected.requests.count == 1, "Uncertain or partial input must never retry")
        }
        for error in [ESTALE, ESRCH, ENOENT] {
            let vanished = Sender(); vanished.outcome = .init(error: error, written: 0)
            try check(deliver(vanished, input: characters) == .agentMissing)
            precondition(vanished.requests.count == 1)
        }
        let disconnected = Sender(); disconnected.failure = RemoteHTTPError(409, "transport interrupted")
        expectHTTP(409) { _ = try deliver(disconnected, input: characters) }
        precondition(disconnected.requests.count == 1)

#if DEBUG
        let plistData = try Data(contentsOf: URL(fileURLWithPath: "scripts/resources/local.autoapprove.tty-input.plist"))
        try TerminalInputInstaller.validatePlist(plistData)
        let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as! [String: Any]
        precondition(plist["Label"] as? String == TTYInputConfiguration.service)
        precondition(plist["BundleProgram"] as? String == "Contents/MacOS/AutoApproveTTYService")
        precondition(plist["ProgramArguments"] == nil)
        precondition(plist["MachServices"] as? [String: Bool] == [TTYInputConfiguration.service: true])
        precondition(plist["UserName"] as? String == "root")
        for (key, value) in [("BundleProgram", "/tmp/foreign-service"), ("Label", "foreign-service"), ("UserName", "user"), ("ProgramArguments", ["/bin/sh", "-c", "anything"])] as [(String, Any)] {
            var invalid = plist; invalid[key] = value
            do {
                try TerminalInputInstaller.validatePlist(PropertyListSerialization.data(fromPropertyList: invalid, format: .xml, options: 0))
                preconditionFailure("Unexpected service executable or contract accepted")
            } catch { }
        }
        let existing = SetupProbe(); existing.connected = true; existing.legacy = true
        try check(existing.run() == .alreadyConnected)
        precondition(existing.registrations == 0 && existing.policyChecks == 0 && existing.refreshes == 0)
        let awaiting = SetupProbe(); awaiting.state = .requiresApproval
        try check(awaiting.run() == .requiresApproval)
        precondition(awaiting.registrations == 0 && awaiting.policyChecks == 0)
        let enabled = SetupProbe(); enabled.state = .enabled
        try check(enabled.run() == .registered)
        precondition(enabled.registrations == 0 && enabled.policyChecks == 0 && enabled.refreshes == 1)
        for scenario in 0..<5 {
            let rejected = SetupProbe()
            switch scenario {
            case 0: rejected.packageFailure = true; rejected.connected = true
            case 1: rejected.legacy = true
            case 2: rejected.state = .missingBundle
            case 3: rejected.policyFailure = true
            default: rejected.registrationFailure = true
            }
            do { _ = try rejected.run(); preconditionFailure("Invalid or unauthorized registration accepted") }
            catch { }
            precondition(rejected.registrations == (scenario == 4 ? 1 : 0))
        }
        let fresh = SetupProbe()
        try check(fresh.run() == .requiresApproval)
        precondition(fresh.policyChecks == 1 && fresh.registrations == 1 && fresh.refreshes == 1)
        let immediate = SetupProbe(); immediate.next = .enabled
        try check(immediate.run() == .registered)
        precondition(immediate.registrations == 1)
        precondition(TerminalInputStatus.requiresApproval.message == TerminalInputInstaller.Result.requiresApproval.message)
        print("PASS: original source input guards and exact bytes preserved; bundled daemon contract rejects substituted executables; native registration requires platform trust, preserves existing services and handles approval without administrator shell execution")
#else
        print("PASS: original source input guards, Codex editor/list keys, unchanged Claude bytes and no uncertain-input retries")
#endif
    }
}
