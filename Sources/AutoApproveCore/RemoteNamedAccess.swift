import Foundation
import SystemConfiguration
import dnssd

/// A CNAME follows macOS's existing Bonjour host records when DHCP changes the IP.
/// Unique registration reports conflicts; it never changes the Mac's host name.
@MainActor final class RemoteDNSAlias {
    private final class CallbackContext: @unchecked Sendable {
        weak var owner: RemoteDNSAlias?
        init(owner: RemoteDNSAlias) { self.owner = owner }
    }
    // DNS-SD cleanup and callbacks must use the queue passed to SetDispatchQueue.
    // The context outlives queued cleanup, so callbacks can safely see a nil owner.
    private final class Lease: @unchecked Sendable {
        var ref: DNSServiceRef?
        let context: CallbackContext
        init(ref: DNSServiceRef, context: CallbackContext) { self.ref = ref; self.context = context }
        func cancel() {
            dispatchPrecondition(condition: .onQueue(.main))
            if let ref { DNSServiceRefDeallocate(ref); self.ref = nil }
        }
    }
    let hostname: String
    private(set) var ready = false
    private var target: String?
    private var lease: Lease?
    private var retry: Task<Void, Never>?
    private var queryDeadline: Task<Void, Never>?
    private let checkExistingName: Bool
    private let onChange: @MainActor () -> Void
    init(hostname: String, checkExistingName: Bool = false, onChange: @escaping @MainActor () -> Void) {
        self.hostname = hostname; self.checkExistingName = checkExistingName; self.onChange = onChange
    }
    deinit {
        retry?.cancel()
        queryDeadline?.cancel()
        let remaining = lease
        DispatchQueue.main.async { remaining?.cancel() }
    }
    func configure(target: String?) {
        guard self.target != target else { return }
        self.target = target; retry?.cancel(); retry = nil
        queryDeadline?.cancel(); queryDeadline = nil
        lease?.cancel(); lease = nil
        let changed = ready; ready = false
        if target != nil { register() }
        if changed { onChange() }
    }
    private func register() {
        guard target?.lowercased() != hostname.lowercased() + "." else { return }
        if checkExistingName { queryExistingName() } else { publish() }
    }
    private func queryExistingName() {
        guard target != nil, lease == nil else { return }
        let context = CallbackContext(owner: self)
        var ref: DNSServiceRef?
        let error = DNSServiceQueryRecord(&ref, DNSServiceFlags(kDNSServiceFlagsForceMulticast), 0, hostname + ".",
                                         UInt16(kDNSServiceType_CNAME), UInt16(kDNSServiceClass_IN), { _, flags, _, error, _, _, _, count, bytes, _, context in
            guard let context else { return }
            let data = bytes.map { Data(bytes: $0, count: Int(count)) }
            MainActor.assumeIsolated {
                Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue().owner?.queried(flags: flags, error: error, data: data)
            }
        }, Unmanaged.passUnretained(context).toOpaque())
        guard error == kDNSServiceErr_NoError, let ref else { scheduleRetry(); return }
        guard DNSServiceSetDispatchQueue(ref, .main) == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(ref); scheduleRetry(); return
        }
        lease = Lease(ref: ref, context: context)
        // Query detects existing local aliases too; the registration's unique
        // probes remain responsible for simultaneous claims by different Macs.
        queryDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            self?.finishQueryAndPublish()
        }
    }
    private func queried(flags: DNSServiceFlags, error: DNSServiceErrorType, data: Data?) {
        guard target != nil else { return }
        if error == kDNSServiceErr_NoSuchRecord { finishQueryAndPublish(); return }
        guard error == kDNSServiceErr_NoError else { completed(error); return }
        guard flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, let data,
              let target, let expected = Self.cnameRecord(target) else { return }
        // DNS names compare without ASCII case; label-length bytes are below 64.
        func canonical(_ value: Data) -> [UInt8] { value.map { (65...90).contains($0) ? $0 + 32 : $0 } }
        if canonical(data) != canonical(expected) { completed(DNSServiceErrorType(kDNSServiceErr_NameConflict)) }
        // Keep collecting for the query window: a responder can have more than
        // one cached CNAME, and a matching entry must not hide a conflicting one.
    }
    private func finishQueryAndPublish() {
        guard target != nil else { return }
        queryDeadline?.cancel(); queryDeadline = nil
        lease?.cancel(); lease = nil
        publish()
    }
    private func publish() {
        guard let target, lease == nil, let data = Self.cnameRecord(target) else { return }
        var ref: DNSServiceRef?
        guard DNSServiceCreateConnection(&ref) == kDNSServiceErr_NoError, let ref else { scheduleRetry(); return }
        guard DNSServiceSetDispatchQueue(ref, .main) == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(ref); scheduleRetry(); return
        }
        let context = CallbackContext(owner: self)
        lease = Lease(ref: ref, context: context)
        var record: DNSRecordRef?
        let error = data.withUnsafeBytes { bytes in
            DNSServiceRegisterRecord(ref, &record, DNSServiceFlags(kDNSServiceFlagsUnique), 0,
                                     hostname + ".", UInt16(kDNSServiceType_CNAME), UInt16(kDNSServiceClass_IN),
                                     UInt16(data.count), bytes.baseAddress, 30, { _, _, _, error, context in
                guard let context else { return }
                MainActor.assumeIsolated {
                    Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue().owner?.completed(error)
                }
            }, Unmanaged.passUnretained(context).toOpaque())
        }
        if error != kDNSServiceErr_NoError { completed(error) }
    }
    private func completed(_ error: DNSServiceErrorType) {
        queryDeadline?.cancel(); queryDeadline = nil
        let previous = ready
        if error == kDNSServiceErr_NoError { ready = true; retry?.cancel(); retry = nil }
        else {
            ready = false; lease?.cancel(); lease = nil
            scheduleRetry()
        }
        if previous != ready { onChange() }
    }
    private func scheduleRetry() {
        guard target != nil, retry == nil else { return }
        retry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self else { return }
            self.retry = nil; self.register()
        }
    }
    static func cnameRecord(_ hostname: String) -> Data? {
        let labels = hostname.hasSuffix(".") ? hostname.dropLast().split(separator: ".", omittingEmptySubsequences: false) : hostname.split(separator: ".", omittingEmptySubsequences: false)
        var bytes = Data()
        for label in labels {
            let data = Data(label.utf8)
            guard !data.isEmpty, data.count <= 63 else { return nil }
            bytes.append(UInt8(data.count)); bytes.append(data)
        }
        bytes.append(0)
        return bytes.count <= 255 ? bytes : nil
    }
}

