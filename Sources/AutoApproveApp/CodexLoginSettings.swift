import SwiftUI
import AppKit
import AutoApproveCore

@MainActor struct CodexLoginSettings: View {
    let accounts: AgentAccounts
    let targets: () async throws -> [CodexAccountTransitionTarget]
    let transitionEnabled: Bool
    let transitionBusy: Bool
    let completed: () async -> Void
    var preferredHome:String? = nil
    var reconnect:((String) async throws -> Void)? = nil
    var setupHomes:(() async throws->[String])? = nil
    var serverStatus:((String) async throws->CodexManagedServerStatus)? = nil
    var prepareServer:((String) async throws->CodexManagedServerStatus)? = nil
    var inspectAccount:((String) async throws->CodexAccountInspection)? = nil
    var homeNames:[String:String]=[:]
    var requestedHome:String?=nil
    var groupFocusRequest:String?=nil
    var onLoginActivityChanged:((Bool)->Void)?=nil
    private struct GroupInputs:Equatable {let names:[String:String];let home:String?}
    @State private var handledGroupHome:String?
    @State private var homes:[CodexAccountTransitionTarget]=[]
    @State private var liveHomes:Set<String>=[]
    @State private var selected=NSHomeDirectory()+"/.codex"
    @State private var loading=true
    @State private var job:NativeCodexLoginState?
    @State private var error:String?
    @State private var otherLogin=false
    @State private var managedServer:CodexManagedServerStatus?
    @State private var preparingServer=false
    @State private var reconnecting=false
    @State private var visible=true
    @State private var targetsRequest=UUID()
    @State private var serverRequest=UUID()
    @State private var serverHome:String?
    @State private var serverTask:Task<Void,Never>?
    @State private var checkingServer=false
    @State private var serverObservedAt:Date?
    @State private var inspection:CodexAccountInspection?
    @State private var inspectionError:String?
    @State private var inspectionStale=false
    @State private var inspectionRequest=UUID()
    @State private var inspectionHome:String?
    @State private var inspectionTask:Task<Void,Never>?
    @State private var checkingAccount=false
    private var scopedJob:NativeCodexLoginState? {
        let current=accounts.nativeCodexLogin
        let home=current?.resolvedHome ?? current.flatMap{try? CodexAccountTransitionTarget.canonicalHome($0.home)}
        let preferred=preferredHome.flatMap{try? CodexAccountTransitionTarget.canonicalHome($0)}
        return preferredHome==nil || home==preferred ? current:nil
    }
    private func belongsToSelection(_ job:NativeCodexLoginState?)->Bool {
        guard let job,let home=job.resolvedHome ?? (try? CodexAccountTransitionTarget.canonicalHome(job.home)) else{return false}
        return home==(try? CodexAccountTransitionTarget.canonicalHome(selected))
    }
    var body:some View {
        CodexLoginContent(homes:homes.map(\.home),selected:$selected,loading:loading,
            job:belongsToSelection(job) ? job:nil,disabled:transitionBusy || otherLogin || preparingServer || reconnecting,
            error:error,transitionEnabled:transitionEnabled,begin:{
                let home=selected
                invalidateInspection(keepingValue:true);loading=true
                Task {
                    defer{loading=false}
                    do {
                        let found:[CodexAccountTransitionTarget]
                        do{found=try await targets()}
                        catch{try Task.checkCancellation();guard preferredHome==nil else{throw error};found=[]}
                        try Task.checkCancellation()
                        let target:CodexAccountTransitionTarget
                        if let live=found.first(where:{$0.home==home}){target=live}
                        else if preferredHome==nil{target = .init(home:home,executable:found.first?.executable ?? "codex")}
                        else{throw AppError.message("선택한 세션의 연결이 바뀌었습니다. 계정을 새로 확인해주세요.")}
                        try accounts.beginNativeCodexLogin(target);job=accounts.nativeCodexLogin;error=nil
                    }catch{self.error=error.localizedDescription}
                }
            },cancel:{
                invalidateInspection(keepingValue:true)
                accounts.cancelNativeCodexLogin();job=accounts.nativeCodexLogin
                requestAccountInspection(force:true)
            },open:{value in
                guard AgentAccountOutput.validURL(value,agent:"codex-browser"),let url=URL(string:value),NSWorkspace.shared.open(url) else{
                    error="로그인 페이지를 열지 못했습니다. 브라우저 연결을 확인하고 다시 시도해주세요.";return
                }
            },reconnect:reconnect.map{action in {
                let home=selected;reconnecting=true;invalidateInspection(keepingValue:true)
                Task {
                    defer{reconnecting=false}
                    do{try await action(home);error=nil;await reloadTargets()}
                    catch{let message=error.localizedDescription;await reloadTargets();self.error=message}
                }
            }},canReconnect:liveHomes.contains(selected) || managedServer?.phase == .running,
            connectedCount:homes.first(where:{$0.home==selected})?.witnesses.count,
            refreshTargets:{Task{await reloadTargets()}},serverStatus:managedServer,preparingServer:preparingServer,
            prepareServer:prepareServer.map{action in {
                let home=selected;preparingServer=true
                Task {
                    defer{preparingServer=false}
                    do{
                        let result=try await action(home);await reloadTargets()
                        if selected==home,result.phase == .unavailable,managedServer?.phase != .running{managedServer=result}
                    }catch{self.error=error.localizedDescription;requestServerStatus(force:true)}
                }
            }},checkingServer:checkingServer,serverObservedAt:serverObservedAt,
            inspection:inspection,inspectionError:inspectionError,checkingAccount:checkingAccount,inspectionStale:inspectionStale,
            inspectAccount:inspectAccount.map{_ in {requestAccountInspection(force:true)}},homeNames:homeNames,focusRequest:groupFocusRequest)
        .onChange(of:GroupInputs(names:homeNames,home:requestedHome)){_,input in
            guard preferredHome==nil else{return}
            Task {
                await reloadTargets()
                guard visible,GroupInputs(names:homeNames,home:requestedHome)==input,let home=input.home,handledGroupHome != home,
                      let canonical=try? CodexAccountTransitionTarget.canonicalHome(home),homes.contains(where:{$0.home==canonical}) else{return}
                handledGroupHome=home
                selected=canonical;requestServerStatus(force:true);requestAccountInspection(force:true)
            }
        }
        .onChange(of:selected){_,_ in
            if serverHome != selected{
                serverRequest=UUID();serverTask?.cancel();serverTask=nil;checkingServer=false;managedServer=nil;serverObservedAt=nil;serverHome=nil
            }
            if inspectionHome != selected{invalidateInspection(keepingValue:false)}
            if !loading{requestServerStatus();requestAccountInspection()}
        }
        .onChange(of:transitionBusy){_,busy in
            if busy{invalidateInspection(keepingValue:true)}
            else{requestAccountInspection(force:true)}
        }
        .onDisappear{
            visible=false;targetsRequest=UUID();serverRequest=UUID();serverTask?.cancel();serverTask=nil
            invalidateInspection(keepingValue:true)
        }
        .task {
            visible=true;job=scopedJob
            var reportedBusy=accounts.busy
            onLoginActivityChanged?(reportedBusy)
            await reloadTargets(preferJob:true)
            while !Task.isCancelled {
                let busy=accounts.busy
                if busy != reportedBusy{reportedBusy=busy;onLoginActivityChanged?(busy)}
                let next=scopedJob
                otherLogin=accounts.busy && (next?.active != true || !belongsToSelection(next))
                let succeeded=next?.phase=="succeeded" && (job?.phase != "succeeded" || next?.id != job?.id)
                let changed=next?.id != job?.id || next?.phase != job?.phase
                let relevant=belongsToSelection(next) || belongsToSelection(job)
                job=next
                if changed,relevant {
                    invalidateInspection(keepingValue:true)
                    if next?.active != true{requestAccountInspection(force:true)}
                }
                if succeeded{error=nil;await completed();await reloadTargets()}
                do{try await Task.sleep(for:.milliseconds(250))}catch{return}
            }
        }
    }
    private func reloadTargets(preferJob:Bool=false) async {
        guard visible,!Task.isCancelled else{return}
        let request=UUID();targetsRequest=request;loading=true
        defer{
            if targetsRequest==request{
                loading=false
                if visible,!Task.isCancelled{requestServerStatus(force:true);requestAccountInspection(force:true)}
            }
        }
        do{
            // Keep a session/group-scoped view on its requested home even when
            // live target discovery fails. Never fall back to the default login.
            if let preferredHome{selected=try CodexAccountTransitionTarget.canonicalHome(preferredHome)}
            var found=try await targets();try Task.checkCancellation()
            guard targetsRequest==request,visible else{return}
            liveHomes=Set(found.map(\.home))
            let candidates:[String]
            if let setupHomes{candidates=(try? await setupHomes()) ?? []}else{candidates=[]}
            try Task.checkCancellation();guard targetsRequest==request,visible else{return}
            for home in candidates where !found.contains(where:{$0.home==home}){found.append(.init(home:home,executable:"codex"))}
            let defaultHome=try CodexAccountTransitionTarget.canonicalHome(NSHomeDirectory()+"/.codex")
            if preferredHome==nil,!found.contains(where:{$0.home==defaultHome}){found.insert(.init(home:defaultHome,executable:"codex"),at:0)}
            homes=found
            if let preferredHome{selected=try CodexAccountTransitionTarget.canonicalHome(preferredHome)}
            else if preferJob,let job,let home=job.resolvedHome ?? (try? CodexAccountTransitionTarget.canonicalHome(job.home)),found.contains(where:{$0.home==home}){selected=home}
            else if preferJob,!liveHomes.contains(selected),let live=found.first(where:{liveHomes.contains($0.home)}){selected=live.home}
            else if preferJob,liveHomes.isEmpty,let candidate=candidates.first{selected=candidate}
            else if !found.contains(where:{$0.home==selected}){selected=found.first?.home ?? defaultHome}
            error=nil
        }catch is CancellationError{}catch{
            guard targetsRequest==request,visible else{return}
            liveHomes=[]
            self.error=preferredHome==nil ? "실행 중인 Codex 연결을 확인하지 못했습니다. 연결을 다시 확인하거나 선택한 홈으로 로그인할 수 있습니다.":"선택한 세션의 연결을 확인하지 못했습니다. 연결을 다시 확인해주세요."
        }
    }
    private func requestServerStatus(force:Bool=false) {
        guard visible,let serverStatus else{return}
        let home=selected
        if checkingServer,serverHome==home{return}
        if !force,serverHome==home,managedServer != nil{return}
        if serverHome != home{managedServer=nil;serverObservedAt=nil}
        serverTask?.cancel();serverHome=home;checkingServer=true
        let request=UUID();serverRequest=request
        serverTask=Task {
            defer{if serverRequest==request{checkingServer=false;serverTask=nil}}
            do{
                let value=try await serverStatus(home);try Task.checkCancellation()
                guard visible,selected==home,serverRequest==request else{return}
                managedServer=value;serverObservedAt=Date()
            }catch is CancellationError{}catch{
                guard visible,selected==home,serverRequest==request else{return}
                managedServer = .init(phase:.unavailable,detail:"관리형 서버 상태를 읽지 못했습니다. 로그인과 계정 확인은 별도로 사용할 수 있습니다.")
            }
        }
    }
    private func invalidateInspection(keepingValue:Bool) {
        inspectionRequest=UUID();inspectionTask?.cancel();inspectionTask=nil;checkingAccount=false;inspectionError=nil
        inspectionStale=keepingValue && inspection != nil
        if !keepingValue{inspection=nil;inspectionHome=nil}
    }
    private func requestAccountInspection(force:Bool=false) {
        guard visible,let inspectAccount else{return}
        let home=selected
        if !force,checkingAccount,inspectionHome==home{return}
        if !force,inspectionHome==home,inspection != nil{return}
        if inspectionHome != home{inspection=nil;inspectionError=nil}
        inspectionTask?.cancel();inspectionHome=home;checkingAccount=true;inspectionStale=inspection != nil;inspectionError=nil
        let request=UUID();inspectionRequest=request
        inspectionTask=Task {
            defer{if inspectionRequest==request{checkingAccount=false;inspectionTask=nil}}
            do{
                let value=try await inspectAccount(home);try Task.checkCancellation()
                guard visible,selected==home,inspectionRequest==request else{return}
                inspection=value;inspectionStale=belongsToSelection(scopedJob) && scopedJob?.active==true
            }catch is CancellationError{}catch{
                guard visible,selected==home,inspectionRequest==request else{return}
                inspectionError=error.localizedDescription;inspectionStale=inspection != nil
            }
        }
    }
}

