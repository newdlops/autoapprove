import AppKit
import Combine
import UserNotifications
import AutoApproveCore

@MainActor final class QuestionNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private let center: UNUserNotificationCenter
    private let engine: ApprovalEngine
    private let openSession: (String) async throws -> Void
    private var subscription: AnyCancellable?
    private var activationObserver: NSObjectProtocol?
    private var tracker = AttentionTracker()
    private var active: [String: AttentionRequest] = [:]
    private var submitted = Set<String>()
    private var failed = Set<String>()
    private var clearedRead = Set<String>()
    private var deliveries: [String: Task<Void, Never>] = [:]
    private var deliveryTokens: [String: UUID] = [:]
    private var deliveryStartedAt: [String: Date] = [:]
    private var deliveryDeadlines: [String: Date] = [:]
    private static let category = "MANUAL_ANSWER"
    private static let completionCategory = "WORK_COMPLETED"
    private static let openAction = "OPEN_TERMINAL"

    var allowed: Bool { authorization == .authorized || authorization == .provisional }
    var status: String {
        if busy { return "macOS 권한 창에서 알림을 허용해주세요" }
        switch authorization {
        case .authorized, .provisional: return "허용됨 · 작업 중단·완료와 오래 기다리는 질문을 알립니다"
        case .denied: return "알림 꺼짐 · 시스템 설정에서 허용해주세요"
        default: return "알림 허용 필요"
        }
    }

    init(engine: ApprovalEngine, center: UNUserNotificationCenter = .current(),
         openSession: ((String) async throws -> Void)? = nil) {
        self.engine = engine; self.center = center
        self.openSession = openSession ?? { id in
            await engine.refresh()
            // A notification can cold-launch the app while its first scan is in flight.
            for _ in 0..<50 {
                if engine.initialDiscoveryComplete { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let session = try AttentionRequest.target(sessionID: id, sessions: engine.snapshot.sessions)
            try await TerminalNavigator.open(session, engine: engine)
        }
        super.init()
        center.delegate = self
        let action = UNNotificationAction(identifier: Self.openAction, title: "터미널 열기", options: [.foreground])
        center.setNotificationCategories(Set([Self.category, Self.completionCategory].map {
            UNNotificationCategory(identifier: $0, actions: [action], intentIdentifiers: [])
        }))
        subscription = engine.$snapshot.sink { [weak self] snapshot in self?.update(snapshot) }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == Bundle.main.bundleIdentifier else { return }
            Task { @MainActor in await self?.refreshAuthorization() }
        }
        Task { await refreshAuthorization(); if authorization == .notDetermined { await requestAuthorization() } }
    }

    func requestAuthorization() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { _ = try await center.requestAuthorization(options: [.alert, .sound]); error = nil }
        catch { self.error = "알림 권한을 확인하지 못했습니다. \(error.localizedDescription)" }
        await refreshAuthorization()
    }

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
        if !allowed {
            for task in deliveries.values { task.cancel() }
            deliveries.removeAll()
            deliveryTokens.removeAll()
        }
        update(engine.snapshot)
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func retryDelivery() async {
        submitted.subtract(failed); failed.removeAll(); error = nil
        await refreshAuthorization()
    }

    private func update(_ snapshot: EngineSnapshot) {
        var requests = tracker.update(snapshot)
        requests.append(contentsOf: AttentionRequest.completions(snapshot))
        var next: [String: AttentionRequest] = [:]
        next.reserveCapacity(requests.count)
        for request in requests { next[request.id] = request }
        let removed = Set(active.keys).subtracting(next.keys)
        for id in removed {
            deliveries.removeValue(forKey: id)?.cancel(); deliveryTokens.removeValue(forKey: id)
            deliveryStartedAt.removeValue(forKey: id); deliveryDeadlines.removeValue(forKey: id)
            submitted.remove(id); failed.remove(id)
        }
        if !removed.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: Array(removed))
            center.removeDeliveredNotifications(withIdentifiers: Array(removed))
        }
        active = next
        var readIDs = Set<String>(), newlyRead = Set<String>()
        for request in requests where engine.isNotificationRead(sessionID: request.originSessionID ?? request.sessionID, sourceKey: request.notificationKey) {
            deliveries.removeValue(forKey: request.id)?.cancel()
            deliveryTokens.removeValue(forKey: request.id)
            deliveryStartedAt.removeValue(forKey: request.id); deliveryDeadlines.removeValue(forKey: request.id)
            submitted.insert(request.id)
            readIDs.insert(request.id)
            if !clearedRead.contains(request.id) { newlyRead.insert(request.id) }
        }
        clearedRead = readIDs
        if !newlyRead.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: Array(newlyRead))
            center.removeDeliveredNotifications(withIdentifiers: Array(newlyRead))
        }
        guard allowed else { return }
        for request in requests where !submitted.contains(request.id) {
            let observedAt = deliveryStartedAt[request.id] ?? Date()
            deliveryStartedAt[request.id] = observedAt
            let deadline = AttentionNotificationSchedule.deadline(kind: request.kind, observedAt: observedAt,
                questionDelay: snapshot.questionNotificationDelay)
            if deliveryDeadlines[request.id] != deadline {
                deliveries.removeValue(forKey: request.id)?.cancel()
                deliveryTokens.removeValue(forKey: request.id)
                deliveryDeadlines[request.id] = deadline
            }
            guard deliveries[request.id] == nil else { continue }
            let token = UUID()
            deliveryTokens[request.id] = token
            deliveries[request.id] = Task { [weak self] in
                let remaining = max(0, deadline.timeIntervalSinceNow)
                if remaining > 0 {
                    do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                }
                guard let self, self.deliveryTokens[request.id] == token,
                      self.deliveryDeadlines[request.id] == deadline,
                      self.active[request.id] != nil, self.allowed,
                      !self.engine.isNotificationRead(sessionID: request.originSessionID ?? request.sessionID, sourceKey: request.notificationKey) else { return }
                let content = UNMutableNotificationContent()
                content.title = request.title
                content.subtitle = request.agent
                content.body = String(request.summary.prefix(600))
                content.sound = .default
                content.categoryIdentifier = request.kind == .completion ? Self.completionCategory : Self.category
                content.threadIdentifier = request.sessionID
                content.userInfo = ["sessionID": request.sessionID]
                do {
                    try await self.center.add(UNNotificationRequest(identifier: request.id, content: content, trigger: nil))
                    if self.active[request.id] == nil || Task.isCancelled {
                        self.center.removePendingNotificationRequests(withIdentifiers: [request.id])
                        self.center.removeDeliveredNotifications(withIdentifiers: [request.id])
                    } else { self.submitted.insert(request.id); self.error = nil }
                } catch {
                    // Avoid retrying on every two-second poll; expose an explicit retry.
                    self.submitted.insert(request.id)
                    self.failed.insert(request.id)
                    self.error = "\(request.kind == .completion ? "작업 완료" : "응답") 알림을 보내지 못했습니다. \(error.localizedDescription)"
                }
                if self.deliveryTokens[request.id] == token {
                    self.deliveries.removeValue(forKey: request.id)
                    self.deliveryTokens.removeValue(forKey: request.id)
                    self.deliveryStartedAt.removeValue(forKey: request.id)
                    self.deliveryDeadlines.removeValue(forKey: request.id)
                }
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let id = notification.request.identifier
        Task { @MainActor [weak self] in
            guard let self, let request = self.active[id],
                  !self.engine.isNotificationRead(sessionID: request.originSessionID ?? request.sessionID, sourceKey: request.notificationKey) else {
                completionHandler([]); return
            }
            completionHandler([.banner, .list, .sound])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let sessionID = response.notification.request.content.userInfo["sessionID"] as? String
        Task { @MainActor [weak self] in
            defer { completionHandler() }
            guard let self, let sessionID,
                  action == UNNotificationDefaultActionIdentifier || action == Self.openAction else { return }
            do { try await self.openSession(sessionID); try self.engine.markNotificationsRead(sessionID) }
            catch {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "터미널을 열지 못했습니다"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "확인").toolTip = "터미널 이동 오류 안내를 닫습니다."
                alert.runModal()
            }
        }
    }
}
