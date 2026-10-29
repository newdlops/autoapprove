import SwiftUI
import AppKit
import AutoApproveCore
@main struct PermissionRender {
    @MainActor static func main() async throws {
        _ = NSApplication.shared;let root=URL(fileURLWithPath:CommandLine.arguments[1])
        for state in ["manual","registered","waiting","submitted","uncertain","unavailable","paused"] {
            for (theme,scheme) in [("light",ColorScheme.light),("dark",ColorScheme.dark)] {
                var session=ProcessDiscovery.sessions(ProcessDiscovery.parse("101901 1 ttys901 101901 101901 Wed Oct 28 22:00:00 2026 /fixture/codex"))[0]
                session.terminal = .terminal;session.automatic=true
                let target=OSPermissionTarget(name:"긴 컴퓨터 유즈 테스트 앱 이름 한글🙂",bundleID:"local.qa",path:"/fixture/아주 긴 프로젝트 폴더/컴퓨터 유즈 테스트 앱.app",requirement:"Synthetic stable identity",pid:123,started:"same")
                if state != "manual" {session.osPermissionPolicy = .init(allowed:[.camera,.accessibility],targets:[target])}
                var requests:[OSPermissionRequest]=[]
                if ["waiting","submitted","uncertain","paused"].contains(state) {
                    var request=OSPermissionRequest(kind:.camera,requester:target,ownerPID:1,ownerStarted:"same",ownerBundleID:"com.apple.UserNotificationCenter",windowToken:"one",content:"합성 OS 요청 · 실제 권한을 요청하지 않습니다.",action:.allow,actionToken:"allow")
                    if state != "waiting" {request.sessionID=session.id}
                    request.phase=state=="submitted" ? .submitted:state=="uncertain" ? .uncertain:.waiting
                    request.detail=state=="uncertain" ? "입력 결과를 확인하지 못해 자동으로 다시 누르지 않습니다. 원래 Mac에서 권한창과 앱 동작을 확인해주세요. "+String(repeating:"긴 상태 안내. ",count:6):"이 세션의 정책으로 원래 OS 요청을 처리합니다."
                    requests=[request]
                }
                let status=OSPermissionMonitorStatus(available:state != "unavailable",detail:state=="unavailable" ? "Mac의 손쉬운 사용에서 AutoApprove를 허용하면 OS 권한창을 확인할 수 있습니다.":"OS 권한은 등록한 앱과 이 세션에서 허용한 종류에만 적용합니다.",requests:requests)
                let size=NSSize(width:state=="registered" ? 860:420,height:720)
                let content=OSPermissionPolicyView(session:session,status:status,paused:state=="paused",setAllowed:{_ in},assign:{_,_,_ in},remove:{_ in},acknowledge:{_,_ in},initiallyExpanded:state != "manual")
                let host=NSHostingView(rootView:ScrollView {content.padding(20)}.frame(width:size.width,height:size.height,alignment:.topLeading).background(Color(nsColor:.windowBackgroundColor)).environment(\.colorScheme,scheme))
                host.frame=NSRect(origin:.zero,size:size);host.appearance=NSAppearance(named:scheme == .dark ? .darkAqua:.aqua)
                let window=NSWindow(contentRect:host.frame,styleMask:[.borderless],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=host
                try await Task.sleep(for:.milliseconds(120));host.layoutSubtreeIfNeeded()
                guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else {throw AppError.message("Missing native permission image")}
                host.cacheDisplay(in:host.bounds,to:bitmap);try bitmap.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent(state+"-"+theme+".png"));window.close()
            }
        }
        print("PASS: production native permission policy, seven states × light/dark at 420/860×720; no OS input")
    }
}
