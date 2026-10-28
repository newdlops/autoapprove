import SwiftUI
import AutoApproveCore

struct CodexProgressStatusView:View {
    let progress:CodexProgressRecovery
    let paused:Bool
    let automatic:Bool
    let working:Bool
    var check:(() throws -> Void)?
    var cancel:(() -> Void)?
    @State private var error:String?
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Label("Codex 진척 확인",systemImage:"clock.arrow.circlepath").font(.headline)
            Text(progress.detail).font(.callout).fixedSize(horizontal:false,vertical:true)
            HStack(spacing:4) {Text("진척 감시 기준");Text(progress.lastProgressAt,style:.relative).monospacedDigit()}.font(.caption).foregroundStyle(.secondary)
            Text("모델 중지를 확정하는 표시가 아닙니다. 30분 동안 진척 신호가 없으면 진행 상황을 묻고 이어가도록 요청합니다.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            HStack {
                if [.interrupting,.waiting,.asking].contains(progress.phase) {
                    ProgressView().controlSize(.small)
                    Button("진행 확인 취소") {cancel?()}.disabled(cancel==nil)
                } else if let check {
                    Button("진행 확인·이어가기") {do {try check();error=nil} catch {self.error=error.localizedDescription}}
                        .disabled(paused || !automatic || !working || progress.phase == .review || progress.phase == .requested)
                }
            }
            if let error {Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true)}
        }
    }
}
