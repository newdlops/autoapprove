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
    @State private var groups:[CodexLoginGroup]=[]
    @State private var groupError:String?
    @State private var loadingGroups=true
    @State private var loginBusy=false
    @State private var newGroup=false
    @State private var groupSettings=false
    @State private var requestedHome:String?
    @State private var focusHome:String?
    @State private var groupsRequest=UUID()
    private var homeNames:[String:String] {
        var names=Dictionary(groups.map{((try? CodexAccountTransitionTarget.canonicalHome($0.home)) ?? $0.home,$0.name)},uniquingKeysWith:{first,_ in first})
        if let home=try? CodexAccountTransitionTarget.canonicalHome(NSHomeDirectory()+"/.codex"){names[home]="기본 로그인"}
        return names
    }
    var body:some View {
        CodexAccountsLayout(close:{dismiss()}) {
            Text("이 Mac에서 실행 중인 Codex의 로그인과 세션 연결을 관리합니다.")
                .fixedSize(horizontal:false,vertical:true)
            HStack(spacing:8) {
                Text("로그인 그룹").font(.callout.weight(.semibold))
                if loadingGroups{ProgressView().controlSize(.small).accessibilityLabel("로그인 그룹 확인 중")}
                Spacer()
                Button("새 로그인 그룹",systemImage:"plus") {
                    guard !engine.agentAccounts.busy else{groupError="진행 중인 로그인을 마친 뒤 새 그룹을 만들어주세요.";return}
                    newGroup=true
                }.disabled(loadingGroups || loginBusy || engine.agentAccounts.busy)
                    .help("별도 로그인 홈을 준비합니다. 만든 뒤 해당 그룹에서 브라우저 로그인을 시작할 수 있습니다.")
            }
            DisclosureGroup("그룹 설정",isExpanded:$groupSettings) {
                CodexLoginGroupSettings(groups:groups,rename:{id,name in
                    let group=try await engine.renameCodexLoginGroup(id:id,name:name)
                    await reloadGroups();return group
                }).disabled(loadingGroups || loginBusy || engine.agentAccounts.busy)
            }
            if let groupError {
                VStack(alignment:.leading,spacing:6) {
                    Label(groupError,systemImage:"exclamationmark.circle").foregroundStyle(.red).fixedSize(horizontal:false,vertical:true)
                    Button("그룹 다시 확인"){Task{await reloadGroups()}}.disabled(loadingGroups)
                }
            }
            CodexLoginSettings(accounts:engine.agentAccounts,targets:{try await engine.codexLoginTargets()},
                transitionEnabled:engine.codexAccountTransitionEnabled,transitionBusy:engine.codexAccountTransitionBusy || engine.codexAccountTransitionHeld,
                completed:{},reconnect:{try await engine.reconnectCodexLogin(home:$0)},
                setupHomes:{try await engine.codexServerSetupHomes()},serverStatus:{try await engine.codexManagedServerStatus(home:$0)},
                prepareServer:{try await engine.prepareCodexManagedServer(home:$0)},inspectAccount:{try await engine.inspectCodexAccount(home:$0)},
                homeNames:homeNames,requestedHome:requestedHome,groupFocusRequest:focusHome,onLoginActivityChanged:{loginBusy=$0})
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
        .task{await reloadGroups()}
        .onDisappear{groupsRequest=UUID();loadingGroups=false}
        .sheet(isPresented:$newGroup,onDismiss:{focusHome=requestedHome}) {
            CodexNewLoginGroupSheet(create:{name in
                guard !engine.agentAccounts.busy else{throw AppError.message("진행 중인 로그인을 마친 뒤 새 그룹을 만들어주세요.")}
                let group=try await engine.createCodexLoginGroup(name:name)
                await reloadGroups();requestedHome=group.home;newGroup=false
            },cancel:{newGroup=false})
        }
    }
    private func reloadGroups() async {
        let request=UUID();groupsRequest=request;loadingGroups=true
        defer{if groupsRequest==request{loadingGroups=false}}
        do {
            let values=try await engine.codexLoginGroups()
            guard groupsRequest==request,!Task.isCancelled else{return}
            groups=values;groupError=nil
        }catch{if groupsRequest==request,!Task.isCancelled{groupError=error.localizedDescription}}
    }
}

@MainActor struct CodexNewLoginGroupSheet:View {
    let create:(String) async throws->Void
    let cancel:()->Void
    @State private var name=""
    @State private var creating=false
    @State private var error:String?
    @FocusState private var nameFocused:Bool
    private var valid:Bool {!name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && name.count<=80}
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("새 로그인 그룹").font(.title2.weight(.semibold))
            Text("그룹을 만든 뒤 브라우저에서 로그인할 수 있습니다. 새 그룹에는 아직 연결된 세션이 없습니다.")
                .fixedSize(horizontal:false,vertical:true)
            VStack(alignment:.leading,spacing:6) {
                Text("그룹 이름").font(.callout.weight(.medium))
                TextField("",text:$name,prompt:Text("예: 개인 계정")).accessibilityLabel("그룹 이름").textFieldStyle(.roundedBorder).focused($nameFocused)
                    .disabled(creating).onSubmit{submit()}
                Text("1~80자 · 예: 개인 계정, 회사 계정").font(.caption).foregroundStyle(.secondary)
            }
            if let error{Label(error,systemImage:"exclamationmark.circle").foregroundStyle(.red).fixedSize(horizontal:false,vertical:true)}
            HStack(spacing:8) {
                if creating{ProgressView().controlSize(.small);Text("그룹을 만드는 중…").font(.caption)}
                Spacer()
                Button("취소",action:cancel).keyboardShortcut(.cancelAction).disabled(creating)
                Button("만들기",action:submit).keyboardShortcut(.defaultAction).disabled(creating || !valid)
            }
        }.padding(24).frame(width:420).interactiveDismissDisabled(creating)
            .onAppear{nameFocused=true}.onChange(of:name){_,_ in error=nil}
    }
    private func submit() {
        guard valid,!creating else{return};creating=true;error=nil
        let selected=name
        Task {
            defer{creating=false}
            do{try await create(selected)}catch{self.error=error.localizedDescription;creating=false;nameFocused=true}
        }
    }
}
