import SwiftUI
import AppKit
import AutoApproveCore
@main struct ProgressRender {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        for phase in [CodexProgressRecovery.Phase.watching,.interrupting,.waiting,.asking,.requested,.review] {
            for (theme,scheme) in [("light",ColorScheme.light),("dark",ColorScheme.dark)] {
                let detail:[CodexProgressRecovery.Phase:String]=[.watching:"30분 동안 진척 신호가 없으면 진행 상황을 확인합니다.",.interrupting:"진행 여부를 확인하기 위해 원래 Codex에 Esc를 한 번 보냅니다.",.waiting:"중단 후 빈 입력창을 확인하고 있습니다. 추가 Esc는 보내지 않습니다.",.asking:"진행 상황 보고 후 기존 작업을 이어가도록 요청합니다.",.requested:"진행 보고·이어가기 요청을 전달했습니다. 새 출력과 기록 갱신을 계속 확인합니다.",.review:"원래 Codex의 입력 대기를 확인하지 못했습니다. 자동 재입력 없이 원래 창 확인을 기다립니다. "+String(repeating:"긴 상태 안내. ",count:8)]
                let status=CodexProgressRecovery(phase:phase,lastProgressAt:Date().addingTimeInterval(-1800),checks:1,detail:detail[phase]!)
                let view=CodexProgressStatusView(progress:status,paused:false,automatic:true,working:true,check:{},cancel:{})
                let host=NSHostingView(rootView:view.padding(20).frame(width:420,height:320,alignment:.topLeading).background(Color(nsColor:.windowBackgroundColor)).environment(\.colorScheme,scheme))
                host.frame=NSRect(x:0,y:0,width:420,height:320);host.appearance=NSAppearance(named:scheme == .dark ? .darkAqua:.aqua)
                let window=NSWindow(contentRect:host.frame,styleMask:[.borderless],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=host
                try await Task.sleep(for:.milliseconds(120));host.layoutSubtreeIfNeeded()
                guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else {throw AppError.message("Missing native progress image")}
                host.cacheDisplay(in:host.bounds,to:bitmap)
                try bitmap.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent(phase.rawValue+"-"+theme+".png"));window.close()
            }
        }
        print("PASS: production native progress states light/dark at 420×320; synthetic data")
    }
}
