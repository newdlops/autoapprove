import SwiftUI
import AutoApproveCore

struct CodexSessionAttachmentStatus:View {
    let detail:String
    var body:some View {
        Label(detail,systemImage:"arrow.triangle.2.circlepath").font(.caption)
            .fixedSize(horizontal:false,vertical:true)
    }
}

struct CodexAccountsLayout<Content:View>:View {
    let close:()->Void
    @ViewBuilder var content:Content
    init(close:@escaping()->Void,@ViewBuilder content:()->Content) {self.close=close;self.content=content()}
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack {
                Text("계정·로그인").font(.title2.weight(.semibold)).foregroundStyle(.primary)
                Spacer()
                Button("완료",action:close).keyboardShortcut(.cancelAction)
                    .help("이 창을 닫습니다. 로그인·전환은 계속 진행됩니다. ⌘W 또는 Esc")
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:20) {content}.padding(24).frame(maxWidth:.infinity,alignment:.leading)
            }
        }.font(.callout).foregroundStyle(.primary).frame(width:600,height:660)
    }
}

@MainActor struct CodexAccountsWindow:View {
    let engine:ApprovalEngine
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewUpdates=WindowViewUpdates()
    @State private var error:String?
    var body:some View {
        CodexAccountsLayout(close:{dismiss()}) {
            Text("이 Mac에서 실행 중인 Codex의 로그인과 세션 연결을 관리합니다.")
                .fixedSize(horizontal:false,vertical:true)
            CodexLoginSettings(accounts:engine.agentAccounts,targets:{try await engine.codexLoginTargets()},
                transitionEnabled:engine.codexAccountTransitionEnabled,transitionBusy:engine.codexAccountTransitionBusy || engine.codexAccountTransitionHeld,
                completed:{},reconnect:{try await engine.reconnectCodexLogin(home:$0)},
                setupHomes:{try await engine.codexServerSetupHomes()},serverStatus:{try await engine.codexManagedServerStatus(home:$0)},
                prepareServer:{try await engine.prepareCodexManagedServer(home:$0)})
            if let notice=engine.codexSessionAttachmentNotice {
                CodexSessionAttachmentStatus(detail:notice)
            }
            Divider()
            CodexAccountTransitionSettings(enabled:engine.codexAccountTransitionEnabled,busy:engine.codexAccountTransitionBusy,
                states:engine.codexAccountTransitionStates,notice:engine.codexAccountTransitionNotice,error:error,
                setEnabled:{enabled in
                    do {
                        try engine.setCodexAccountTransitionEnabled(enabled);error=nil
                        if enabled {Task {await engine.checkCodexAccountTransitions()}}
                    } catch {self.error=error.localizedDescription}
                },check:{error=nil;Task {await engine.checkCodexAccountTransitions()}},cancel:{home in
                    do {try engine.cancelCodexAccountTransition(home:home);error=nil}
                    catch {self.error=error.localizedDescription}
                })
        }.windowUpdates(viewUpdates,sources:[engine.objectWillChange])
    }
}
