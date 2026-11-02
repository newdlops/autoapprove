import SwiftUI
import AppKit
import AutoApproveCore

@MainActor private struct NativeLoginPreview: View {
    let accounts:AgentAccounts
    let root:URL
    @State private var completed=0
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {Text("Codex 로그인 · 합성 검사").font(.headline);Spacer();Text("완료 \(completed)회").font(.caption)}
            HStack {
                Button("합성 로그인 완료") {try? Data().write(to:root.appendingPathComponent("signed-codex"))}
                Button("합성 인증 초기화") {try? FileManager.default.removeItem(at:root.appendingPathComponent("signed-codex"))}
            }
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    CodexLoginSettings(accounts:accounts,targets:{[.init(home:"/fixture/개발 계정/"+String(repeating:"long-repository/",count:8),executable:"/fixture/codex")]},transitionEnabled:true,transitionBusy:false,completed:{completed+=1})
                    Divider()
                    CodexAccountTransitionSettings(enabled:false,busy:false,states:[:],notice:nil,error:nil,setEnabled:{_ in},check:{},cancel:{_ in})
                }
            }
        }.padding(24).font(.callout).foregroundStyle(.secondary).frame(width:600,height:660)
    }
}
@main struct CodexLoginPreviewApp {
    @MainActor static func main() throws {
        _=NSApplication.shared;NSApp.setActivationPolicy(.regular)
        let root=URL(fileURLWithPath:CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory()+"aa-native-login-preview");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let phases=["starting","waiting","verifying","succeeded","failed","expired","cancelled"]
        for phase in phases {for dark in [false,true] {
            let oauth="https://auth.openai.com/oauth/authorize?response_type=code&client_id=app_EMoamEEZ73f0CkXaXp7hrann&redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback&code_challenge="+String(repeating:"A",count:43)+"&code_challenge_method=S256&state=synthetic-private-state-12345"
            let job=NativeCodexLoginState(id:"synthetic",home:"/fixture/개발 계정/"+String(repeating:"long-repository/",count:8),phase:phase,url:phase=="waiting" ? oauth:nil,message:phase=="succeeded" ? "이 Mac에서 로그인했습니다.":"로그인 상태를 확인해주세요. 다시 로그인할 수 있습니다.")
            let host=NSHostingView(rootView:ScrollView {
                CodexLoginContent(homes:["/fixture/default",job.home],selected:.constant(job.home),loading:false,job:job,disabled:false,error:phase=="failed" ? "연결이 종료되었습니다. 다시 로그인해주세요.":nil,transitionEnabled:false,begin:{},cancel:{},open:{_ in}).padding(24)
            }.font(.callout).foregroundStyle(.secondary).frame(width:600,height:660).background(Color(nsColor:.windowBackgroundColor)).environment(\.colorScheme,dark ? .dark:.light))
            host.frame=NSRect(x:0,y:0,width:600,height:660);host.appearance=NSAppearance(named:dark ? .darkAqua:.aqua)
            let w=NSWindow(contentRect:host.frame,styleMask:[.borderless],backing:.buffered,defer:false);w.contentView=host
            host.layoutSubtreeIfNeeded();host.displayIfNeeded()
            RunLoop.main.run(until:Date().addingTimeInterval(0.05))
            let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds)!;host.cacheDisplay(in:host.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent("\(phase)-\(dark ? "dark":"light").png"))
        }}
        if CommandLine.arguments.contains("--interactive") || CommandLine.arguments.count == 1 {
            let services=try AgentAccountFixture.services(root,codexBrowser:true)
            let accounts=AgentAccounts(services:services,codexServices:{_ in services})
            let w=NSWindow(contentRect:NSRect(x:100,y:100,width:600,height:660),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
            w.title="AutoApprove Codex 로그인 합성 검사";w.contentView=NSHostingView(rootView:NativeLoginPreview(accounts:accounts,root:root))
            w.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);NSApp.run();accounts.stop()
        }
        print("Rendered 14 native login states at 600×660")
    }
}
