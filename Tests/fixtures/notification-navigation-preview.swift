import AppKit
import UserNotifications
import AutoApproveCore

@MainActor private final class NavigationPreview:NSObject,NSApplicationDelegate {
    private var window:NSWindow!
    private var status:NSTextField!
    private var send:NSButton!
    private var notifications:QuestionNotifications?
    private var engine:ApprovalEngine!
    private var session:AgentSession!
    private var reports:[[String:Any]]=[]
    private let receiverID="local.autoapprove.notification-navigation-host"
    private var root:URL {URL(fileURLWithPath:Bundle.main.object(forInfoDictionaryKey:"NavigationQAData") as! String)}
    private var receiver:Bool {Bundle.main.object(forInfoDictionaryKey:"NavigationQARole") as? String == "receiver"}
    func applicationDidFinishLaunching(_ notification:Notification) {
        window=NSWindow(contentRect:NSRect(x:260,y:240,width:620,height:310),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.title=receiver ? "알림 대상 QA":"AutoApprove 알림 이동 QA"
        let box=NSStackView();box.orientation = .vertical;box.alignment = .leading;box.spacing=16;box.translatesAutoresizingMaskIntoConstraints=false
        let title=NSTextField(labelWithString:receiver ? "알림으로 이동할 검증용 앱":"알림 클릭 → 원본 선택 → 앱 전환")
        title.font = .systemFont(ofSize:20,weight:.semibold);box.addArrangedSubview(title)
        let detail=NSTextField(wrappingLabelWithString:"실제 Terminal·사용자 세션을 조회하거나 조작하지 않습니다. 생산 알림 이동 코드와 합성 세션으로 검증합니다.")
        box.addArrangedSubview(detail)
        status=NSTextField(wrappingLabelWithString:receiver ? "이 앱이 전면으로 오면 전환 성공입니다.":"알림 권한을 조회하고 있습니다…")
        box.addArrangedSubview(status)
        if !receiver {
            let button=NSButton(title:"알림 클릭 경로 시험",target:self,action:#selector(testNavigation));box.addArrangedSubview(button)
            send=NSButton(title:"3초 뒤 시스템 알림 보내기",target:self,action:#selector(sendNotification));send.isEnabled=false;box.addArrangedSubview(send)
            let paths=AppPaths(directory:root.appendingPathComponent("engine"));engine=try! ApprovalEngine(paths:paths,processReader:{[]})
            session=AgentSession(id:"navigation-fixture-exact",agent:.codex,pid:1200,started:"synthetic-start",tty:"/dev/navigation-fixture",cwd:"/tmp/알림 이동 검증",terminal:.terminal)
            session.phase = .idle;session.channel = .terminalScreen;engine.updateDiscovery([session],records:[])
            Task {
                let authorization=await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                let allowed=authorization == .authorized || authorization == .provisional
                status.stringValue=allowed ? "기존 알림 권한 있음 · 시스템 알림 시험 가능":"알림 권한 없음 · 권한 요청 없이 앱 간 전환만 시험합니다."
                if allowed {
                    notifications=QuestionNotifications(engine:engine,openSession:{[weak self] id in try await self?.navigate(id,source:"system-notification")})
                    send.isEnabled=true
                }
                try? JSONSerialization.data(withJSONObject:["authorization":authorization.rawValue,"requestedAuthorization":false]).write(to:root.appendingPathComponent("authorization.json"),options:.atomic)
            }
        }
        window.contentView!.addSubview(box)
        NSLayoutConstraint.activate([box.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:24),box.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-24),box.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:24)])
        window.makeKeyAndOrderFront(nil)
    }
    @objc private func testNavigation() {Task {do {try await navigate(session.id,source:"button")}catch {status.stringValue=error.localizedDescription}}}
    private func navigate(_ id:String,source:String) async throws {
        var events:[String]=[]
        do {
            try await NotificationSessionOpener.open(id,engine:engine) {target in
                events.append("exact-session")
                try await TerminalNavigator.open(target,reveal:{events.append("exact-reveal");return nil},activate:{host in
                    guard host == .terminal,let receiver=NSRunningApplication.runningApplications(withBundleIdentifier:self.receiverID).first else {throw AppError.message("검증용 대상 앱을 먼저 여세요.")}
                    events.append("activation-request")
                    try await TerminalNavigator.activate(receiver)
                    events.append("activation-confirmed")
                })
            }
            status.stringValue="전환 확인 완료 · "+source
            reports.append(["source":source,"success":true,"events":events,"realTerminalOperations":0])
            save()
            Task {
                try? await Task.sleep(for:.seconds(1))
                self.reports.append(["source":source+"-settled","receiverStillFrontmost":NSWorkspace.shared.frontmostApplication?.bundleIdentifier==self.receiverID,"realTerminalOperations":0]);self.save()
            }
        } catch {
            reports.append(["source":source,"success":false,"events":events,"error":error.localizedDescription,"realTerminalOperations":0]);save();throw error
        }
    }
    private func save() {try? JSONSerialization.data(withJSONObject:reports,options:.prettyPrinted).write(to:root.appendingPathComponent("navigation-events.json"),options:.atomic)}
    @objc private func sendNotification() {
        let content=UNMutableNotificationContent();content.title="알림 이동 QA · 합성 세션";content.body="이 알림을 클릭하면 별도 검증 앱으로 이동합니다. 실제 Terminal 작업은 없습니다."
        content.categoryIdentifier="WORK_COMPLETED";content.userInfo=["sessionID":session.id]
        Task {
            do {try await UNUserNotificationCenter.current().add(.init(identifier:"navigation-qa-"+UUID().uuidString,content:content,trigger:UNTimeIntervalNotificationTrigger(timeInterval:3,repeats:false)));status.stringValue="3초 뒤 알림을 보냅니다. 검증용 대상 앱을 앞에 두세요."}
            catch {status.stringValue=error.localizedDescription}
        }
    }
}
@main private struct NotificationNavigationPreview {
    @MainActor static func main() {let app=NSApplication.shared;app.setActivationPolicy(.regular);let delegate=NavigationPreview();app.delegate=delegate;withExtendedLifetime(delegate){app.run()}}
}
