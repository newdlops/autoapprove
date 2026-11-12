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
    @State private var standalone:CodexStandaloneSession?
    @State private var standaloneMove:CodexStandaloneSession?
    @State private var detachPresentation:CodexAccountLoginPresentation?
    @State private var loading=false
    @State private var error:String?
    @State private var loginPresentation:CodexAccountLoginPresentation?
    @State private var movePresentation:CodexAccountLoginPresentation?
    @State private var busy=false
    @State private var held=false
    @State private var serverLink:CodexSessionServerLink?
    @State private var linkingServer=false
    @State private var serverLinkError:String?
    var body:some View {
        CodexSessionAccountContent(account:account,loading:loading,error:error,disabled:busy || held,
            refresh:{Task{await load()}},login:{if let account {loginPresentation = .init(account:account)}},reconnect:{
                guard let account else{return}
                Task {
                    do {_ = try await verifiedTargets(account);try await engine.reconnectCodexLogin(home:account.target.home)}
                    catch {self.error=error.localizedDescription}
                }
            },changeGroup:{
                if let account {movePresentation = .init(account:account)}
                else if let standalone {standaloneMove=standalone}
            },standalone:standalone,makeIndependent:{if let account {detachPresentation = .init(account:account)}},
            serverLink:serverLink,serverLinkError:serverLinkError,linkingServer:linkingServer,
            verifyServerLink:{verifyServerLink()})
            .padding(.horizontal,24).padding(.vertical,12)
            .task(id:sessionID) {
                account=nil;standalone=nil;error=nil
                while !Task.isCancelled {
                    await load()
                    do {try await Task.sleep(for:.seconds(30))} catch {return}
                }
            }
            .onReceive(engine.$codexAccountTransitionBusy){busy=$0}
            .onReceive(engine.$codexAccountTransitionStates){held=$0.values.contains(where:\.held)}
            .sheet(item:$movePresentation) {presentation in
                CodexSessionMoveView(engine:engine,source:presentation.account,close:{movePresentation=nil})
            }
            .sheet(item:$standaloneMove) {source in
                CodexSessionMoveView(engine:engine,standalone:source,close:{standaloneMove=nil})
            }
            .sheet(item:$detachPresentation) {presentation in
                CodexSessionDetachView(engine:engine,source:presentation.account,close:{detachPresentation=nil})
            }
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
        loading=true;serverLink=nil;serverLinkError=nil;defer{loading=false}
        do {
            let value=try await engine.codexSessionAccount(sessionID:sessionID)
            try Task.checkCancellation();account=value;standalone=nil;error=nil
            if serverLink?.sessionID != value.sessionID || serverLink?.serverPID != value.serverPID {serverLink=nil}
        } catch is CancellationError {} catch {
            let accountError=error
            account=nil
            do {
                let value=try await engine.codexStandaloneSession(sessionID:sessionID)
                try Task.checkCancellation();standalone=value;self.error=nil
            }catch is CancellationError {}catch {standalone=nil;self.error=accountError.localizedDescription}
        }
    }
    private func verifyServerLink() {
        guard !linkingServer else{return}
        linkingServer=true;serverLinkError=nil
        Task { @MainActor in
            defer{linkingServer=false}
            do {
                let value=try await engine.codexSessionServerLink(sessionID:sessionID)
                try Task.checkCancellation();serverLink=value
            } catch is CancellationError {} catch {serverLink=nil;serverLinkError=error.localizedDescription}
        }
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
    var changeGroup:(()->Void)?=nil
    var standalone:CodexStandaloneSession?=nil
    var makeIndependent:(()->Void)?=nil
    var serverLink:CodexSessionServerLink?=nil
    var serverLinkError:String?=nil
    var linkingServer=false
    var verifyServerLink:(()->Void)?=nil
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
                Label(account.loginGroupName ?? "기존 Codex 홈",systemImage:"folder")
                    .font(.caption).foregroundStyle(.secondary).help(account.target.home)
                    .accessibilityLabel("로그인 그룹: \(account.loginGroupName ?? "기존 Codex 홈")")
                    .fixedSize(horizontal:false,vertical:true)
                Text(account.identity.email ?? account.identity.provider).textSelection(.enabled)
                    .fixedSize(horizontal:false,vertical:true)
                Text([account.identity.provider,account.identity.plan,account.individual ? "열린 세션 1개":"\(account.sharedSessions)개 세션 공유"].compactMap{$0}.joined(separator:" · "))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                if let server=account.serverPID,server>0 {
                    Text("연결 서버 · Codex app-server (PID \(String(server)))")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal:false,vertical:true)
                }
                if let serverLink,serverLink.sessionID==account.sessionID {
                    Label("서버 전체 연결 확인됨 · Codex 창 \(serverLink.clientCount)개 / 접속 \(serverLink.serverConnectionCount)개",systemImage:"checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    Text("이 세션의 접속 ID #\(serverLink.connectionID)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("서버 세대 \(serverLink.serverGeneration) · 백엔드 \(serverLink.logicalBackendID)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal:false,vertical:true)
                }
                if let serverLinkError {
                    Label("세션 서버 연결 상세를 확인하지 못했습니다: \(serverLinkError)",systemImage:"exclamationmark.circle")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
                ViewThatFits(in:.horizontal) {
                    HStack {buttons(account)}
                    VStack(alignment:.leading,spacing:8){buttons(account)}
                }
                if !account.individual {
                    Text("개별 계정으로 쓰려면 Codex 홈·서버를 분리해야 합니다. 이 서버의 로그인 변경은 공유 세션 전체에 적용됩니다.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
            }else if let standalone {
                Label("독립 실행",systemImage:"person.crop.circle").font(.callout.weight(.medium))
                Text("공유 app-server 없이 실행 중입니다. 로그인 그룹에 연결하면 해당 그룹의 계정을 사용합니다.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Text(standalone.home).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                if let changeGroup {
                    Button("로그인 그룹에 연결…",action:changeGroup).disabled(disabled || loading)
                        .help("선택한 독립 세션의 대화를 로그인 그룹으로 옮깁니다. 다른 세션은 그대로 유지합니다.")
                }
            } else if error==nil {Text("이 세션이 연결된 서버에서 계정을 확인합니다…").font(.caption).foregroundStyle(.secondary)}
            if let error {Label(error,systemImage:"exclamationmark.circle").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    @ViewBuilder private func buttons(_ account:CodexSessionAccount) -> some View {
        Button(account.individual ? "이 세션 계정 로그인":"공유 계정 로그인 (\(account.sharedSessions)개 세션)",action:login)
            .disabled(loading).help("연결된 계정의 로그인과 전환 진행 상태를 확인합니다.")
        if let verifyServerLink {
            Button(linkingServer ? "연결 확인 중…":"전체 서버 연결 확인",systemImage:"point.3.connected.trianglepath.dotted",action:verifyServerLink)
                .disabled(disabled || loading || linkingServer)
                .help("이 세션 창과 app-server 사이의 실제 로컬 연결 및 같은 서버의 전체 창 목록을 대조합니다.")
        }
        Button("현재 로그인으로 재연결",action:reconnect).disabled(disabled || loading)
            .help("같은 서버의 연결된 Codex를 순차 중단하고 저장된 로그인으로 다시 연결합니다.")
        if let changeGroup {
            Button("로그인 그룹 변경…",action:changeGroup).disabled(disabled || loading)
                .help("옮길 로그인 그룹의 계정과 연결 서버를 확인합니다.")
        }
        if let makeIndependent {
            Button("독립 실행으로 분리…",action:makeIndependent).disabled(disabled || loading)
                .help("이 세션만 전용 로그인 홈으로 옮기고 공유 서버 없이 실행합니다.")
        }
    }
}
