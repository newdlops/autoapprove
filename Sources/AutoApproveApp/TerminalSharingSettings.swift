import SwiftUI
import AutoApproveCore

struct TerminalSharingSettings: View {
    var screenAllowed: Bool
    var inputStatus: TerminalInputStatus
    var inputBusy: Bool
    var inputError: String?
    var controlAllowed:Bool
    var screenAction: () -> Void
    var inputAction: () -> Void
    var controlAction:()->Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("같은 원본 터미널의 출력과 입력을 중계하며 실행 중인 CLI를 유지합니다. Terminal 직접 입력은 AutoApprove의 손쉬운 사용 권한으로 전달합니다. root 입력 서비스는 사용하지 않습니다. 유료 개발자 계정이나 휴대폰 설치는 필요 없습니다. ‘Mac 창 보기’를 켤 때만 화면 기록 권한을 사용합니다.").font(.caption)
            HStack {
                permissionLabel(screenAllowed, allowed: "Mac 창 보기 허용됨", needed: "Mac 창 보기 · 선택 사항", optional: true)
                Spacer()
                Button(screenAllowed ? "화면 공유 설정" : "화면 공유 허용", action: screenAction)
                    .help("선택한 원본 터미널 창을 공유하는 macOS 권한을 확인합니다.")
            }
            HStack {
                permissionLabel(controlAllowed,allowed:"공유 화면 키보드·마우스 허용됨",needed:"화면 조작 · 손쉬운 사용 필요",optional:true)
                Spacer()
                Button(controlAllowed ? "화면 조작 설정":"화면 조작 허용",action:controlAction)
                    .help("웹의 공유 화면에서 키보드·마우스를 사용할 수 있도록 macOS 손쉬운 사용 권한을 확인합니다.")
            }
            Text("화면을 공유한 뒤 웹에서 ‘조작하기’를 켜면 클릭·드래그·스크롤과 키보드를 사용할 수 있습니다. 손쉬운 사용 권한은 이 Mac에서 한 번 허용합니다.").font(.caption)
            HStack {
                permissionLabel(inputStatus.available, allowed: "원본에 직접 입력 연결됨", needed: "Terminal 직접 입력 · 손쉬운 사용 필요")
                Spacer()
                if inputBusy { ProgressView().controlSize(.small).accessibilityLabel("입력 권한 확인 중") }
                Button(inputStatus.available ? "연결 확인" : "손쉬운 사용 허용", action: inputAction)
                    .disabled(inputBusy)
                    .help(inputStatus.available ? "AutoApprove의 손쉬운 사용 입력 권한을 다시 확인합니다." : "macOS 손쉬운 사용에서 AutoApprove의 입력 권한을 확인합니다. 별도 서비스를 설치하지 않습니다.")
            }
            Text(inputBusy ? "손쉬운 사용 권한을 확인하고 있습니다." : inputStatus.message).font(.caption)
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
