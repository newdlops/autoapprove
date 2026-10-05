import Foundation
import Darwin
import TerminalInputSupport

public enum TerminalInputStatus: Equatable, Sendable {
    case notInstalled, available, requiresApproval, unavailable(String)
    public var message: String {
        switch self {
        case .notInstalled: return "Terminal 직접 입력 연결이 필요합니다. Mac 앱에서 등록하고 로그인 항목 설정에서 허용합니다."
        case .available: return "원본 터미널 직접 입력 연결됨 · 손쉬운 사용 권한 없이 사용합니다."
        case .requiresApproval: return TerminalInputInstaller.Result.requiresApproval.message
        case .unavailable(let message): return message
        }
    }
    public var available: Bool { self == .available }
}

/// Read-only probing never installs a service or requests a macOS permission.
public final class TerminalInputClient: @unchecked Sendable {
    public static let shared = TerminalInputClient()
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var status: TerminalInputStatus = .notInstalled
    private var refreshAt = 0.0
    private var refreshing = false
    private init() { }
    public var state: TerminalInputStatus {
        refreshIfNeeded(); lock.lock(); defer { lock.unlock() }; return status
    }
    public var isAvailable: Bool { state.available }

    public func refreshIfNeeded(force: Bool = false) {
        lock.lock()
        guard !refreshing, force || TTYInputConfiguration.uptime >= refreshAt else { lock.unlock(); return }
        refreshing = true; refreshAt = TTYInputConfiguration.uptime + 2
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let next = self.probe()
            self.lock.lock(); self.status = next; self.refreshing = false; self.lock.unlock()
        }
    }
    /// Called by explicit Mac setup off the main thread to avoid a stale cached
    /// state causing an unnecessary second registration of a healthy service.
    public func refreshNow() -> TerminalInputStatus {
        let next = probe()
        lock.lock(); status = next; refreshAt = TTYInputConfiguration.uptime + 2; lock.unlock()
        return next
    }
    private func probe() -> TerminalInputStatus {
        let legacy = FileManager.default.fileExists(atPath: TTYInputConfiguration.helperPath)
        if !legacy {
            switch TerminalInputInstaller.registrationState {
            case .requiresApproval: return .requiresApproval
            case .enabled: break
            case .notRegistered, .missingBundle: return .notInstalled
            }
        }
        do {
            let connection = try signedConnection(), result = ReplyBox<Int32>()
            let object = connection.remoteObjectProxyWithErrorHandler { result.finish(.failure($0)) } as? TerminalInputServiceProtocol
            guard let object else { throw AppError.message("터미널 입력 서비스에 연결하지 못했습니다.") }
            object.status { result.finish(.success($0)) }
            guard try result.wait(seconds: 1.5) == 0 else { throw AppError.message("터미널 입력 서비스의 실행 권한을 확인하지 못했습니다.") }
            return .available
        } catch { return .unavailable("터미널 입력 서비스에 연결하지 못했습니다. Mac 연결 설정에서 실행 상태와 백그라운드 실행 허용을 확인해주세요.") }
    }
    private func signedConnection() throws -> NSXPCConnection {
        lock.lock(); defer { lock.unlock() }
        if let connection { return connection }
        let requirement = try TTYInputSigning.peerRequirements(ownIdentifiers: [TTYInputConfiguration.appIdentifier, TTYInputConfiguration.cliIdentifier],
            peerIdentifiers: [TTYInputConfiguration.helperIdentifier])
        let value = NSXPCConnection(machServiceName: TTYInputConfiguration.service, options: .privileged)
        value.setCodeSigningRequirement(requirement)
        value.remoteObjectInterface = NSXPCInterface(with: TerminalInputServiceProtocol.self)
        value.invalidationHandler = { [weak self, weak value] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            if self.connection === value {
                self.connection = nil; self.status = .unavailable("터미널 입력 서비스와 연결이 끊겼습니다. Mac 연결 설정에서 확인해주세요.")
            }
        }
        value.interruptionHandler = { [weak self] in
            guard let self else { return }; self.lock.lock()
            self.status = .unavailable("터미널 입력 서비스가 중단되었습니다. 보낸 키를 다시 전송하지 말고 원본 터미널을 확인해주세요.")
            self.lock.unlock()
        }
        connection = value; value.activate(); return value
    }
    public func deliver(_ request: TTYInputRequest) throws -> TTYInputReply {
        guard isAvailable else { throw RemoteHTTPError(409, state.message) }
        let connection = try signedConnection(), result = ReplyBox<Data>()
        let data = try JSONEncoder().encode(request)
        guard let object = connection.remoteObjectProxyWithErrorHandler({ result.finish(.failure($0)) }) as? TerminalInputServiceProtocol else {
            throw RemoteHTTPError(409, "원본 입력 서비스를 확인하지 못해 키를 보내지 않았습니다.")
        }
        object.deliver(data) { result.finish(.success($0)) }
        do {
            let reply = try result.wait(seconds: 2.5)
            guard reply.count <= 1024 else { throw AppError.message("입력 서비스 응답 크기가 잘못되었습니다.") }
            return try JSONDecoder().decode(TTYInputReply.self, from: reply)
        } catch {
            throw RemoteHTTPError(409, "원본 터미널에 일부 입력이 전달되었을 수 있습니다. 전달 결과를 확인하지 못했으므로 다시 보내지 말고 화면을 확인해주세요.")
        }
    }
    private final class ReplyBox<Value> {
        private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
        private var value: Result<Value, Error>?
        func finish(_ result: Result<Value, Error>) {
            lock.lock(); defer { lock.unlock() }
            guard value == nil else { return }; value = result; semaphore.signal()
        }
        func wait(seconds: Double) throws -> Value {
            guard semaphore.wait(timeout: .now() + seconds) == .success else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))
            }
            lock.lock(); defer { lock.unlock() }
            return try value!.get()
        }
    }
}
