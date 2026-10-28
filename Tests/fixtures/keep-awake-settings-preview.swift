import SwiftUI
import AppKit
import AutoApproveCore

@main struct KeepAwakeSettingsPreview {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let out=URL(fileURLWithPath:CommandLine.arguments[1])
        let cases:[(String,KeepAwakeStatus.Phase,Bool,Bool,Bool,String?)]=[
            ("holding",.holding,true,false,false,nil),("idle",.holding,true,false,false,nil),
            ("locked",.holding,true,true,false,nil),("off",.off,false,false,false,nil),
            ("busy",.checking,false,false,true,nil),("battery",.lowBattery,true,false,false,nil),
            ("hot",.hot,true,false,false,nil),("error",.failed,true,false,false,"설정 적용에 실패했습니다. 권한을 확인한 뒤 다시 시도해주세요. 긴 오류 내용 · "+String(repeating:"상태를 다시 확인해주세요. ",count:8))]
        for (name,phase,enabled,locked,busy,error) in cases {
            let detail:String
            switch phase {
            case .off: detail="잠자기·화면 유지가 꺼져 있습니다."
            case .checking: detail="잠자기 설정을 확인하고 있습니다."
            case .lowBattery: detail="배터리가 20% 이하라 잠자기·화면 유지를 해제했습니다. 충전되면 다시 유지합니다."
            case .hot: detail="Mac이 뜨거워 잠자기·화면 유지를 해제했습니다. 식으면 다시 유지합니다."
            case .failed: detail="잠자기 설정을 적용하지 못했습니다."
            default: detail=locked ? "앱이 켜진 동안 계속 작업 중 · 화면은 잠겨 있습니다.":"앱이 켜진 동안 잠자기·자동 화면 꺼짐을 방지하고 있습니다."
            }
            let status=KeepAwakeStatus(phase:phase,detail:detail,enabled:enabled,ruleFile:true,lidClosed:name=="locked",screenLocked:locked,idleDisplaySleepPrevented:phase == .holding)
            for (theme,scheme) in [("light",ColorScheme.light),("dark",ColorScheme.dark)] {
                let content=VStack(alignment:.leading,spacing:10) {
                    Label("앱이 켜진 동안 계속 작업",systemImage:"laptopcomputer").font(.headline)
                    Text(status.detail).foregroundStyle(.secondary)
                    KeepAwakeSettings(status:status,busy:busy,error:error,setEnabled:{_ in},removeRule:{},openLockSettings:{})
                }.font(.callout).padding(24).frame(width:600,alignment:.topLeading)
                let view=ScrollView {content}.frame(width:600,height:660).background(Color(nsColor:.windowBackgroundColor)).environment(\.colorScheme,scheme)
                let host=NSHostingView(rootView:view);host.frame=NSRect(x:0,y:0,width:600,height:660);host.appearance=NSAppearance(named:theme=="dark" ? .darkAqua:.aqua)
                let window=NSWindow(contentRect:host.frame,styleMask:[.borderless],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=host
                try await Task.sleep(for:.milliseconds(100));host.layoutSubtreeIfNeeded();host.displayIfNeeded()
                guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else {throw AppError.message("Native preview unavailable")};host.cacheDisplay(in:host.bounds,to:bitmap)
                guard let png=bitmap.representation(using:.png,properties:[:]) else {throw AppError.message("PNG unavailable")};try png.write(to:out.appendingPathComponent(name+"-"+theme+".png"));window.close()
            }
        }
        print("PASS native keep-awake control at 600×660: 8 states in light/dark; no power changes or inputs")
    }
}
