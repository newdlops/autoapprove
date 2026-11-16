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
    var source:CodexSessionAccount?=nil
    var standalone:CodexStandaloneSession?=nil
    var independentDestination:CodexIndependentLogin?=nil
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
    @State private var copyingLogin=false
    @State private var copiedLogin=false
    @State private var completed=false
    private var destination:CodexMoveDestination? {destinations.first{$0.id==selected}}
    private var sourceHome:String {source?.target.home ?? standalone?.home ?? ""}
    private var sourceExecutable:String {source?.target.executable ?? standalone?.executable ?? "codex"}
    var body:some View {
        if CodexFeatureSupport.canMoveOpenSessions {supportedContent}
        else {CodexSessionMoveUnavailableView(close:close)}
    }
    private var supportedContent:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack {
                Text(independentDestination != nil ? "독립 실행으로 분리":standalone == nil ? "로그인 그룹 변경":"독립 세션을 그룹에 연결").font(.title2.weight(.semibold))
                Spacer()
                Button("닫기",action:close).keyboardShortcut(.cancelAction)
                    .disabled(moving || copyingLogin || plan != nil && !attempted)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    VStack(alignment:.leading,spacing:6) {
                        Text(completed ? "이전 연결":"현재 연결").font(.callout.weight(.semibold))
                        Text(source?.loginGroupName ?? (standalone == nil ? "기존 Codex 홈":"독립 실행 · 공유 서버에 연결되지 않음")).fixedSize(horizontal:false,vertical:true)
                        Text(sourceHome).font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                        if let source {
                            Text(source.identity.email ?? source.identity.provider).textSelection(.enabled)
                                .fixedSize(horizontal:false,vertical:true)
                        }
                        if let pid=source?.serverPID {
                            Text("Codex app-server · PID \(String(pid))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    VStack(alignment:.leading,spacing:10) {
                        HStack {
                            Text(independentDestination == nil ? "옮길 로그인 그룹":"전용 로그인 홈").font(.callout.weight(.semibold))
                            Spacer()
                            Button("새로 확인"){Task{await load()}}
                                .disabled(loading || loginBusy || busy || held || plan != nil || moving || attempted)
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
                            }.disabled(loading || busy || held || loginBusy || plan != nil || moving || attempted)
                        }
                    }
                    if let destination {
                        if let independentDestination,let source {
                            VStack(alignment:.leading,spacing:8) {
                                Text("현재 그룹의 로그인과 설정을 전용 홈에 복사하거나 아래에서 별도로 로그인할 수 있습니다.")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                                Button(copiedLogin ? "그룹 로그인·설정 복사됨":"현재 그룹의 로그인·설정 사용") {
                                    copyingLogin=true;error=nil
                                    Task { @MainActor in
                                        defer{copyingLogin=false}
                                        do {
                                            try await engine.copyCodexLoginToIndependentHome(sessionID:source.sessionID,independentID:independentDestination.id)
                                            copiedLogin=true
                                        }catch {self.error=error.localizedDescription}
                                    }
                                }.disabled(copyingLogin || copiedLogin || plan != nil || moving || loginBusy || busy || held || attempted)
                                if copyingLogin {ProgressView("독립 로그인 준비 중…").controlSize(.small)}
                            }
                        }
                        VStack(alignment:.leading,spacing:8) {
                            Label(independentDestination == nil ? "대상 그룹의 연결 서버":"전용 로그인 서버",systemImage:"server.rack").font(.callout.weight(.semibold))
                            Text(destination.target.home).font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                            Text(independentDestination == nil ? "선택한 그룹의 로그인과 Codex app-server를 확인합니다.":"이 세션의 전용 홈에서 실행하는 로컬 서버입니다. 다른 로그인 그룹의 계정과 분리되며 Goal 제어·복원 기능을 유지합니다.")
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
                                .disabled(plan != nil || moving || attempted)
                        }
                    }
                    Divider()
                    VStack(alignment:.leading,spacing:8) {
                        Label("기존 대화 이동",systemImage:"arrow.right.arrow.left").font(.callout.weight(.semibold))
                        Text("대화·하위 서브에이전트·Goal을 저장한 뒤 원래 터미널에서 같은 Session ID로 다시 연결합니다. 진행 중인 명령은 중단될 수 있으며 자동으로 재실행하지 않습니다.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                        if standalone != nil {
                            Text("선택한 독립 세션만 다시 연결합니다. 이미 서버에 연결된 다른 터미널은 종료하지 않습니다.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                        }
                        if let plan {
                            CodexMoveScopeSummary(conversationCount:plan.conversationCount,restartingSessionCount:plan.restartingSessionCount)
                            if !attempted {
                                HStack {
                                    Button(independentDestination == nil ? "이 그룹으로 이동하고 재연결":"독립 실행으로 전환"){performMove(plan)}
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
                        if let notice {
                            CodexMoveProgressNotice(detail:notice,complete:completed)
                        }
                    }
                }.padding(24).frame(maxWidth:.infinity,alignment:.leading)
            }
        }.font(.callout).frame(width:600,height:660)
            .interactiveDismissDisabled(moving || copyingLogin || plan != nil && !attempted)
            .task{await load()}
            .task(id:attempted ? plan?.id:nil) {
                guard attempted,let id=plan?.id else{return}
                while !Task.isCancelled,plan?.id==id {
                    do {
                        if let progress=try engine.codexSessionMoveProgress(id:id) {
                            notice=progress.detail
                            if progress.complete {completed=true;error=nil;plan=nil;return}
                        }
                        try await Task.sleep(for:.seconds(1))
                    }catch is CancellationError {return}
                    catch {self.error=error.localizedDescription;return}
                }
            }
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
            do {
                if let standalone {
                    plan=try await engine.prepareStandaloneCodexSessionMove(sessionID:standalone.sessionID,destinationHome:destination.id)
                }else if let source {
                    plan=try await engine.prepareCodexSessionMove(sessionID:source.sessionID,destinationHome:destination.id)
                }
            }
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
                if result.phase == .connected {completed=true;self.plan=nil}
                else {error="이동 후 연결 확인이 필요합니다. "+result.detail}
            }catch {
                self.error=error.localizedDescription
                if (try? engine.codexSessionMoveProgress(id:plan.id))?.canCancel==true {attempted=false}
                notice="저장된 단계에서 복원 결과를 확인합니다. 확인되지 않은 실행 명령은 중복 전송하지 않습니다."
            }
        }
    }
    private func load() async {
        guard !loginBusy else{return}
        loading=true;error=nil
        defer{loading=false}
        do {
            if let independentDestination {
                guard try await engine.codexIndependentLogins().contains(independentDestination) else {
                    throw AppError.message("독립 로그인 홈이 바뀌었습니다. 창을 닫고 다시 준비해주세요.")
                }
                let target=CodexAccountTransitionTarget(home:independentDestination.home,executable:sourceExecutable)
                destinations=[.init(target:target,name:independentDestination.name)];selected=target.home
                return
            }
            async let groups=engine.codexLoginGroups()
            async let targets=engine.codexLoginTargets()
            let (names,live)=try await (groups,targets)
            try Task.checkCancellation()
            var values=Dictionary(live.map{($0.home,$0)},uniquingKeysWith:{first,_ in first})
            for group in names where values[group.home]==nil {
                values[group.home] = .init(home:group.home,executable:sourceExecutable)
            }
            let baseline=try CodexAccountTransitionTarget.canonicalHome(NSHomeDirectory()+"/.codex")
            if values[baseline]==nil {values[baseline] = .init(home:baseline,executable:sourceExecutable)}
            let named=Dictionary(names.map{($0.home,$0.name)},uniquingKeysWith:{first,_ in first})
            let currentHome=try CodexAccountTransitionTarget.canonicalHome(sourceHome)
            destinations=values.values.filter{(try? CodexAccountTransitionTarget.canonicalHome($0.home)) != currentHome}.map {
                .init(target:$0,name:named[$0.home] ?? ($0.home==baseline ? "기본 로그인":$0.home))
            }.sorted{$0.name.localizedStandardCompare($1.name) == .orderedAscending}
            if !destinations.contains(where:{$0.id==selected}) {selected=nil}
        } catch is CancellationError {} catch {self.error=error.localizedDescription;destinations=[];selected=nil}
    }
    private func verifiedTarget(_ expected:CodexMoveDestination) async throws->[CodexAccountTransitionTarget] {
        if let standalone {
            guard try await engine.codexStandaloneSession(sessionID:standalone.sessionID)==standalone else {
                throw AppError.message("독립 세션의 실행이 바뀌었습니다. 창을 닫고 다시 확인해주세요.")
            }
        }else if let source {
            let current=try await engine.codexSessionAccount(sessionID:source.sessionID)
            guard current.target==source.target,current.serverPID==source.serverPID,current.identity==source.identity else {
                throw AppError.message("현재 세션의 연결이 바뀌었습니다. 창을 닫고 계정을 다시 확인해주세요.")
            }
        }
        let groups=try await engine.codexLoginGroups()
        let live=try await engine.codexLoginTargets()
        if let target=live.first(where:{$0.home==expected.id}) {return [target]}
        let baseline=try CodexAccountTransitionTarget.canonicalHome(NSHomeDirectory()+"/.codex")
        let independent=try await engine.codexIndependentLogins()
        guard groups.contains(where:{$0.home==expected.id}) || independent.contains(where:{$0.home==expected.id}) || expected.id==baseline else {
            throw AppError.message("대상 로그인 그룹이 바뀌었습니다. 그룹을 다시 확인해주세요.")
        }
        return [expected.target]
    }
}