struct CodexLoginContent: View {
    let homes: [String]
    @Binding var selected: String
    let loading: Bool
    let job: NativeCodexLoginState?
    let disabled: Bool
    let error: String?
    let transitionEnabled: Bool
    let begin: () -> Void
    let cancel: () -> Void
    let open: (String) -> Void
    var reconnect:(()->Void)? = nil
    var canReconnect=true
    var connectedCount:Int? = nil
    var refreshTargets:(()->Void)? = nil
    var serverStatus:CodexManagedServerStatus? = nil
    var preparingServer=false
    var prepareServer:(()->Void)? = nil
    var checkingServer=false
    var serverObservedAt:Date? = nil
    var inspection:CodexAccountInspection? = nil
    var inspectionError:String? = nil
    var checkingAccount=false
    var inspectionStale=false
    var inspectAccount:(()->Void)? = nil
    var homeNames:[String:String]=[:]
    var focusRequest:String?=nil
    @FocusState private var groupFocused:Bool
    private var active: Bool { job?.active == true }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if homeNames.isEmpty{Text("Codex 로그인").font(.callout.weight(.semibold)).foregroundStyle(.primary)}
            if homes.count > 1 {
                Picker(homeNames.isEmpty ? "로그인할 Codex 홈":"로그인 그룹", selection: $selected) {
                    ForEach(homes, id: \.self) { Text(homeNames[$0] ?? $0).lineLimit(1).truncationMode(.middle).help($0).tag($0) }
                }.disabled(active || loading || disabled).focused($groupFocused)
                    .onChange(of:focusRequest){_,home in
                        if let home,selected==(try? CodexAccountTransitionTarget.canonicalHome(home)){groupFocused=true}
                    }
                    .onChange(of:selected){_,home in
                        if let focusRequest,home==(try? CodexAccountTransitionTarget.canonicalHome(focusRequest)){groupFocused=true}
                    }
            }
            if homes.count==1,let name=homeNames[selected]{Text(name).font(.callout.weight(.semibold))}
            Text(active ? job?.home ?? selected : selected)
                .font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if canReconnect,let connectedCount,connectedCount>0 {
                Label("연결 확인 · Codex \(connectedCount)개",systemImage:"checkmark.circle").font(.caption)
            }else if homeNames[selected] != nil,connectedCount==0 {
                Label("연결 확인된 Codex 0개",systemImage:"info.circle").font(.caption).foregroundStyle(.secondary)
            }
            accountSummary
            Text("기본 브라우저에서 계정을 선택하면 이 창에 로그인 완료가 표시됩니다. 기존 창은 유지됩니다.")
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in:.horizontal) {
                HStack(spacing:8){loginButtons}
                VStack(alignment:.leading,spacing:8){loginButtons}
            }
            if let job {
                HStack(spacing: 6) {
                    if ["starting", "verifying"].contains(job.phase) { ProgressView().controlSize(.small) }
                    if job.phase=="succeeded" {Image(systemName:"checkmark.circle.fill").foregroundStyle(.green)}
                    Text(title(job)).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }.accessibilityElement(children: .combine)
                if job.phase == "waiting", let url = job.url, AgentAccountOutput.validURL(url, agent: "codex-browser") {
                    Button("로그인 페이지 다시 열기") { open(url) }
                    Text("auth.openai.com").font(.caption)
                    Text("열린 브라우저에서 로그인한 뒤 이 창에서 완료를 기다려주세요.").font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            serverDetails
            if let error {
                Label {Text(error).foregroundStyle(.primary)} icon: {Image(systemName:"exclamationmark.circle").foregroundStyle(.red)}
                    .fixedSize(horizontal:false,vertical:true)
            }
            if let reconnect {
                HStack(spacing:8) {
                    Button("현재 로그인으로 세션 재연결",action:reconnect).disabled(active || loading || disabled || !canReconnect)
                        .help(canReconnect ? "기존 터미널을 같은 대화로 연결한 뒤 저장된 로그인을 적용합니다. 실행 중 Goal은 먼저 일시정지하고 작업 중단을 확인합니다. 질문·초안은 유지합니다. 직접 요청한 시점에 확인한 상주 도구 호스트는 Codex 정상 종료 때 정리합니다.":"선택한 홈의 실제 연결을 먼저 확인해주세요. 로그인은 연결 확인 없이도 시작할 수 있습니다.")
                    if let refreshTargets {
                        Button("연결 다시 확인",systemImage:"arrow.clockwise",action:refreshTargets).disabled(active || loading || disabled)
                            .help("이 Mac의 서버·세션 연결만 다시 읽습니다. 작업을 중단하거나 계정을 바꾸지 않습니다.")
                    }
                }
                if !loading,!canReconnect {
                    Label(serverStatus?.phase == .running
                        ? "관리형 서버는 실행 중입니다. 기존 세션 연결 진행·보류 이유는 아래에서 확인할 수 있습니다."
                        : "이 홈의 서버·세션 연결은 아직 확인되지 않았습니다. 연결을 다시 확인하거나 먼저 로그인해주세요.",systemImage:"info.circle")
                        .font(.caption).fixedSize(horizontal:false,vertical:true)
                }
            }
            Text("직접 재연결하면 실행 중 Goal을 먼저 일시정지하고 작업 중단을 확인합니다. 이후 Codex를 정상 종료해 확인한 상주 도구 호스트를 정리합니다. 셸이 없으면 같은 창의 복구 탭으로 대화를 옮깁니다. 로그인 완료 후 연결이 확인된 관리형 Codex 작업을 순차 중단합니다. Goal은 일시정지하고 Codex 백그라운드 작업은 종료한 뒤 새 계정으로 전환합니다. 이 창을 닫아도 계속 진행합니다.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }
    @ViewBuilder private var loginButtons:some View {
        if let inspectAccount {
            Button("현재 로그인 확인",action:inspectAccount).disabled(loading || checkingAccount)
                .help("계정만 읽습니다. 자동 전환 설정과 무관하며 작업을 중단하거나 서버를 전환하지 않습니다.")
        }
        Button(job == nil ? "브라우저로 로그인":"다시 로그인",action:begin)
            .disabled(active || loading || disabled)
            .help(disabled ? "진행 중인 로그인·서버 전환이 끝난 뒤 로그인해주세요.":"선택한 Codex 홈에서 공식 브라우저 로그인을 시작합니다.")
        if active{Button("로그인 취소",action:cancel)}
        if loading{ProgressView().controlSize(.small).accessibilityLabel("Codex 홈 확인 중")}
    }
    @ViewBuilder private var accountSummary:some View {
        if inspection != nil || checkingAccount || inspectionError != nil {
            VStack(alignment:.leading,spacing:6) {
                if let inspection {
                    Text(inspectionStale ? "마지막으로 확인한 연결 계정":"연결 서버 계정").font(.caption).foregroundStyle(.secondary)
                    if let identity=inspection.identity {
                        Text(identity.email ?? identity.provider).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                        let detail=[identity.email != nil ? identity.provider:nil,identity.plan].compactMap{$0}.joined(separator:" · ")
                        if !detail.isEmpty{Text(detail).font(.caption).foregroundStyle(.secondary)}
                    }
                    Label(inspection.detail,systemImage:inspection.comparison == .same ? "checkmark.circle":"info.circle")
                        .font(.caption).fixedSize(horizontal:false,vertical:true)
                    Text("확인 시각 · "+inspection.observedAt.formatted(date:.omitted,time:.standard))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if checkingAccount {
                    HStack(spacing:6){ProgressView().controlSize(.small);Text("로그인 계정 확인 중…").font(.caption)}
                        .accessibilityElement(children:.combine)
                }
                if let inspectionError {
                    Label(inspectionError,systemImage:"exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal:false,vertical:true)
                }
            }
        }
    }
    @ViewBuilder private var serverDetails:some View {
        if checkingServer {
            HStack(spacing:6){ProgressView().controlSize(.small);Text("서버 상태 확인 중…").font(.caption)}
                .accessibilityElement(children:.combine)
        }
            if let state=serverStatus {
                VStack(alignment:.leading,spacing:8) {
                    Label {Text(state.detail).foregroundStyle(.primary)} icon: {
                        Image(systemName:state.phase == .running ? "checkmark.circle":"info.circle")
                    }.fixedSize(horizontal:false,vertical:true)
                    if let version=state.version {Text("Codex \(version)").font(.caption)}
                    if let enabled=state.autoStartEnabled {Text("일반 Codex 실행의 데몬 자동 시작 · \(enabled ? "켜짐":"꺼짐")").font(.caption)}
                    if state.canPrepare,let prepareServer {
                        Button(state.phase == .running ? "데몬 자동 시작 켜기":"관리형 서버 준비",systemImage:"server.rack",action:prepareServer)
                            .disabled(active || loading || disabled)
                            .help("선택한 홈의 데몬 자동 시작을 켜고, 서버가 없으면 준비합니다. 실행 중인 서버는 재시작하지 않습니다.")
                    }
                    if preparingServer {Label("관리형 서버 준비 중…",systemImage:"hourglass").accessibilityLabel("관리형 서버 준비 중")}
                    if state.phase == .running,(connectedCount ?? 0)==0 {
                        Text("서버는 실행 중이며 기존 Codex의 자동 연결을 확인합니다. 작업·Goal·질문·초안이 있으면 기다리고, 원본 셸과 대화를 확인한 세션은 같은 창에서 다시 연결합니다. 확인할 수 없는 경우 아래에 보류 이유를 표시합니다.")
                            .font(.caption).fixedSize(horizontal:false,vertical:true)
                    }
                    if [.missingCLI,.unsupported].contains(state.phase) {
                        Link(destination:URL(string:"https://developers.openai.com/codex/cli")!) {
                            Label("Codex 설치·업데이트 안내",systemImage:"arrow.up.right")
                        }.foregroundStyle(Color(nsColor:.linkColor))
                    }
                }.padding(.vertical,4)
            }
        if let serverObservedAt {
            Text("서버 확인 시각 · "+serverObservedAt.formatted(date:.omitted,time:.standard)).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func title(_ job: NativeCodexLoginState) -> String {
        switch job.phase {
        case "starting": return "브라우저 로그인 준비 중…"
        case "waiting": return "브라우저에서 로그인해주세요"
        case "verifying": return "로그인 완료 확인 중…"
        default: return job.message ?? "로그인 상태를 확인해주세요."
        }
    }
}
