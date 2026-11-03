// Production account views with synthetic metadata and an isolated fake auth CLI.
// Never opens a browser, reads a real credential, or controls a user session.
import AppKit
import SwiftUI
import AutoApproveCore

private let fixtureHomes=["/Users/alex/.codex","/Users/서연/Library/Application Support/Codex data/"+String(repeating:"긴 저장소 이름/",count:8),"/Volumes/Workspace/users/team/.codex"]

@MainActor private final class AccountsFixture:ObservableObject {
    @Published var mode="connected"
    @Published var profile=1
    @Published var reconnectFails=false
    @Published var preparationFails=false
    var reads=0,reconnects=0,preparations=0,serverReads=0,inspectionReads=0
    var inspectedHomes:[String]=[]
    let root:URL
    let accounts:AgentAccounts
    init(root:URL) throws {
        self.root=root
        let services=try AgentAccountFixture.services(root,codexBrowser:true)
        accounts=AgentAccounts(services:services,codexServices:{target in
            let data=try JSONSerialization.data(withJSONObject:["home":target.home,"executable":target.executable])
            try data.write(to:root.appendingPathComponent("login-target.json"),options:.atomic)
            return services
        })
    }
    func targets() async throws->[CodexAccountTransitionTarget] {
        reads+=1;record()
        try await Task.sleep(for:.milliseconds(180))
        if mode=="error" {throw AppError.message("Synthetic discovery failure")}
        guard mode=="connected" else{return []}
        return [.init(home:fixtureHomes[profile],executable:["/opt/homebrew/bin/codex","/usr/local/bin/codex","/Users/team/.local/bin/codex"][profile],
            witnesses:(0..<3).map{.init(pid:Int32(9100+$0),started:"synthetic",tty:"/dev/fixture\($0)",threadID:nil)})]
    }
    func reconnect(_ home:String) async throws {
        reconnects+=1;record()
        if reconnectFails {mode="empty";throw AppError.message("합성 검사: 연결이 바뀌었습니다. 연결을 다시 확인해주세요.")}
    }
    func serverStatus() ->CodexManagedServerStatus {
        switch mode {
        case "stopped":return .init(phase:.stopped,version:"0.166.0",detail:"이 홈의 관리형 Codex 서버가 아직 준비되지 않았습니다.")
        case "disabled":return .init(phase:.running,version:"0.166.0",detail:"이 홈의 관리형 Codex 서버가 실행 중입니다.",autoStartEnabled:false)
        case "missing":return .init(phase:.missingCLI,detail:"이 Mac의 로그인 셸에서 Codex CLI를 찾지 못했습니다. Codex를 설치한 뒤 연결을 다시 확인해주세요.")
        case "unsupported":return .init(phase:.unsupported,version:"0.165.0",detail:"Codex 0.165.0은 관리형 서버 자동 전환 대상이 아닙니다. Codex 0.166.0 이상으로 업데이트해주세요.")
        case "error":return .init(phase:.unavailable,detail:"관리형 서버 상태를 읽지 못했습니다. 연결을 다시 확인해주세요.")
        default:return .init(phase:.running,version:"0.166.0",detail:"이 홈의 관리형 Codex 서버가 실행 중입니다.",autoStartEnabled:true)
        }
    }
    func readServerStatus() async throws ->CodexManagedServerStatus {
        serverReads+=1;record()
        while FileManager.default.fileExists(atPath:root.appendingPathComponent("hold-server-status").path) {
            try await Task.sleep(for:.milliseconds(50))
        }
        return serverStatus()
    }
    func inspectAccount(_ home:String) async throws ->CodexAccountInspection {
        inspectionReads+=1;inspectedHomes.append(home);record()
        while FileManager.default.fileExists(atPath:root.appendingPathComponent("hold-account-status").path) {
            // Deliberately return a late answer despite consumer cancellation.
            await Task.detached{try? await Task.sleep(for:.milliseconds(50))}.value
        }
        if FileManager.default.fileExists(atPath:root.appendingPathComponent("fail-account-status").path){throw AppError.message("합성 계정 조회가 지연되었습니다. 마지막 확인 계정은 유지합니다.")}
        let number=fixtureHomes.firstIndex(of:home).map{$0+1} ?? 0
        return .init(home:home,identity:.init(provider:"ChatGPT",email:"profile-\(number)@example.test",plan:"pro"),comparison:.same,connectedSessions:3)
    }
    func prepare() async throws ->CodexManagedServerStatus {
        preparations+=1;record();try await Task.sleep(for:.milliseconds(350))
        if preparationFails {mode="error";throw AppError.message("합성 검사: 서버 준비 결과를 확인하지 못했습니다. 연결을 다시 확인해주세요.")}
        mode="ready-empty";record();return serverStatus()
    }
    func record() {
        let data=try! JSONSerialization.data(withJSONObject:["reads":reads,"reconnects":reconnects,"preparations":preparations,"serverReads":serverReads,"inspectionReads":inspectionReads,"inspectedHomes":inspectedHomes,"mode":mode,"profile":profile])
        try! data.write(to:root.appendingPathComponent("ui-counters.json"),options:.atomic)
    }
}
@MainActor private struct FixtureControls:View {
    @ObservedObject var fixture:AccountsFixture
    @Environment(\.openWindow) var openWindow
    var body:some View {
        Form {
            Text("합성 연결 메타데이터만 사용합니다. 실제 Codex·계정·Terminal은 조작하지 않습니다.")
            Picker("연결 대역",selection:$fixture.mode) {
                Text("연결됨").tag("connected");Text("연결 미확인").tag("empty");Text("조회 실패").tag("error")
                Text("서버 미준비").tag("stopped");Text("서버만 실행 중").tag("ready-empty");Text("구버전 CLI").tag("unsupported");Text("CLI 미설치").tag("missing")
                Text("자동 시작 꺼짐").tag("disabled")
            }
            Picker("머신 프로필",selection:$fixture.profile) {ForEach(0..<3,id:\.self) {Text("프로필 \($0+1)").tag($0)}}
            Toggle("재연결 중 연결 유실",isOn:$fixture.reconnectFails)
            Toggle("서버 준비 실패",isOn:$fixture.preparationFails)
            Button("합성 로그인 완료") {try? Data().write(to:fixture.root.appendingPathComponent("signed-codex"))}
        }.padding(24).frame(width:600,height:280)
        .toolbar {
            ToolbarItem(placement:.primaryAction) {
                Button {openWindow(id:"accounts")} label: {Label("계정·로그인",systemImage:"person.crop.circle")}
                    .labelStyle(.iconOnly).accessibilityIdentifier("account-login-entry").help("계정·로그인 · ⌘⇧L")
            }
        }
    }
}
@MainActor private struct FixtureAccounts:View {
    @ObservedObject var fixture:AccountsFixture
    @Environment(\.dismiss) var dismiss
    var body:some View {
        CodexAccountsLayout(close:{dismiss()}) {
            if ProcessInfo.processInfo.environment["AUTOAPPROVE_LOGIN_LIFECYCLE_QA"] == "1" || FileManager.default.fileExists(atPath:fixture.root.appendingPathComponent("lifecycle-qa").path) {
                HStack {
                    Button("다른 뷰에서 합성 로그인") {try? fixture.accounts.beginNativeCodexLogin(.init(home:fixtureHomes[fixture.profile],executable:"codex"))}
                    Button("다른 뷰에서 합성 취소") {fixture.accounts.cancelNativeCodexLogin()}
                }
            }
            Text("이 Mac에서 실행 중인 Codex의 로그인과 세션 연결을 관리합니다.")
            CodexLoginSettings(accounts:fixture.accounts,targets:{try await fixture.targets()},transitionEnabled:true,transitionBusy:false,completed:{},reconnect:{try await fixture.reconnect($0)},
                setupHomes:{[fixtureHomes[fixture.profile]]},serverStatus:{_ in try await fixture.readServerStatus()},prepareServer:{_ in try await fixture.prepare()},inspectAccount:{try await fixture.inspectAccount($0)})
            CodexSessionAttachmentStatus(detail:"기존 세션 3개 연결 대기\n• server · ttys001: 작업 실행 중 · 완료 후 자동 연결\n• api · ttys002: 원본 셸 확인 필요\n• client · ttys003: Terminal·iTerm 화면 연결 필요 · Mac 연결 설정에서 연결해주세요")
            Divider()
            CodexAccountTransitionSettings(enabled:false,busy:false,states:[:],notice:nil,error:nil,setEnabled:{_ in},check:{},cancel:{_ in})
        }
    }
}
private struct FixtureApp:App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var fixture:AccountsFixture
    init() {
        let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["AUTOAPPROVE_ACCOUNTS_FIXTURE"] ?? Bundle.main.bundleURL.deletingLastPathComponent().path)
        _fixture=StateObject(wrappedValue:try! AccountsFixture(root:root))
    }
    var body:some Scene {
        Window("계정 UI · 합성 검사",id:"fixture") {FixtureControls(fixture:fixture)}.windowResizability(.contentSize)
            .commands {AppCommands(connectionsAvailable:true)}
        Window("계정·로그인",id:"accounts") {FixtureAccounts(fixture:fixture)}.windowResizability(.contentSize).commandsRemoved()
    }
}
@MainActor private struct Snapshot:View {
    let kind:String
    let home:String
    private var account:CodexAccountInspection? {
        guard kind.hasPrefix("account-") else{return nil}
        let comparison:CodexAccountInspection.Comparison=kind=="account-different" ? .different:kind=="account-signed-out" ? .signedOut:.same
        return .init(home:home,identity:.init(provider:kind=="account-signed-out" ? "로그인되지 않음":"ChatGPT",email:kind=="account-signed-out" ? nil:String(repeating:"long-account.",count:5)+"@example.test",plan:kind=="account-signed-out" ? nil:"pro",authenticated:kind != "account-signed-out"),comparison:comparison,connectedSessions:3,observedAt:Date(timeIntervalSince1970:1793721600))
    }
    var body:some View {
        let server:CodexManagedServerStatus? = kind.hasPrefix("server-") ? {
            switch kind {
            case "server-missing":return .init(phase:.missingCLI,detail:"이 Mac의 로그인 셸에서 Codex CLI를 찾지 못했습니다. Codex를 설치한 뒤 연결을 다시 확인해주세요.")
            case "server-unsupported":return .init(phase:.unsupported,version:"0.165.0",detail:"Codex 0.165.0은 관리형 서버 자동 전환 대상이 아닙니다. Codex 0.166.0 이상으로 업데이트해주세요.")
            case "server-ready-empty":return .init(phase:.running,version:"0.166.0",detail:"이 홈의 관리형 Codex 서버가 실행 중입니다.",autoStartEnabled:true)
            case "server-disabled":return .init(phase:.running,version:"0.166.0",detail:"이 홈의 관리형 Codex 서버가 실행 중입니다.",autoStartEnabled:false)
            case "server-unavailable":return .init(phase:.unavailable,version:"0.166.0",detail:"서버 소켓의 상태를 확인하지 못했습니다. 서버를 다시 시작하지 않았습니다. 연결을 다시 확인해주세요.")
            default:return .init(phase:.stopped,version:"0.166.0",detail:"이 홈의 관리형 Codex 서버가 아직 준비되지 않았습니다.")
            }
        }():nil
        let job:NativeCodexLoginState?=["waiting","succeeded","failed"].contains(kind)
            ? .init(id:"synthetic",home:home,phase:kind,url:kind=="waiting" ? "https://auth.openai.com/oauth/authorize?response_type=code&client_id=app_EMoamEEZ73f0CkXaXp7hrann&redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback&code_challenge="+String(repeating:"A",count:43)+"&code_challenge_method=S256&state=synthetic-preview":nil,message:kind=="succeeded" ? "이 Mac에서 로그인했습니다.":"로그인을 완료하지 못했습니다. 다시 로그인해주세요.") : nil
        CodexAccountsLayout(close:{}) {
            Text("이 Mac에서 실행 중인 Codex의 로그인과 세션 연결을 관리합니다.")
            CodexLoginContent(homes:[fixtureHomes[0],home],selected:.constant(home),loading:kind=="loading",job:job,disabled:kind=="transition" || kind=="server-preparing",error:kind=="failed" ? "실행 중인 Codex 연결을 확인하지 못했습니다. 연결을 다시 확인하거나 선택한 홈으로 로그인할 수 있습니다.":nil,transitionEnabled:true,begin:{},cancel:{},open:{_ in},reconnect:{},canReconnect:server?.phase == .running || (!["empty","failed"].contains(kind) && server==nil),connectedCount:server == nil && !["empty","failed"].contains(kind) ? 3:0,refreshTargets:{},serverStatus:server,preparingServer:kind=="server-preparing",prepareServer:{},checkingServer:kind=="server-checking",inspection:account,inspectionError:kind=="account-error" ? "계정 확인을 완료하지 못했습니다. 마지막 확인 계정은 유지합니다. 잠시 뒤 다시 확인해주세요.":nil,checkingAccount:kind=="account-pending",inspectionStale:["account-error","account-pending"].contains(kind),inspectAccount:{})
            Divider()
            if kind.hasPrefix("server-") {CodexSessionAttachmentStatus(detail:"기존 세션 3개 연결 대기\n• server · ttys001: 작업 실행 중 · 완료 후 자동 연결\n• api · ttys002: 원본 셸 확인 필요\n• client · ttys003: Terminal·iTerm 화면 연결 필요 · Mac 연결 설정에서 연결해주세요")}
            CodexAccountTransitionSettings(enabled:kind=="transition",busy:kind=="transition",states:kind=="transition-complete" ? ["synthetic":{var state=CodexAccountTransitionState();state.phase = .complete;state.detail="새 로그인으로 서버 전환 · 기존 창 1개 재연결을 확인했습니다.";state.verified=1;return state}()]:[:],notice:kind=="empty" ? "관리형 Codex 서버 연결을 아직 확인하지 못했습니다. 실행 중인 Codex를 유지하고 연결을 다시 확인해주세요.":nil,error:nil,setEnabled:{_ in},check:{},cancel:{_ in})
        }
    }
}
@main private enum AccountsPreview {
    @MainActor static func main() throws {
        let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["AUTOAPPROVE_ACCOUNTS_FIXTURE"] ?? Bundle.main.bundleURL.deletingLastPathComponent().path)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        if CommandLine.arguments.contains("--render") {
            _=NSApplication.shared
            let kinds=["connected","loading","empty","waiting","succeeded","failed","transition","server-stopped","server-missing","server-unsupported","server-ready-empty","server-unavailable","server-preparing","server-disabled","transition-complete","account-same","account-different","account-pending","account-error","account-signed-out","server-checking"]
            for kind in kinds {for dark in [false,true] {
                let host=NSHostingView(rootView:Snapshot(kind:kind,home:fixtureHomes[1]).background(Color(nsColor:.windowBackgroundColor)).environment(\.colorScheme,dark ? .dark:.light))
                host.frame=NSRect(x:0,y:0,width:600,height:660);host.appearance=NSAppearance(named:dark ? .darkAqua:.aqua)
                let window=NSWindow(contentRect:host.frame,styleMask:.borderless,backing:.buffered,defer:false);window.contentView=host
                host.layoutSubtreeIfNeeded();host.displayIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.05))
                let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds)!;host.cacheDisplay(in:host.bounds,to:bitmap)
                try bitmap.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent("\(kind)-\(dark ? "dark":"light").png"))
            }}
            print("Rendered \(kinds.count*2) production account-layout states at 600×660")
        } else {FixtureApp.main()}
    }
}
