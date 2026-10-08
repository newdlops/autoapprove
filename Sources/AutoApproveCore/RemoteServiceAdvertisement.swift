import Foundation
import dnssd

/// Advertising is independent of the HTTP listener: a DNS daemon failure must not close web connections.
@MainActor public protocol RemoteServiceAdvertising: AnyObject {
    func publish(name: String, type: String, port: UInt16, txt: Data, onChange: @escaping @MainActor (Bool) -> Void)
    func stop()
}

@MainActor final class RemoteServiceAdvertisement: RemoteServiceAdvertising {
    private final class Context: @unchecked Sendable {
        weak var owner: RemoteServiceAdvertisement?
        init(_ owner: RemoteServiceAdvertisement) { self.owner = owner }
    }
    private final class Lease: @unchecked Sendable {
        var ref: DNSServiceRef?
        let context: Context
        init(_ ref: DNSServiceRef, _ context: Context) { self.ref = ref; self.context = context }
        func cancel() {
            dispatchPrecondition(condition: .onQueue(.main))
            if let ref { DNSServiceRefDeallocate(ref); self.ref = nil }
        }
    }
    private struct Record: Equatable { var name: String; var type: String; var port: UInt16; var txt: Data }
    private var record: Record?
    private var lease: Lease?
    private var retry: Task<Void, Never>?
    private var onChange: (@MainActor (Bool) -> Void)?
    deinit { retry?.cancel(); let remaining = lease; DispatchQueue.main.async { remaining?.cancel() } }

    func publish(name: String, type: String, port: UInt16, txt: Data, onChange: @escaping @MainActor (Bool) -> Void) {
        let next = Record(name: name, type: type, port: port, txt: txt)
        self.onChange = onChange
        guard record != next else { return }
        stopRegistration(); record = next; register()
    }
    func stop() { record = nil; onChange = nil; stopRegistration() }
    private func stopRegistration() {
        retry?.cancel(); retry = nil; lease?.cancel(); lease = nil
    }
    private func register() {
        guard let record, lease == nil, record.txt.count <= Int(UInt16.max) else { return }
        let context = Context(self)
        var ref: DNSServiceRef?
        let error = record.txt.withUnsafeBytes { bytes in
            DNSServiceRegister(&ref, DNSServiceFlags(kDNSServiceFlagsNoAutoRename), 0, record.name, record.type, "local.", nil,
                record.port.bigEndian, UInt16(record.txt.count), bytes.baseAddress, { _, _, error, _, _, _, context in
                    guard let context else { return }
                    MainActor.assumeIsolated {
                        let value = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue()
                        value.owner?.completed(error, context: value)
                    }
                }, Unmanaged.passUnretained(context).toOpaque())
        }
        guard error == kDNSServiceErr_NoError, let ref else { onChange?(false); scheduleRetry(); return }
        lease = Lease(ref, context)
        guard DNSServiceSetDispatchQueue(ref, .main) == kDNSServiceErr_NoError else {
            lease?.cancel(); lease = nil; onChange?(false); scheduleRetry(); return
        }
    }
    private func completed(_ error: DNSServiceErrorType, context: Context) {
        guard lease?.context === context, record != nil else { return }
        if error == kDNSServiceErr_NoError { onChange?(true) }
        else { lease?.cancel(); lease = nil; onChange?(false); scheduleRetry() }
    }
    private func scheduleRetry() {
        guard record != nil, retry == nil else { return }
        retry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self else { return }
            self.retry = nil; self.register()
        }
    }
}
