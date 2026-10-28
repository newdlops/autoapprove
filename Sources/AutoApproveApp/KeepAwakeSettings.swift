import SwiftUI
import AutoApproveCore

struct KeepAwakeSettings: View {
    let status: KeepAwakeStatus?
    let busy: Bool
    let error: String?
    let setEnabled: (Bool) -> Void
    let removeRule: () -> Void
    let openLockSettings: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text("한 번 켜면 작업·질문·대기 상태와 관계없이 앱이 켜진 동안 Mac 잠자기와 유휴 화면 꺼짐을 방지합니다. 자동 승인을 끄거나 전체 일시정지를 해도 유지합니다.")
            Toggle("앱 실행 중 잠자기·자동 화면 꺼짐 방지",isOn:Binding(get:{status?.enabled ?? false},set:setEnabled))
                .toggleStyle(.switch).disabled(busy)
                .help(status?.enabled == true ? "끄면 앱의 잠자기·화면 유지 활동을 해제합니다." : "앱이 켜진 동안 유지합니다. 처음에는 관리자 암호로 잠자기 권한을 설치합니다.")
            if let closed=status?.lidClosed {
                Text("덮개: \(closed ? "닫힘":"열림") · 화면: \(status?.screenLocked.map{$0 ? "잠김":"사용 중"} ?? "확인 중")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if status?.screenLocked == true {
                Label("화면이 이미 잠겨 있습니다. 이 Mac에서 한 번 잠금을 해제해주세요.",systemImage:"lock.fill")
            }
            if let error {Label(error,systemImage:"exclamationmark.circle").foregroundStyle(.red)}
            Text("앱이나 이 설정을 끄면 유지 활동을 해제합니다. 배터리가 20% 이하이거나 Mac이 뜨거우면 보호를 위해 해제하고, 상태가 회복되면 다시 유지합니다.").font(.caption)
            Text("처음에는 pmset 잠자기 금지를 켜고 끄는 권한 규칙을 설치합니다. 유지 중에는 macOS의 평소 잠자기가 제한되며, 앱이 멈추면 별도 감시 프로세스가 복원합니다. 덮개를 닫은 채 가방에 넣지 마세요.").font(.caption)
            Text("덮개 닫힘에 따른 macOS 잠금 설정·수동 잠금·조직 보안 정책은 해제하지 않습니다. 이 설정만으로 모든 잠금을 막는 것은 보장할 수 없습니다.").font(.caption).foregroundStyle(.secondary)
            Button("macOS 잠금 화면 설정") {openLockSettings()}.disabled(busy)
                .help("macOS 잠금 화면 설정을 엽니다. 설정값을 자동으로 바꾸지는 않습니다.")
            if status?.ruleFile == true && status?.enabled != true {
                Button("권한 규칙 제거") {removeRule()}.disabled(busy)
                    .help("AutoApprove의 잠자기 권한 규칙을 제거합니다. 관리자 암호가 필요합니다.")
            }
        }
    }
}
