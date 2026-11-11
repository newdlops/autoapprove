import SwiftUI
import AutoApproveCore

struct CodexAutomationHoldView:View {
    @ObservedObject var engine:ApprovalEngine
    let sessionID:String
    @Environment(\.openWindow) private var openWindow
    var body:some View {
        if engine.snapshot.sessions.first(where:{$0.id==sessionID})?.automatic == true,
           let reason=engine.codexApprovalHoldReason(sessionID:sessionID) {
            CodexAutomationHoldNotice(reason:reason,openAccounts:{openWindow(id:"accounts")})
        }
    }
}

struct CodexAutomationHoldNotice:View {
    let reason:String
    let openAccounts:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Label("자동 승인 보류",systemImage:"pause.circle").font(.headline).foregroundStyle(.orange)
            Text(reason).font(.callout).fixedSize(horizontal:false,vertical:true)
            Button("계정·로그인에서 확인",action:openAccounts)
                .help("계정 전환의 진행 상태와 중지 조작부를 엽니다.")
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}
