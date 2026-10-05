import SwiftUI
import AutoApproveCore

struct TerminalSharingSettings: View {
    var screenAllowed: Bool
    var inputStatus: TerminalInputStatus
    var inputBusy: Bool
    var inputError: String?
    var screenAction: () -> Void
    var inputAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("같은 원본 터미널의 출력과 입력을 중계하며 실행 중인 CLI를 유지합니다. 새 Terminal 입력 연결은 macOS에 등록한 뒤 로그인 항목 설정에서 허용합니다. ‘Mac 창 보기’를 켤 때만 화면 기록 권한을 사용합니다.").font(.caption)
            HStack {
                permissionLabel(screenAllowed, allowed: "Mac 창 보기 허용됨", needed: "Mac 창 보기 · 선택 사항", optional: true)
                Spacer()
                Button(screenAllowed ? "화면 공유 설정" : "화면 공유 허용", action: screenAction)
                    .help("선택한 원본 터미널 창을 공유하는 macOS 권한을 확인합니다.")
            }
            HStack {
                permissionLabel(inputStatus.available, allowed: "원본에 직접 입력 연결됨", needed: inputStatus == .requiresApproval ? "Terminal 직접 입력 · 승인 대기" : "Terminal 직접 입력 연결 필요")
                Spacer()
                if inputBusy { ProgressView().controlSize(.small).accessibilityLabel("직접 입력 연결 등록 중") }
                Button(inputStatus.available ? "연결 확인" : inputStatus == .requiresApproval ? "허용 설정 열기" : "직접 입력 연결", action: inputAction)
                    .disabled(inputBusy)
                    .help(inputStatus.available ? "원본 터미널 입력 서비스의 연결 상태를 다시 확인합니다." : inputStatus == .requiresApproval ? "macOS 로그인 항목 설정에서 AutoApprove의 백그라운드 실행을 허용합니다." : "macOS에 원본 CLI 입력 서비스를 등록합니다. 이미 연결된 서비스는 계속 사용합니다. 휴대폰은 브라우저만 사용합니다.")
            }
            Text(inputBusy ? "macOS 서비스 등록과 기존 연결 상태를 확인하고 있습니다." : inputStatus.message).font(.caption)
            if let inputError { Label(inputError, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
    }
    private func permissionLabel(_ granted: Bool, allowed: String, needed: String, optional: Bool = false) -> some View {
        Label {
            Text(granted ? allowed : needed).foregroundStyle(.primary)
        } icon: {
            Image(systemName: granted ? "checkmark.circle" : optional ? "info.circle" : "exclamationmark.circle")
                .foregroundStyle(granted ? Color.green : optional ? Color.secondary : Color.orange)
        }
    }
}
