import SwiftUI
import AppKit
import AutoApproveCore

struct TmuxSharingSettings: View {
    var installed: Bool
    var health: ScreenHostHealth
    var command: String
    var connect: () -> Void
    var disconnect: () -> Void
    @State private var copied = false
    @State private var copyReset: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mac과 휴대폰에서 같은 tmux 창의 화면·커서·입력을 사용합니다. tmux는 공유할 각 Mac에만 설치합니다. 휴대폰은 브라우저만 사용합니다.")
            Label(installed ? "이 Mac에 tmux 설치됨" : "이 Mac에 tmux 설치 필요", systemImage: installed ? "checkmark.circle" : "info.circle")
                .foregroundStyle(installed ? Color.primary : Color.orange)
            if installed {
                Text("새 작업은 Mac 터미널에서 아래 명령을 실행한 뒤 Codex 또는 Claude를 시작하세요. 이미 tmux 안에서 실행 중이면 연결 확인만 하세요.").font(.caption)
                Text(command).font(.system(.callout, design: .monospaced)).foregroundStyle(.primary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).accessibilityLabel("tmux 시작 명령: \(command)")
                HStack {
                    Button(copied ? "복사됨" : "시작 명령 복사") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string); copied = true
                        copyReset?.cancel()
                        copyReset = Task {
                            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                            copied = false
                        }
                    }.help("Mac 터미널에 붙여 넣을 tmux 시작 명령을 복사합니다.")
                    Button(health.requested ? "연결 확인" : "tmux 연결", action: connect)
                        .disabled(health.connecting).help(health.connecting ? "연결 상태를 확인하고 있습니다." : "이 Mac의 tmux 안에서 실행 중인 CLI를 확인합니다.")
                    Button("연결 해제", action: disconnect).disabled(!health.requested)
                        .help(health.requested ? "AutoApprove 중계만 해제합니다. tmux 창과 실행 중인 CLI는 계속 유지됩니다." : "현재 tmux 중계가 해제되어 있습니다.")
                    if health.connecting { ProgressView().controlSize(.small).accessibilityLabel("tmux 연결 확인 중") }
                }
            } else {
                Text("Homebrew를 사용한다면 Mac 터미널에서 brew install tmux를 실행한 뒤 연결 설정을 다시 여세요.").font(.caption).textSelection(.enabled)
            }
            Text("tmux 밖에서 이미 실행 중인 세션은 그대로 유지됩니다. 설치만으로 그 세션이 tmux로 전환되지는 않습니다.")
                .font(.caption)
        }.onChange(of: command) { _, _ in copyReset?.cancel(); copied = false }
            .onDisappear { copyReset?.cancel() }
    }
}