@MainActor final class RemoteNamedAccess {
    nonisolated static let portalHost = "autoapprove.local"
    private let sharedHost: String
    let personalHost: String?
    private let personal: RemoteDNSAlias?
    private let portal: RemoteDNSAlias
    var ownsPortal: Bool { portal.ready }
    var personalReady: Bool { personal?.ready == true }
    init(nodeID: String, portalHost: String = RemoteNamedAccess.portalHost, onChange: @escaping @MainActor () -> Void) {
        sharedHost = portalHost
        personalHost = Self.personalHost(nodeID)
        personal = personalHost.map { RemoteDNSAlias(hostname: $0, onChange: onChange) }
        portal = RemoteDNSAlias(hostname: portalHost, checkExistingName: true, onChange: onChange)
    }
    func update(port: UInt16, anotherPortal: Bool, preferred: Bool = true) {
        let target = (SCDynamicStoreCopyLocalHostName(nil) as String?).map { $0 + ".local." }
        personal?.configure(target: target)
        // One of the standard-port Macs owns the shared address. DNS-SD resolves
        // simultaneous claims. An older owner explicitly releases its lease when
        // a verified newer standard-port Mac can provide the shared address.
        portal.configure(target: port == 8765 && preferred && (!anotherPortal || ownsPortal) ? target : nil)
    }
    func stop() { personal?.configure(target: nil); portal.configure(target: nil) }
    static func personalHost(_ nodeID: String) -> String? {
        guard let id = UUID(uuidString: nodeID) else { return nil }
        return "autoapprove-" + id.uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased() + ".local"
    }
    func urls(port: UInt16, anotherPortal: Bool) -> [String] {
        var urls: [String] = []
        if ownsPortal || anotherPortal { urls.append("http://\(sharedHost):8765") }
        if personalReady, let personalHost { urls.append("http://\(personalHost):\(port)") }
        return urls
    }
}
