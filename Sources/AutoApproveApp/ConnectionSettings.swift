import SwiftUI
import AppKit
import AutoApproveCore

struct ConnectionSettings: View {
    @ObservedObject var engine: ApprovalEngine
    @ObservedObject var notifications: QuestionNotifications
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var notice: String?
    private var helper: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/autoapprove").path }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("연결 설정").font(.title2.weight(.semibold)); Spacer(); Button("완료") { dismiss() }.keyboardShortcut(.defaultAction).help("연결 설정을 닫고 세션 목록으로 돌아갑니다.") }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    section("응답 알림", icon: "bell", status: notifications.status) {
                        Text("자동으로 답할 수 없는 질문을 macOS 알림으로 알려줍니다. 알림을 누르면 해당 터미널을 열고 강조합니다. 같은 질문은 한 번만 알리며, 답한 질문의 알림은 정리합니다.")
                        HStack {
                            if notifications.authorization == .notDetermined {
                                Button("알림 허용") { Task { await notifications.requestAuthorization() } }
                                    .disabled(notifications.busy)
                                    .help("질문 알림과 소리를 허용하는 macOS 권한 창을 엽니다.")
                            }
                            Button("시스템 알림 설정") { notifications.openSettings() }
                                .help("macOS 알림 설정에서 AutoApprove의 배너·소리·미리보기를 변경합니다.")
                        }
                        Text("배너와 소리는 macOS 알림·집중 모드 설정을 따릅니다.").font(.caption)
                        if let error = notifications.error {
                            Text(error).foregroundStyle(.red)
                            Button("알림 다시 확인") { Task { await notifications.retryDelivery() } }
                                .disabled(notifications.busy).help("알림 권한을 확인하고 전송에 실패한 질문 알림을 다시 보냅니다.")
                        }
                    }
                    Divider()
                    section("Terminal", icon: "terminal", status: engine.snapshot.health.terminal) {
                        Text("실행 중인 탭을 연결해 요청을 읽고 해당 탭에만 승인 입력을 전달합니다. 한 번 연결하면 앱을 다시 실행해도 연결을 복원합니다. 처음 연결할 때 macOS의 자동화 권한을 허용해주세요.")
                        HStack {
                            Button(engine.snapshot.health.terminalConnected ? "다시 연결" : "Terminal 연결") { busy = true; Task { await engine.connectTerminal(); busy = false } }.disabled(busy || engine.snapshot.health.terminalConnecting)
                                .help(busy || engine.snapshot.health.terminalConnecting ? "연결 상태를 확인하고 있습니다." : "macOS Terminal의 Claude Code·Codex 탭을 연결합니다. 허용한 연결은 앱 재실행 후 복원됩니다.")
                            Button("연결 해제") { engine.disconnectTerminal() }.disabled(!engine.snapshot.health.terminalRequested)
                                .help(engine.snapshot.health.terminalRequested ? "Terminal 화면 감지와 승인 입력을 중단합니다. 다시 연결하기 전까지 해제 상태를 유지합니다." : "현재 Terminal 연결이 꺼져 있습니다.")
                        }
                    }
                    Divider()
                    section("Claude Code", icon: "bolt.horizontal", status: engine.snapshot.health.claude) {
                        Text("Terminal과 VS Code 모두에서 권한 요청을 직접 받습니다. 기존 설정을 백업하고 AutoApprove 훅만 추가합니다.")
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
                    section("VS Code", icon: "chevron.left.forwardslash.chevron.right", status: engine.snapshot.health.vscode) {
                        Text("AutoApprove Bridge 확장을 설치하면 터미널을 찾아 이동할 수 있습니다. 출력 감지는 확장이 연결된 뒤 시작한 명령부터 가능합니다.")
                        Button("VS Code 확장 설치") { installExtension() }.disabled(busy)
                            .help(busy ? "현재 연결 작업이 끝날 때까지 기다려주세요." : "앱에 포함된 AutoApprove Bridge를 VS Code에 설치합니다. 출력 감지는 연결 후 시작한 명령부터 가능합니다.")
                    }
                    Divider()
                    section("Codex", icon: "command", status: engine.snapshot.health.codex) {
                        Text("현재 버전은 연결된 터미널의 승인 화면을 감지합니다. 기존 VS Code 세션의 출력에 연결할 수 없으면 확장 설치 후 CLI를 다시 실행하고 대화를 이어가세요.")
                    }
                    if let notice {
                        Label(notice, systemImage: "info.circle").font(.callout).foregroundStyle(.primary).textSelection(.enabled)
                    }
                }.padding(24)
            }
        }.frame(width: 600, height: 660)
    }
    @ViewBuilder private func section<Content: View>(_ title: String, icon: String, status: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline)
            Text(status).font(.callout.weight(.medium)).textSelection(.enabled)
            content().font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func installExtension() {
        guard let vsix = Bundle.main.url(forResource: "autoapprove-bridge", withExtension: "vsix") else { notice = "확장 파일이 없습니다. README의 확장 빌드 명령을 먼저 실행해주세요."; return }
        let cli = "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
        guard FileManager.default.isExecutableFile(atPath: cli) else { notice = "Applications 폴더의 Visual Studio Code를 찾지 못했습니다."; return }
        busy = true
        Task {
            do {
                let result = try await Task.detached { try CommandRunner.run(cli, ["--install-extension", vsix.path, "--force"], timeout: 45) }.value
                notice = result.status == 0 ? "확장을 설치했습니다. 연결되지 않으면 VS Code에서 Developer: Reload Window를 실행해주세요." : "확장 설치에 실패했습니다. \(result.error)"
            } catch { notice = error.localizedDescription }
            busy = false
        }
    }
}
