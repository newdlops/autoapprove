import SwiftUI
import AppKit
import AutoApproveCore

@main struct ScreenControlSettingsPreview {
    @MainActor static func main() throws {
        _=NSApplication.shared
        let directory=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        for state in ["permission-needed","allowed","busy","error"] {
            for (theme,scheme) in [("light",ColorScheme.light),("dark",ColorScheme.dark)] {
                for width in [480,600] {
                    let allowed=state=="allowed",busy=state=="busy"
                    let view=VStack(alignment:.leading,spacing:12) {
                        Label("터미널 중계·화면 공유",systemImage:"keyboard").font(.headline)
                        TerminalSharingSettings(screenAllowed:allowed,inputStatus:allowed ? .available:.requiresApproval,inputBusy:busy,
                            inputError:state=="error" ? "합성 연결 오류 · "+String(repeating:"현재 Mac의 허용 설정과 연결 상태를 확인해주세요. ",count:3):nil,
                            controlAllowed:allowed,screenAction:{},inputAction:{},controlAction:{}).font(.callout).foregroundStyle(.secondary)
                    }.padding(24).frame(width:CGFloat(width),height:520,alignment:.topLeading)
                        .background(Color(nsColor:.windowBackgroundColor)).environment(\.colorScheme,scheme)
                    let host=NSHostingView(rootView:view);host.frame=NSRect(x:0,y:0,width:width,height:520)
                    host.appearance=NSAppearance(named:scheme == .dark ? .darkAqua:.aqua)
                    let window=NSWindow(contentRect:host.frame,styleMask:[.borderless],backing:.buffered,defer:false)
                    window.contentView=host;host.layoutSubtreeIfNeeded();host.displayIfNeeded()
                    guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else {throw AppError.message("Settings preview bitmap unavailable")}
                    host.cacheDisplay(in:host.bounds,to:bitmap)
                    guard let png=bitmap.representation(using:.png,properties:[:]) else {throw AppError.message("Settings preview PNG unavailable")}
                    try png.write(to:directory.appendingPathComponent("\(state)-\(theme)-\(width).png"))
                }
            }
        }
        print("Rendered 16 inert screen-control settings states, light/dark at 480/600pt; no OS permission or desktop input requested")
    }
}
