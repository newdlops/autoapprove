import Foundation
import Darwin
import TerminalInputSupport

private final class SaturationProbe: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let lock = NSLock()
    private var values = [TTYInputReply]()
    func record(_ value: TTYInputReply) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    var outcomes: [TTYInputReply] { lock.lock(); defer { lock.unlock() }; return values }
}

@main struct Check {
    static func main() throws {
        let publisher = String(repeating: "a", count: 40)
        let requirement = try TTYInputSigning.requirement(publisherSHA1: publisher, peerIdentifier: TTYInputConfiguration.appIdentifier)
        precondition(requirement == "identifier \"local.autoapprove.mac\" and certificate leaf = H\"\(publisher)\"")
        do { _ = try TTYInputSigning.requirement(publisherSHA1: "-", peerIdentifier: TTYInputConfiguration.appIdentifier); fatalError("Ad-hoc publisher accepted") } catch { }
        do { _ = try TTYInputSigning.requirement(publisherSHA1: publisher, peerIdentifier: "untrusted.app"); fatalError("Unknown peer accepted") } catch { }
        do { _ = try TTYInputSigning.peerRequirement(ownIdentifier: TTYInputConfiguration.appIdentifier, peerIdentifier: TTYInputConfiguration.helperIdentifier); fatalError("Unsigned fixture accepted") } catch { }
        let identity = TTYInputIdentity(pid: 91, processGroup: 91, uid: 501, effectiveUID: 501,
            device: 42, startSeconds: 1, startMicroseconds: 2)
        let request = TTYInputRequest(identity: identity, tty: "/dev/ttys123", bytes: Data("한글🙂\u{1b}[D\r".utf8), deadline: 12)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(TTYInputRequest.self, from: data)
        precondition(decoded == request)
        var writes = 0
        let router = TTYInputRouter(clock: { 10 }, write: { value, caller in
            precondition(value == request && caller == 501); writes += 1
            return TTYInputReply(error: 0, written: value.bytes.count)
        })
        func reply(_ value: Data, caller: UInt32 = 501) throws -> TTYInputReply {
            try JSONDecoder().decode(TTYInputReply.self, from: router.deliver(value, caller: caller))
        }
        let first = try reply(data); precondition(first.error == 0 && first.written == request.bytes.count)
        let duplicate = try reply(data); precondition(duplicate.error == EALREADY && duplicate.written == 0 && writes == 1)
        let invalid = try reply(Data("invalid JSON".utf8)); precondition(invalid.error == EINVAL && writes == 1)
        let oversized = try reply(Data(repeating: 32, count: 20001)); precondition(oversized.error == EINVAL && writes == 1)
        var expired = request; expired.id = UUID(); expired.deadline = 9
        let expiredReply = try reply(JSONEncoder().encode(expired)); precondition(expiredReply.error == ETIMEDOUT)
        var future = request; future.id = UUID(); future.deadline = 100
        let futureReply = try reply(JSONEncoder().encode(future)); precondition(futureReply.error == EINVAL)
        var empty = request; empty.id = UUID(); empty.bytes = Data()
        let emptyReply = try reply(JSONEncoder().encode(empty)); precondition(emptyReply.error == EINVAL)
        var tooLarge = request; tooLarge.id = UUID(); tooLarge.bytes = Data(repeating: 32, count: 8001)
        let largeReply = try reply(JSONEncoder().encode(tooLarge)); precondition(largeReply.error == EINVAL)
        var foreign = request; foreign.id = UUID()
        let foreignReply = try reply(JSONEncoder().encode(foreign), caller: 502); precondition(foreignReply.error == EACCES)
        precondition(writes == 1)
        let partial = TTYInputRouter(clock: { 10 }, write: { _, _ in TTYInputReply(error: ETIMEDOUT, written: 4) })
        let partialResult = try JSONDecoder().decode(TTYInputReply.self, from: partial.deliver(data, caller: 501))
        precondition(partialResult.error == ETIMEDOUT && partialResult.written == 4)
        let repeatedPartial = try JSONDecoder().decode(TTYInputReply.self, from: partial.deliver(data, caller: 501))
        precondition(repeatedPartial.error == EALREADY)
        let saturation = SaturationProbe(), firstDone = DispatchSemaphore(value: 0)
        let busy = TTYInputRouter(clock: { 10 }, write: { value, _ in
            saturation.entered.signal()
            _ = saturation.release.wait(timeout: .now() + 3)
            return .init(error: 0, written: value.bytes.count)
        })
        busy.deliver(data, caller: 501) { response in
            let reply = try! JSONDecoder().decode(TTYInputReply.self, from: response)
            precondition(reply.error == 0); firstDone.signal()
        }
        precondition(saturation.entered.wait(timeout: .now() + 1) == .success)
        let attempts = DispatchGroup()
        for _ in 0..<16 {
            attempts.enter()
            DispatchQueue.global().async {
                busy.deliver(data, caller: 501) { response in
                    let reply = try! JSONDecoder().decode(TTYInputReply.self, from: response)
                    saturation.record(reply); attempts.leave()
                }
            }
        }
        precondition(attempts.wait(timeout: .now() + 0.5) == .success, "An active writer must reject concurrent admission without retaining waiting packets")
        precondition(saturation.outcomes.count == 16 && saturation.outcomes.allSatisfy { $0.error == EBUSY && $0.written == 0 })
        saturation.release.signal()
        precondition(firstDone.wait(timeout: .now() + 1) == .success)
        let chained = SaturationProbe(), chainDone = DispatchSemaphore(value: 0)
        let sequential = TTYInputRouter(clock: { 10 }, write: { value, _ in .init(error: 0, written: value.bytes.count) })
        var next = request; next.id = UUID()
        let nextData = try JSONEncoder().encode(next)
        sequential.deliver(data, caller: 501) { response in
            chained.record(try! JSONDecoder().decode(TTYInputReply.self, from: response))
            sequential.deliver(nextData, caller: 501) { nextResponse in
                chained.record(try! JSONDecoder().decode(TTYInputReply.self, from: nextResponse)); chainDone.signal()
            }
        }
        precondition(chainDone.wait(timeout: .now() + 1) == .success)
        precondition(chained.outcomes.count == 2 && chained.outcomes.allSatisfy { $0.error == 0 && $0.written == request.bytes.count },
            "A completed reply must admit the next packet immediately")
        print("PASS: bounded packets, original identity round-trip, expiry, foreign UID, duplicate and partial outcomes; no OS service or user terminal touched")
    }
}