struct CodexMoveScopeSummary:View {
    let conversationCount:Int,restartingSessionCount:Int
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Text("이동할 대화 \(conversationCount)개 · 서브에이전트 포함")
                .font(.callout.weight(.medium)).fixedSize(horizontal:false,vertical:true)
            Text(restartingSessionCount>1
                 ? "같은 서버의 터미널 \(restartingSessionCount)개를 종료·다시 엽니다. 선택한 터미널만 대상 그룹으로 옮기고, 나머지는 원래 로그인 그룹으로 복원합니다."
                 : "선택한 터미널만 종료·다시 엽니다. 다른 터미널은 유지합니다.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }
    }
}

struct CodexMoveProgressNotice:View {
    let detail:String,complete:Bool
    var body:some View {
        Label(detail,systemImage:complete ? "checkmark.circle":"clock")
            .foregroundStyle(complete ? Color.green:Color.secondary)
            .font(.caption).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
    }
}

struct CodexSessionMoveUnavailableView:View {
    let close:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Text("기존 대화 이동 미지원").font(.title2.weight(.semibold))
                Spacer()
                Button("닫기",action:close).keyboardShortcut(.cancelAction)
            }
            Label(CodexFeatureSupport.sessionMoveUnavailable,systemImage:"info.circle")
                .foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }.padding(24).font(.callout).frame(width:600,alignment:.leading)
    }
}
