import SwiftUI
import AppKit
import AutoApproveCore

@main struct SessionProfilesRender {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        let store=TerminalProfileStore(directory:root.appendingPathComponent("render-data"))
        var entries:[TerminalProfileEntry]=[]
        for i in 0..<24 {
            let agent=i%2==0 ? "codex":"claude"
            let conversation=i<2 ? "":String(format:"00000000-0000-4000-8000-%012d",i+1)
            var entry=TerminalProfileEntry(title:"긴 프로젝트 작업 \(i+1) · Codex와 Claude 대화 복원",agent:agent,cwd:"/fixture/여러 프로젝트/긴 작업 폴더 이름/프로젝트-\(i)",conversationID:conversation)
            if i==0 {entry.providerHome="/fixture/CLI 설정을 따로 보관하는 긴 폴더 이름/.codex"}
            entry.terminalTab = .init(window:UUID(uuidString:String(format:"10000000-0000-4000-8000-%012d",i/8+1))!,windowOrder:i/8,tabOrder:i%8,selected:i%8==0,settingsName:i==0 ? "사용자 지정 긴 Terminal 설정 프로필 이름":"Pro")
            entries.append(entry)
        }
        let profile=try store.save(.init(name:"여러 창 작업 프로필 · 재부팅 뒤 이어가기",entries:entries))
        let controller=SessionProfilesController(store:store,capture:{[]},launch:{_,_ in "/dev/fixture-render"})
        await controller.reload();controller.selectedID=profile.id
        for (name,width,height) in [("minimum",700,480),("default",860,640),("wide",1100,800)] {
            for (theme,scheme) in [("light",ColorScheme.light),("dark",ColorScheme.dark)] {
                try await render(SessionProfilesWindow(controller:controller),name:name+"-"+theme,width:width,height:height,scheme:scheme,root:root)
            }
        }
        var legacy=TerminalSessionProfile(name:"기존 작업 프로필 · 창 정보가 없는 이전 프로필",entries:Array(entries.prefix(2)).map {value in var entry=value;entry.terminalTab=nil;return entry})
        legacy.schema=1;_ = try store.save(legacy);await controller.reload();controller.selectedID=legacy.id
        try await render(SessionProfilesWindow(controller:controller),name:"legacy-light",width:700,height:480,scheme:.light,root:root)
        controller.selectedID=profile.id
        controller.error="프로필 파일을 읽지 못했습니다. 파일 형식을 확인한 뒤 다시 불러와주세요. "+String(repeating:"긴 오류 안내. ",count:16)
        try await render(SessionProfilesWindow(controller:controller),name:"error-light",width:700,height:480,scheme:.light,root:root)
        let empty=SessionProfilesController(store:.init(directory:root.appendingPathComponent("empty-data")),capture:{[]},launch:{_,_ in "/dev/fixture-render"})
        await empty.reload()
        try await render(SessionProfilesWindow(controller:empty),name:"empty-light",width:700,height:480,scheme:.light,root:root)
        var missing=entries[1];missing.conversationID=""
        let draft=SessionProfileDraft(profileID:UUID(),name:"대화 ID 없이 폴더에서 CLI 열기",candidates:[.init(id:"known",entry:entries[0]),.init(id:"choose",entry:missing,conversations:[.init(id:"00000000-0000-4000-8000-000000000002",title:"선택할 기존 대화")],detail:"대화 ID는 선택 사항입니다. 비워 두면 새 CLI를 엽니다.")])
        for scheme in [ColorScheme.light,.dark] {
            try await render(SessionProfileEditor(draft:draft,save:{_ in},cancel:{}),name:scheme == .dark ? "editor-dark":"editor-light",width:700,height:620,scheme:scheme,root:root)
        }
        var invalid=draft;invalid.candidates[0].entry.conversationID="bad-id"
        try await render(SessionProfileEditor(draft:invalid,save:{_ in},cancel:{}),name:"editor-invalid-light",width:700,height:620,scheme:.light,root:root)
        print("PASS native profile views: 700×480 / 860×640 / 1100×800 light/dark, empty, long error and optional/invalid conversation editor; synthetic data only")
    }
    @MainActor static func render<V:View>(_ view:V,name:String,width:Int,height:Int,scheme:ColorScheme,root:URL) async throws {
        let host=NSHostingView(rootView:view.frame(width:CGFloat(width),height:CGFloat(height)).background(Color(nsColor:.windowBackgroundColor)).environment(\.colorScheme,scheme))
        host.frame=NSRect(x:0,y:0,width:width,height:height);host.appearance=NSAppearance(named:scheme == .dark ? .darkAqua:.aqua)
        let window=NSWindow(contentRect:host.frame,styleMask:[.borderless],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=host
        try await Task.sleep(for:.milliseconds(120));host.layoutSubtreeIfNeeded();host.displayIfNeeded()
        guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else {throw AppError.message("Native profile render missing")}
        host.cacheDisplay(in:host.bounds,to:bitmap)
        guard let png=bitmap.representation(using:.png,properties:[:]) else {throw AppError.message("Native profile PNG missing")}
        try png.write(to:root.appendingPathComponent(name+".png"));window.close()
    }
}
