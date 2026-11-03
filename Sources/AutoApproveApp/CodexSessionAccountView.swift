import SwiftUI
import AutoApproveCore

private struct CodexAccountLoginPresentation:Identifiable {
    let account:CodexSessionAccount
    var id:String {account.sessionID}
}

@MainActor struct CodexSessionAccountView: View {
    let engine:ApprovalEngine
    let sessionID:String
    @State private var account:CodexSessionAccount?
    @State private var loading=false
    @State private var error:String?
    @State private var loginPresentation:CodexAccountLoginPresentation?
    @State private var busy=false
    @State private var held=false
    var body:some View {
        CodexSessionAccountContent(account:account,loading:loading,error:error,disabled:busy || held,
            refresh:{Task{await load()}},login:{if let account {loginPresentation = .init(account:account)}},reconnect:{
                guard let account else{return}
                Task {
                    do {_ = try await verifiedTargets(account);try await engine.reconnectCodexLogin(home:account.target.home)}
                    catch {self.error=error.localizedDescription}
                }
            })
            .padding(.horizontal,24).padding(.vertical,12)
            .task(id:sessionID) {
                account=nil;error=nil
                while !Task.isCancelled {
                    await load()
                    do {try await Task.sleep(for:.seconds(30))} catch {return}
                }
            }
            .onReceive(engine.$codexAccountTransitionBusy){busy=$0}
            .onReceive(engine.$codexAccountTransitionStates){held=$0.values.contains(where:\.held)}
            .sheet(item:$loginPresentation) {presentation in
                    let account=presentation.account
                    VStack(alignment:.leading,spacing:16) {
                        HStack {Text(account.individual ? "이 세션의 Codex 계정":"공유 Codex 계정").font(.title2.weight(.semibold));Spacer();Button("완료"){loginPresentation=nil}.keyboardShortcut(.cancelAction)}
                        ScrollView {
                            VStack(alignment:.leading,spacing:16) {
                                Text(account.individual ? "이 서버에 연결된 열린 세션은 1개입니다.":"같은 서버의 열린 Codex \(account.sharedSessions)개에 함께 적용됩니다.")
                                    .fixedSize(horizontal:false,vertical:true)
                                CodexLoginSettings(accounts:engine.agentAccounts,targets:{try await verifiedTargets(account)},
                                    transitionEnabled:engine.codexAccountTransitionEnabled,transitionBusy:busy || held,completed:{},preferredHome:account.target.home,
                                    reconnect:{try await engine.reconnectCodexLogin(home:$0)},inspectAccount:{try await engine.inspectCodexAccount(home:$0)})
                                Divider()
                                CodexAccountTransitionSettings(enabled:engine.codexAccountTransitionEnabled,busy:busy,
                                    states:engine.codexAccountTransitionStates,notice:engine.codexAccountTransitionNotice,error:error,
                                    setEnabled:{value in do{try engine.setCodexAccountTransitionEnabled(value)}catch{self.error=error.localizedDescription}},
                                    check:{Task{await engine.checkCodexAccountTransitions()}},cancel:{home in do{try engine.cancelCodexAccountTransition(home:home)}catch{self.error=error.localizedDescription}})
                            }.frame(maxWidth:.infinity,alignment:.leading)
                        }
                    }.padding(24).frame(width:600,height:660)
            }
    }
    private func load() async {
        guard !loading else{return}
        loading=true;defer{loading=false}
        do {
            let value=try await engine.codexSessionAccount(sessionID:sessionID)
            try Task.checkCancellation();account=value;error=nil
        } catch is CancellationError {} catch {account=nil;self.error=error.localizedDescription}
    }
    private func verifiedTargets(_ expected:CodexSessionAccount) async throws -> [CodexAccountTransitionTarget] {
        let fresh=try await engine.codexSessionAccount(sessionID:sessionID)
        guard fresh.target.home==expected.target.home,fresh.sharedSessions==expected.sharedSessions,fresh.identity==expected.identity else {
            throw AppError.message("계정이나 공유 세션 수가 바뀌었습니다. 창을 닫고 계정을 새로 확인해주세요.")
        }
        return [fresh.target]
    }
}

struct CodexSessionAccountContent:View {
    let account:CodexSessionAccount?
    let loading:Bool
    let error:String?
    let disabled:Bool
    let refresh:()->Void
    let login:()->Void
    let reconnect:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Label("연결 서버 계정",systemImage:"person.crop.circle").font(.callout.weight(.semibold))
                Spacer()
                Button(action:refresh){Image(systemName:"arrow.clockwise")}.buttonStyle(.borderless)
                    .accessibilityLabel("이 세션의 연결 계정 새로 확인").disabled(loading)
                if loading {ProgressView().controlSize(.small).accessibilityLabel("연결 계정 확인 중")}
            }
            if let account {
                Text(account.identity.email ?? account.identity.provider).textSelection(.enabled)
                    .fixedSize(horizontal:false,vertical:true)
                Text([account.identity.provider,account.identity.plan,account.individual ? "열린 세션 1개":"\(account.sharedSessions)개 세션 공유"].compactMap{$0}.joined(separator:" · "))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                ViewThatFits(in:.horizontal) {
                    HStack {buttons(account)}
                    VStack(alignment:.leading,spacing:8){buttons(account)}
                }
                if !account.individual {
                    Text("개별 계정으로 쓰려면 Codex 홈·서버를 분리해야 합니다. 이 서버의 로그인 변경은 공유 세션 전체에 적용됩니다.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
            } else if error==nil {Text("이 세션이 연결된 서버에서 계정을 확인합니다…").font(.caption).foregroundStyle(.secondary)}
            if let error {Label(error,systemImage:"exclamationmark.circle").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    @ViewBuilder private func buttons(_ account:CodexSessionAccount) -> some View {
        Button(account.individual ? "이 세션 계정 로그인":"공유 계정 로그인 (\(account.sharedSessions)개 세션)",action:login)
            .disabled(loading).help("연결된 계정의 로그인과 전환 진행 상태를 확인합니다.")
        Button("현재 로그인으로 재연결",action:reconnect).disabled(disabled || loading || !account.identity.authenticated)
            .help("같은 서버의 연결된 Codex를 순차 중단하고 저장된 로그인으로 다시 연결합니다.")
    }
}
