import SwiftUI
import AutoApproveCore

struct MouseActivitySettings: View {
    let status: MouseActivityStatus
    let error: String?
    let setEnabled: (Bool) -> Void
    let requestPermission: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("1분마다 마우스 신호 보내기", isOn: Binding(get: { status.enabled }, set: setEnabled))
                .toggleStyle(.switch)
                .help("작업 상태·일시정지·배터리·온도와 관계없이 보냅니다. 이미 잠긴 화면과 로그인 화면에는 보내지 않습니다.")
            Text("커서 위치를 바꾸거나 클릭·키 입력을 하지 않습니다. 켜 둔 동안 1분마다 신호를 보내며, 앱을 다시 열어도 설정을 유지합니다.")
            Text(status.detail).font(.callout.weight(.medium)).foregroundStyle(.primary).textSelection(.enabled)
                .accessibilityLabel("마우스 신호 상태: \(status.detail)")
            if status.phase == .permission {
                Button("손쉬운 사용 허용") { requestPermission() }
                    .help("macOS에서 AutoApprove의 마우스 신호 권한을 허용합니다.")
            }
            if let sent = status.lastSentAt {
                HStack(spacing: 4) { Text("마지막 신호"); Text(sent, style: .time).monospacedDigit() }.font(.caption)
            }
            if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
            Text("화면 잠금을 해제하지 않습니다. 이미 잠겼다면 Mac에서 직접 잠금을 해제해주세요. 덮개를 닫은 상태의 잠자기는 위의 설정에서 별도로 관리합니다.").font(.caption)
        }
    }
}
