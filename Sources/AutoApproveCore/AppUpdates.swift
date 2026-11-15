import Foundation
import Combine

/// GitHub release discovery and installation, independent of the web listener.
@MainActor public final class AppUpdates: ObservableObject {
    @Published public private(set) var automatic: Bool
    @Published public private(set) var status = PublishedUpdateStatus()
    private weak var engine: ApprovalEngine?
    private let releases: PublishedUpdates
    private var maintenance: Task<Void, Never>?
    private var pending: PublishedReleaseOffer?
    private var epoch = UUID()
    var hasPendingInstallation: Bool { pending != nil }

    init(engine: ApprovalEngine, services: PublishedUpdateServices) {
        self.engine = engine; releases = PublishedUpdates(services: services)
        automatic = (engine.store.value("githubAutomaticUpdates") ?? engine.store.value("lanUpdateEnabled")) != "false"
        status.host = RemoteWebVersion.current
    }

    func start() {
        guard maintenance == nil else { return }
        maintenance = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.automatic, self.status.checkedAt.map({ Date().timeIntervalSince($0) >= 3600 }) ?? true {
                    await self.check()
                }
                self.continueInstallation()
                do { try await Task.sleep(for: .seconds(self.pending == nil ? 60 : 5)) } catch { return }
            }
        }
    }

    func stop() {
        epoch = UUID(); maintenance?.cancel(); maintenance = nil; releases.stop()
        if pending != nil { engine?.updateReceiver.stop() }
        pending = nil; status.update = nil
    }

    public func setAutomatic(_ enabled: Bool) throws {
        guard let engine else { return }
        try engine.store.set("githubAutomaticUpdates", enabled ? "true" : "false")
        automatic = enabled
        if !enabled, pending != nil {
            pending = nil; engine.updateReceiver.stop(); status.update = nil
            status.detail = "자동 적용을 중지했습니다. 받은 파일은 다음 업데이트에 재사용합니다."
        }
        if enabled { Task { await self.check() } }
    }

    public func check() async {
        guard let engine else { return }
        guard !engine.networkIsolated else {
            status.phase = "paused"; status.detail = "네트워크 격리 모드에서는 업데이트 확인을 중지합니다."; return
        }
        let epoch = self.epoch
        status.phase = "checking"; status.detail = "GitHub의 최신 정식 버전을 확인하고 있습니다."
        await releases.check()
        guard self.epoch == epoch, !Task.isCancelled else { return }
        let installation = status.update
        status = releases.status; status.host = RemoteWebVersion.current; status.update = installation
        guard let current = status.host else { return }
        if let offer = releases.record?.offer {
            status.canSync = offer.manifest.release > current && (try? LANUpdateInstallation.currentApp()) != nil
            status.detail = offer.manifest.release > current ? "새 버전 \(offer.manifest.release.version)을 사용할 수 있습니다." : "최신 버전입니다."
            if automatic, status.canSync { apply() }
        } else if status.phase == "ready" {
            status.detail = status.latestVersion?.compare(current.version, options: .numeric) == .orderedDescending
                ? "이 Mac용 업데이트 파일을 준비 중입니다. 다음 확인 때 다시 조회합니다." : "최신 버전입니다."
        }
    }

    public func apply() {
        guard let engine, !engine.networkIsolated, status.canSync, let offer = releases.record?.offer else { return }
        pending = offer; continueInstallation(); start()
    }

    private func continueInstallation() {
        guard let engine, !engine.networkIsolated, let offer = pending else { return }
        let epoch = self.epoch
        engine.updateReceiver.check(nodeID: offer.manifest.nodeID, release: offer.manifest.release,
            routeKey: offer.url.absoluteString, allowTunnelRestart: true,
            authorization: { [weak self] in self?.pending == offer && self?.epoch == epoch && self?.engine?.networkIsolated == false }) { [weak self] path in
                guard let self, self.epoch == epoch, self.pending == offer else { throw CancellationError() }
                if path == "/api/update/manifest" { return try .json(offer.manifest) }
                return try await self.releases.read(path, offer: offer)
            }
    }

    func receive(_ update: LANUpdateStatus) {
        guard pending != nil else { return }
        status.update = update
    }
}
