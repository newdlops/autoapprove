import SwiftUI
import AutoApproveCore

@MainActor struct CodexSessionDetachView:View {
    let engine:ApprovalEngine
    let source:CodexSessionAccount
    let close:()->Void
    @State private var name="독립 로그인 · "+String(UUID().uuidString.prefix(6))
    @State private var home:CodexIndependentLogin?
    @State private var preparing=false
    @State private var error:String?
    var body:some View {
        if let home {
            CodexSessionMoveView(engine:engine,source:source,independentDestination:home,close:close)
        }else {
            VStack(alignment:.leading,spacing:20) {
                HStack {
                    Text("독립 실행으로 분리").font(.title2.weight(.semibold))
                    Spacer();Button("닫기",action:close).keyboardShortcut(.cancelAction).disabled(preparing)
                }
                Text(source.identity.email ?? source.identity.provider).textSelection(.enabled)
                Text("선택한 세션에 전용 로그인 홈을 만들고, 같은 대화를 공유 서버 없이 다시 실행합니다. 다른 그룹 세션은 유지됩니다.")
                    .foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                TextField("독립 로그인 이름",text:$name).textFieldStyle(.roundedBorder).disabled(preparing)
                if let error {Label(error,systemImage:"exclamationmark.circle").foregroundStyle(.red).fixedSize(horizontal:false,vertical:true)}
                Button("독립 홈 준비") {
                    preparing=true;error=nil
                    Task { @MainActor in
                        defer{preparing=false}
                        do {home=try await engine.createCodexIndependentLogin(name:name)}
                        catch {self.error=error.localizedDescription}
                    }
                }.disabled(preparing || name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                if preparing {ProgressView("독립 로그인 홈 준비 중…").controlSize(.small)}
                Spacer()
            }.padding(24).font(.callout).frame(width:600,height:660)
                .interactiveDismissDisabled(preparing)
        }
    }
}
