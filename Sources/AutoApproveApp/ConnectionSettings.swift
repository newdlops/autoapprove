import SwiftUI
import AppKit
import AutoApproveCore

struct ConnectionSettings: View {
    @ObservedObject var engine: ApprovalEngine
    @ObservedObject var notifications: QuestionNotifications
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var notice: String?
    @State private var questionDelayText = ""
    @State private var questionDelayError: String?
    @State private var keepAwakeBusy = false
    @State private var keepAwakeError: String?
    @State private var terminalWindowSharingAllowed = false
    @State private var terminalInputStatus = TerminalInputStatus.notInstalled
    @State private var terminalInputBusy = false
    @State private var terminalInputError: String?
    private var questionDelayValue: Int? { Int(questionDelayText.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var validQuestionDelay: Bool { questionDelayValue.map(EngineSnapshot.questionNotificationDelayRange.contains) ?? false }
    private var helper: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/autoapprove").path }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("연결 설정").font(.title2.weight(.semibold)); Spacer(); Button("완료") { dismiss() }.keyboardShortcut(.defaultAction).help("연결 설정 창을 닫습니다. ⌘W로도 닫을 수 있습니다.") }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    RemoteAccessSettings(engine: engine)
                    Divider()
                    section("tmux로 같은 터미널 공유", icon: "terminal", status: engine.snapshot.health.screen(.tmux).status) {
                        TmuxSharingSettings(installed: TmuxRelay.executable != nil, health: engine.snapshot.health.screen(.tmux),
                            command: TmuxRelay.startCommand,
                            connect: { Task { await engine.connectScreenHost(.tmux) } },
                            disconnect: { engine.disconnectScreenHost(.tmux) })
                    }
                    Divider()
                    section("원본 터미널 화면·입력", icon: "display", status: "기본은 터미널 중계 · Mac 창 보기는 선택 사항입니다.") {
                        TerminalSharingSettings(screenAllowed: terminalWindowSharingAllowed, inputStatus: terminalInputStatus,
                            inputBusy: terminalInputBusy, inputError: terminalInputError,
                            screenAction: requestTerminalScreenSharing, inputAction: requestTerminalInput)
                    }
                    Divider()
                    section("질문 · 작업 완료 알림", icon: "bell", status: notifications.status) {
                        Text("질문이 설정한 시간 동안 미응답 상태로 남거나 작업이 끝나면 알립니다. 그 전에 처리된 질문은 알리지 않습니다. 같은 질문·완료는 한 번만 알리며, 알림을 누르면 해당 터미널을 엽니다.")
                        HStack(spacing: 8) {
                            Text("질문 대기 시간").foregroundStyle(.primary)
                            Spacer()
                            TextField("초", text: $questionDelayText)
                                .textFieldStyle(.roundedBorder).frame(width: 72)
                                .accessibilityLabel("질문 알림 대기 시간(초)")
                                .help("1~3600초로 입력하고 적용하세요. 기본값은 10초입니다.")
                                .onSubmit { saveQuestionDelay() }
                            Text("초")
                            Button("적용") { saveQuestionDelay() }
                                .disabled(!validQuestionDelay || questionDelayValue == engine.snapshot.questionNotificationDelay)
                                .help("대기 중인 질문과 새 질문에 적용하고 앱 재실행 후에도 유지합니다.")
                        }
                        if let questionDelayError {
                            Label(questionDelayError, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                        } else if !questionDelayText.isEmpty && !validQuestionDelay {
                            Label("1~3600초의 숫자로 입력해주세요.", systemImage: "exclamationmark.circle").foregroundStyle(.red)
                        } else {
                            Text("현재 \(engine.snapshot.questionNotificationDelay)초 · 기본 10초 · 작업 완료 알림은 별도로 유지합니다.").font(.caption)
                        }
                        Text("완료 알림은 Claude 훅과 Codex 완료 기록을 사용합니다. 처음부터 대기 중인 세션·중단·프로세스 종료는 완료로 알리지 않습니다.").font(.caption)
                        HStack {
                            if notifications.authorization == .notDetermined {
                                Button("알림 허용") { Task { await notifications.requestAuthorization() } }
                                    .disabled(notifications.busy)
                                    .help(notifications.busy ? "알림 권한을 확인하고 있습니다. macOS 권한 창이 열렸다면 응답해주세요." : "질문·작업 완료 알림과 소리를 허용하는 macOS 권한 창을 엽니다.")
                            }
                            Button("시스템 알림 설정") { notifications.openSettings() }
                                .help("macOS 알림 설정에서 AutoApprove의 배너·소리·미리보기를 변경합니다.")
                        }
                        Text("배너와 소리는 macOS 알림·집중 모드 설정을 따릅니다.").font(.caption)
                        if let error = notifications.error {
                            Text(error).foregroundStyle(.red)
                            Button("알림 다시 확인") { Task { await notifications.retryDelivery() } }
                                .disabled(notifications.busy).help(notifications.busy ? "알림 권한과 전송 상태를 확인하고 있습니다." : "알림 권한을 확인하고 전송에 실패한 알림을 다시 보냅니다.")
                        }
                    }
                    Divider()
                    keepAwakeSection
                    Divider()
                    screenSection(.terminal, icon: "terminal",
                        text: "실행 중인 탭을 연결해 요청을 읽고 해당 탭에만 승인 입력을 전달합니다. 한 번 연결하면 앱을 다시 실행해도 연결을 복원합니다. 처음 연결할 때 macOS의 자동화 권한을 허용해주세요.")
                    Divider()
                    screenSection(.iterm, icon: "apple.terminal",
                        text: "iTerm2 세션을 연결해 요청을 읽고 해당 세션에만 승인 입력을 전달합니다. 분할 창도 세션별로 구분합니다. 한 번 연결하면 앱을 다시 실행해도 연결을 복원합니다. 처음 연결할 때 iTerm2 자동화 권한을 허용해주세요.")
                    Divider()
                    screenSection(.orca, icon: "square.grid.2x2",
                        text: "Orca에 포함된 명령줄 도구로 각 터미널의 현재 화면을 읽고 해당 터미널에만 승인 입력을 전달합니다. 별도 권한은 필요하지 않으며 Orca가 실행 중이어야 합니다. tmux 안의 세션은 위의 tmux 연결을 사용합니다.")
                    Divider()
                    section("Claude Code", icon: "bolt.horizontal", status: engine.snapshot.health.claude) {
                        Text("Terminal·iTerm2·Orca·VS Code 등 모든 터미널에서 권한 요청을 직접 받습니다. 기존 설정을 백업하고 AutoApprove 훅만 추가합니다.")
                        HStack {
                            Button("Claude 훅 설치") {
                                do { try engine.installClaude(executable: helper); notice = "설치했습니다. Claude의 다음 이벤트를 기다립니다. 연결되지 않으면 /hooks에서 설정을 확인하거나 대화를 이어하기 해주세요." }
                                catch { notice = error.localizedDescription }
                            }.disabled(!FileManager.default.isExecutableFile(atPath: helper))
                                .help(FileManager.default.isExecutableFile(atPath: helper) ? "기존 Claude 설정을 백업하고 AutoApprove의 권한 요청·작업 이벤트 훅을 추가합니다." : "앱에 포함된 연결 도구를 찾지 못했습니다. 패키징된 AutoApprove 앱에서 설치하세요.")
                            Button("훅 제거") { do { try engine.removeClaude(); notice = "AutoApprove 훅만 제거했습니다." } catch { notice = error.localizedDescription } }
                                .help("Claude 설정에서 AutoApprove가 추가한 훅을 제거합니다. 다른 훅은 유지합니다.")
                        }
                        Text("앱이 꺼져 있으면 원래 Claude 승인 흐름을 따릅니다.").font(.caption)
                    }
                    Divider()
                    section("VS Code·Cursor", icon: "chevron.left.forwardslash.chevron.right", status: engine.snapshot.health.vscode) {
                        Text("AutoApprove Bridge가 같은 원본 터미널에 화면과 입력을 연결합니다. 이미 실행 중인 명령은 휴대폰의 원본 연결 버튼으로 해당 창을 공유합니다. 새로 시작한 명령의 출력 연결은 앱이 재실행되어도 유지됩니다.")
                        Button("편집기 확장 설치") { installExtension() }.disabled(busy)
                            .help(busy ? "현재 연결 작업이 끝날 때까지 기다려주세요." : "설치된 VS Code·Cursor 계열 편집기에 앱의 AutoApprove Bridge를 설치합니다.")
                    }
                    Divider()
                    section("Codex", icon: "command", status: engine.snapshot.health.codex) {
                        Text("연결된 원본 터미널의 승인 화면을 감지합니다. 휴대폰에서 같은 실행 세션에 직접 입력할 수 있으며 새 CLI를 만들지 않습니다.")
                    }
                    if let notice {
                        Label(notice, systemImage: "info.circle").font(.callout).foregroundStyle(.primary).textSelection(.enabled)
                            .help(notice)
                    }
                }.padding(24)
            }
        }.frame(width: 600, height: 660)
            .onAppear { questionDelayText = String(engine.snapshot.questionNotificationDelay); refreshTerminalPermissions() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshTerminalPermissions() }
            .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in refreshTerminalPermissions() }
            .onChange(of: questionDelayText) { _, _ in questionDelayError = nil }
    }
    private func saveQuestionDelay() {
        guard let seconds = questionDelayValue, validQuestionDelay else {
            questionDelayError = "질문 알림 대기 시간은 1~3600초로 입력해주세요."
            return
        }
        do {
            try engine.setQuestionNotificationDelay(seconds)
            questionDelayText = String(seconds); questionDelayError = nil
        } catch { questionDelayError = "저장하지 못했습니다. \(error.localizedDescription)" }
    }
    @ViewBuilder private var keepAwakeSection: some View {
        let status = engine.snapshot.keepAwake
        section("덮개를 닫아도 계속 작업", icon: "laptopcomputer",
                status: keepAwakeBusy ? "적용하고 있습니다. 관리자 암호 창이 열리면 입력해주세요." : status?.detail ?? "꺼져 있습니다.") {
            Text("자동 승인을 켠 세션이 작업 중이면 덮개를 닫아도 Mac이 잠들지 않습니다. 작업이 모두 끝나고 2분이 지나면 원래대로 돌리고, 그때 덮개가 닫혀 있으면 바로 잠재웁니다. 배터리가 20% 이하이거나 Mac이 뜨거우면 작업 중이어도 원래대로 돌립니다.")
            Toggle("덮개를 닫아도 계속 작업", isOn: Binding(get: { status?.enabled ?? false }, set: { setKeepAwake($0) }))
                .toggleStyle(.switch).disabled(keepAwakeBusy)
                .help(status?.enabled == true ? "끄면 잠자기 금지를 바로 해제하고 macOS의 평소 잠자기로 돌아갑니다."
                    : "켜면 자동 승인 세션이 작업하는 동안 덮개를 닫아도 잠들지 않습니다. 처음에는 관리자 암호를 묻습니다.")
            if status?.phase == .holding, let releaseAt = status?.releaseAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("\(max(0, Int(releaseAt.timeIntervalSince(context.date).rounded(.up))))초 뒤 평소처럼 잠듭니다.")
                        .font(.caption).monospacedDigit()
                }
            }
            if let keepAwakeError { Label(keepAwakeError, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
            Text("처음 켤 때 관리자 암호를 받아, 잠자기 금지(pmset disablesleep)를 켜고 끄는 일과 잠자기만 암호 없이 실행하는 규칙을 설치합니다. 켜 둔 동안에는 Apple 메뉴의 잠자기와 macOS의 배터리 부족 잠자기도 동작하지 않고, AutoApprove의 배터리 하한만 적용됩니다.").font(.caption)
            Text("‘상태 미확인’ 세션은 작업 중으로 보지 않습니다. 덮개를 닫은 채 가방에 넣지 마세요. 앱이 종료되거나 멈추면 별도 감시 프로세스가 원래대로 돌립니다.").font(.caption)
            if status?.ruleFile == true && status?.enabled != true {
                Button("권한 규칙 제거") { removeKeepAwakeRule() }.disabled(keepAwakeBusy)
                    .help("AutoApprove가 설치한 잠자기 금지 권한 규칙을 지웁니다. 관리자 암호가 필요합니다.")
            }
        }
    }
    private func setKeepAwake(_ enabled: Bool) {
        keepAwakeBusy = true; keepAwakeError = nil
        Task {
            do { try await engine.setKeepAwake(enabled) } catch { keepAwakeError = error.localizedDescription }
            keepAwakeBusy = false
        }
    }
    private func removeKeepAwakeRule() {
        keepAwakeBusy = true; keepAwakeError = nil
        Task {
            do { try await engine.removeKeepAwakeRule() } catch { keepAwakeError = error.localizedDescription }
            keepAwakeBusy = false
        }
    }
    @ViewBuilder private func screenSection(_ host: ScreenHost, icon: String, text: String) -> some View {
        let health = engine.snapshot.health.screen(host)
        section(host.title, icon: icon, status: health.status) {
            Text(text)
            HStack {
                Button(health.connected ? "다시 연결" : "\(host.title) 연결") { busy = true; Task { await engine.connectScreenHost(host); busy = false } }.disabled(busy || health.connecting)
                    .help(busy || health.connecting ? "연결 상태를 확인하고 있습니다." : "\(host == .terminal ? "macOS Terminal" : host.title)의 Claude Code·Codex 탭을 연결합니다. 허용한 연결은 앱 재실행 후 복원됩니다.")
                Button("연결 해제") { engine.disconnectScreenHost(host) }.disabled(!health.requested)
                    .help(health.requested ? "\(host.title) 화면 감지와 승인 입력을 중단합니다. 다시 연결하기 전까지 해제 상태를 유지합니다." : "현재 \(host.title) 연결이 꺼져 있습니다.")
            }
        }
    }
    private func refreshTerminalPermissions() {
        terminalWindowSharingAllowed = TerminalWindowCapture.screenPermissionGranted
        terminalInputStatus = TerminalInputClient.shared.state
    }
    private func openPrivacySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
    private func requestTerminalScreenSharing() {
        if terminalWindowSharingAllowed { openPrivacySettings("Privacy_ScreenCapture") }
        else {
            _ = TerminalWindowCapture.requestScreenPermission(); refreshTerminalPermissions()
            notice = "macOS 설정에서 AutoApprove의 화면 공유를 허용해주세요. macOS가 재시작을 요청하면 앱을 다시 연 뒤 휴대폰에서 원본 터미널을 연결하세요."
        }
    }
    private func requestTerminalInput() {
        terminalInputError = nil
        if terminalInputStatus == .requiresApproval {
            TerminalInputInstaller.openApprovalSettings()
            return
        }
        if terminalInputStatus.available {
            TerminalInputClient.shared.refreshIfNeeded(force: true); refreshTerminalPermissions(); return
        }
        terminalInputBusy = true
        Task {
            do {
                let result = try await Task.detached { try TerminalInputInstaller.install() }.value
                notice = result.message
                if result == .requiresApproval {
                    terminalInputStatus = .requiresApproval
                    TerminalInputInstaller.openApprovalSettings()
                }
            } catch { terminalInputError = error.localizedDescription }
            terminalInputBusy = false; refreshTerminalPermissions()
        }
    }
    @ViewBuilder private func section<Content: View>(_ title: String, icon: String, status: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline)
                .help("\(title) 연결 상태: \(status)")
            Text(status).font(.callout.weight(.medium)).textSelection(.enabled)
            content().font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func installExtension() {
        guard let vsix = Bundle.main.url(forResource: "autoapprove-bridge", withExtension: "vsix") else { notice = "확장 파일이 없습니다. README의 확장 빌드 명령을 먼저 실행해주세요."; return }
        let editors = [
            ("VS Code", "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"),
            ("VS Code Insiders", "/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code-insiders"),
            ("Cursor", "/Applications/Cursor.app/Contents/Resources/app/bin/cursor"),
            ("Windsurf", "/Applications/Windsurf.app/Contents/Resources/app/bin/windsurf"),
            ("VSCodium", "/Applications/VSCodium.app/Contents/Resources/app/bin/codium")
        ].filter { FileManager.default.isExecutableFile(atPath: $0.1) }
        guard !editors.isEmpty else { notice = "Applications 폴더에서 지원하는 편집기를 찾지 못했습니다."; return }
        busy = true
        Task {
            let results = await Task.detached { editors.map { name, cli -> String in
                do {
                    let result = try CommandRunner.run(cli, ["--install-extension", vsix.path, "--force"], timeout: 45)
                    return result.status == 0 ? "\(name): 설치됨" : "\(name): \(result.error)"
                } catch { return "\(name): \(error.localizedDescription)" }
            } }.value
            notice = results.joined(separator: "\n") + "\n이미 열려 있는 편집기는 새 확장을 사용하려면 창 새로고침이 필요할 수 있습니다. 실행 중인 터미널의 작업을 확인한 뒤 진행하세요."
            busy = false
        }
    }
}
