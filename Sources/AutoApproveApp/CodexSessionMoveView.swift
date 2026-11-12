import SwiftUI
import AutoApproveCore

private struct CodexMoveDestination:Identifiable {
    let target:CodexAccountTransitionTarget
    let name:String
    var id:String {target.home}
}

/// Prepares the destination, reviews the stored conversation scope, and runs
/// the engine's journaled move plus original-terminal reconnection.
@MainActor struct CodexSessionMoveView:View {
    let engine:ApprovalEngine
    let source:CodexSessionAccount
    let close:()->Void
    @State private var destinations:[CodexMoveDestination]=[]
    @State private var selected:String?
    @State private var loading=true
    @State private var error:String?
    @State private var busy=false
    @State private var held=false
    @State private var loginBusy=false
    @State private var plan:CodexSessionMovePlan?
    @State private var moving=false
    @State private var attempted=false
    @State private var notice:String?
    private var destination:CodexMoveDestination? {destinations.first{$0.id==selected}}
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack {
                Text("로그인 그룹 변경").font(.title2.weight(.semibold))
                Spacer()
                Button("닫기",action:close).keyboardShortcut(.cancelAction)
                    .disabled(moving || plan != nil && !attempted)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    VStack(alignment:.leading,spacing:6) {
                        Text("현재 연결").font(.callout.weight(.semibold))
                        Text(source.loginGroupName ?? "기존 Codex 홈").fixedSize(horizontal:false,vertical:true)
                        Text(source.target.home).font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                        Text(source.identity.email ?? source.identity.provider).textSelection(.enabled)
                            .fixedSize(horizontal:false,vertical:true)
                        if let pid=source.serverPID {
                            Text("Codex app-server · PID \(String(pid))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    VStack(alignment:.leading,spacing:10) {
                        HStack {
                            Text("옮길 로그인 그룹").font(.callout.weight(.semibold))
                            Spacer()
                            Button("새로 확인"){Task{await load()}}
                                .disabled(loading || loginBusy || busy || held || plan != nil || moving)
                        }
                        if loading {ProgressView("로그인 그룹 확인 중…").controlSize(.small)}
                        if let error {
                            Label(error,systemImage:"exclamationmark.circle")
                                .foregroundStyle(.red).fixedSize(horizontal:false,vertical:true)
                        } else if !loading, destinations.isEmpty {
                            Text("다른 로그인 그룹이 없습니다. 계정·로그인에서 새 그룹을 만든 뒤 다시 확인해주세요.")
                                .foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                        }
                        if !destinations.isEmpty {
                            Picker("대상 그룹",selection:$selected) {
                                Text("그룹 선택").tag(Optional<String>.none)
                                ForEach(destinations){value in
                                    Text(value.name).lineLimit(1).help(value.target.home).tag(Optional(value.id))
                                }
                            }.disabled(loading || busy || held || loginBusy || plan != nil || moving)
                        }
                    }
                    if let destination {
                        VStack(alignment:.leading,spacing:8) {
                            Label("대상 그룹의 연결 서버",systemImage:"server.rack").font(.callout.weight(.semibold))
                            Text(destination.target.home).font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                            Text("선택한 그룹의 로그인과 Codex app-server를 확인합니다.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                            CodexLoginSettings(accounts:engine.agentAccounts,targets:{try await verifiedTarget(destination)},
                                transitionEnabled:engine.codexAccountTransitionEnabled,transitionBusy:busy || held,
                                completed:{},preferredHome:destination.target.home,
                                setupHomes:{[destination.target.home]},
                                serverStatus:{try await engine.codexManagedServerStatus(home:$0)},
                                prepareServer:{try await engine.prepareCodexManagedServer(home:$0)},
                                inspectAccount:{try await engine.inspectCodexAccount(home:$0)},
                                homeNames:[destination.target.home:destination.name],
                                onLoginActivityChanged:{loginBusy=$0})
                                .id(destination.id)
                                .disabled(plan != nil || moving)
                        }
                    }
                    Divider()
                    VStack(alignment:.leading,spacing:8) {
                        Label("기존 대화 이동",systemImage:"arrow.right.arrow.left").font(.callout.weight(.semibold))
                        Text("이 세션의 대화와 하위 서브에이전트를 선택한 로그인 그룹으로 옮긴 뒤, 원래 터미널에서 같은 대화를 다시 연결합니다. 진행 중인 Goal·작업·작성 중 입력은 먼저 정리해주세요.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                        if let plan {
                            Text("이동할 대화 \(plan.conversationCount)개 · 서브에이전트 포함")
                                .font(.callout.weight(.medium)).fixedSize(horizontal:false,vertical:true)
                            if !attempted {
                                HStack {
                                    Button("이 그룹으로 이동하고 재연결"){performMove(plan)}
                                        .disabled(moving || busy || held || loginBusy)
                                    Button("준비 취소"){
                                        do {try engine.cancelCodexSessionMove(id:plan.id);self.plan=nil;error=nil}
                                        catch {self.error=error.localizedDescription}
                                    }.disabled(moving)
                                }
                            }
                        }else if notice == nil {
                            Button("이동 범위 확인"){prepareMove()}
                                .disabled(destination == nil || loading || loginBusy || busy || held || moving)
                        }
                        if moving {ProgressView(attempted ? "대화 이동·재연결 중…":"이동할 대화 확인 중…").controlSize(.small)}
                        if let notice {Text(notice).font(.caption).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)}
                    }
                }.padding(24).frame(maxWidth:.infinity,alignment:.leading)
            }
        }.font(.callout).frame(width:600,height:660)
            .interactiveDismissDisabled(moving || plan != nil && !attempted)
            .task{await load()}
            .onReceive(engine.$codexAccountTransitionBusy){busy=$0}
            .onReceive(engine.$codexAccountTransitionStates){states in
                held=states.values.contains(where:\.held)
            }
    }
    private func prepareMove() {
        guard let destination,!moving else{return}
        moving=true;error=nil;notice=nil
        Task { @MainActor in
            defer{moving=false}
            do {plan=try await engine.prepareCodexSessionMove(sessionID:source.sessionID,destinationHome:destination.id)}
            catch {self.error=error.localizedDescription}
        }
    }
    private func performMove(_ plan:CodexSessionMovePlan) {
        guard !moving,!attempted else{return}
        moving=true;attempted=true;error=nil
        Task { @MainActor in
            defer{moving=false}
            do {
                let result=try await engine.performCodexSessionMove(id:plan.id)
                notice=result.detail
                if result.phase == .connected {self.plan=nil}
                else {error="이동 후 연결 확인이 필요합니다. "+result.detail}
            }catch {
                self.error=error.localizedDescription
                notice="이동 결과를 확인해야 합니다. 같은 요청을 자동으로 반복하지 않습니다."
            }
        }
    }
    private func load() async {
        guard !loginBusy else{return}
        loading=true;error=nil
        defer{loading=false}
        do {
            async let groups=engine.codexLoginGroups()
            async let targets=engine.codexLoginTargets()
            let (names,live)=try await (groups,targets)
            try Task.checkCancellation()
            var values=Dictionary(live.map{($0.home,$0)},uniquingKeysWith:{first,_ in first})
            for group in names where values[group.home]==nil {
                values[group.home] = .init(home:group.home,executable:source.target.executable)
            }
            let baseline=try CodexAccountTransitionTarget.canonicalHome(NSHomeDirectory()+"/.codex")
            if values[baseline]==nil {values[baseline] = .init(home:baseline,executable:source.target.executable)}
            let named=Dictionary(names.map{($0.home,$0.name)},uniquingKeysWith:{first,_ in first})
            destinations=values.values.filter{$0.home != source.target.home}.map {
                .init(target:$0,name:named[$0.home] ?? ($0.home==baseline ? "기본 로그인":$0.home))
            }.sorted{$0.name.localizedStandardCompare($1.name) == .orderedAscending}
            if !destinations.contains(where:{$0.id==selected}) {selected=nil}
        } catch is CancellationError {} catch {self.error=error.localizedDescription;destinations=[];selected=nil}
    }
    private func verifiedTarget(_ expected:CodexMoveDestination) async throws->[CodexAccountTransitionTarget] {
        let current=try await engine.codexSessionAccount(sessionID:source.sessionID)
        guard current.target==source.target,current.serverPID==source.serverPID,current.identity==source.identity else {
            throw AppError.message("현재 세션의 연결이 바뀌었습니다. 창을 닫고 계정을 다시 확인해주세요.")
        }
        let groups=try await engine.codexLoginGroups()
        let live=try await engine.codexLoginTargets()
        if let target=live.first(where:{$0.home==expected.id}) {return [target]}
        let baseline=try CodexAccountTransitionTarget.canonicalHome(NSHomeDirectory()+"/.codex")
        guard groups.contains(where:{$0.home==expected.id}) || expected.id==baseline else {
            throw AppError.message("대상 로그인 그룹이 바뀌었습니다. 그룹을 다시 확인해주세요.")
        }
        return [expected.target]
    }
}
