import AppKit
import SwiftUI
import AutoApproveCore

@MainActor private struct AccountPanelPreview:View {
    @State private var shared=true
    @State private var action="아직 실행하지 않음"
    static func info(shared:Bool,long:Bool=false,existing:Bool=false) -> CodexSessionAccount {
        .init(sessionID:"owned-fixture",target:.init(home:"/fixture/account",executable:"/fixture/codex"),
            identity:.init(provider:"ChatGPT",email:long ? String(repeating:"long-account-",count:16)+"@example.test":"session@example.test",plan:"pro"),sharedSessions:shared ? 5:1,
            loginGroupName:existing ? nil:long ? String(repeating:"긴 로그인 그룹 ",count:7):(shared ? "개발 공통":"개인 작업"),serverPID:shared ? 42421:42422)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Toggle("공통 서버 합성 상태",isOn:$shared)
            CodexSessionAccountContent(account:Self.info(shared:shared),loading:false,error:nil,disabled:false,
                refresh:{action="계정 새로 확인"},login:{action=shared ? "공유 로그인 범위: 5개 세션":"개별 로그인 범위: 1개 세션"},reconnect:{action="현재 로그인 재연결 요청"},changeGroup:{action="로그인 그룹 변경 요청"})
            Divider();Text(action).accessibilityIdentifier("fixture-action");Spacer()
        }.padding(24).frame(width:500,height:400)
    }
}
@main struct SessionAccountPreviewApp {
    @MainActor static func main() throws {
        _=NSApplication.shared;NSApp.setActivationPolicy(.regular)
        let output=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        for mode in ["shared","individual","existing","long","loading","error","busy"] {for dark in [false,true] {for width in [350.0,600.0] {
            let info=mode=="loading" || mode=="error" ? nil:AccountPanelPreview.info(shared:mode != "individual",long:mode=="long",existing:mode=="existing")
            let root=CodexSessionAccountContent(account:info,loading:mode=="loading",error:mode=="error" ? "연결 서버를 확인하지 못했습니다. 현재 세션을 유지하고 계정을 다시 확인해주세요.":nil,disabled:mode=="busy",refresh:{},login:{},reconnect:{},changeGroup:{})
                .padding(16).frame(width:width,height:420,alignment:.topLeading).background(Color(nsColor:.windowBackgroundColor)).environment(\.colorScheme,dark ? .dark:.light)
            let view=NSHostingView(rootView:root);view.frame=NSRect(x:0,y:0,width:width,height:420);view.appearance=NSAppearance(named:dark ? .darkAqua:.aqua)
            let window=NSWindow(contentRect:view.frame,styleMask:[.borderless],backing:.buffered,defer:false);window.contentView=view
            view.layoutSubtreeIfNeeded();view.displayIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.05))
            let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds)!;view.cacheDisplay(in:view.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("\(mode)-\(dark ? "dark":"light")-\(Int(width)).png"))
        }}}
        print("Rendered 28 native account panel states; synthetic identities only")
        if CommandLine.arguments.contains("--interactive") {
            let window=NSWindow(contentRect:NSRect(x:100,y:100,width:500,height:400),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.title="AutoApprove 세션 계정 합성 검사";window.contentView=NSHostingView(rootView:AccountPanelPreview());window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);NSApp.run()
        }
    }
}
