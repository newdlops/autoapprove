import SwiftUI
import AppKit
import AutoApproveCore

private actor FixtureLaunches {
    var entries:[TerminalProfileEntry]=[]
    let file:URL
    init(file:URL) {self.file=file}
    func launch(_ entry:TerminalProfileEntry) throws -> String {
        _ = try entry.resumeCommand()
        entries.append(entry)
        let report:[String:Any]=["launched":entries.map(\.conversationID),"commands":try entries.map {try $0.resumeCommand()},"realTerminalLaunches":0]
        try JSONSerialization.data(withJSONObject:report,options:.prettyPrinted).write(to:file,options:.atomic)
        return "/dev/fixture-profiles-qa"
    }
}

@MainActor private final class ProfileHarness:ObservableObject {
    @Published var controller:SessionProfilesController
    init() {
        let root=URL(fileURLWithPath:Bundle.main.object(forInfoDictionaryKey:"ProfileQADataDirectory") as! String)
        let launches=FixtureLaunches(file:root.appendingPathComponent("launches.json"))
        let store=TerminalProfileStore(directory:root.appendingPathComponent("profiles"))
        func id(_ number:Int)->String {String(format:"00000000-0000-4000-8000-%012d",number)}
        func entry(_ number:Int,_ title:String,_ agent:String,_ leaf:String) throws -> TerminalProfileEntry {
            let cwd=root.appendingPathComponent(leaf)
            try FileManager.default.createDirectory(at:cwd,withIntermediateDirectories:true)
            return .init(title:title,agent:agent,cwd:cwd.path,conversationID:id(number))
        }
        do {
            if try store.list().profiles.isEmpty {
                _ = try store.save(.init(id:UUID(uuidString:id(1))!,name:"개발 작업",entries:[
                    try entry(100,"결제 API · Codex","codex","old-api"),try entry(101,"웹 관리자 · Claude Code","claude","old-web")]))
                _ = try store.save(.init(id:UUID(uuidString:id(2))!,name:"긴 이름의 프로필 · 여러 프로젝트와 재부팅 뒤 이어갈 작업",entries:try (0..<18).map {try entry(200+$0,"긴 작업 이름 \($0+1) · 한국어와 English 프로젝트의 작업 상태","codex","dense/project-\($0)/long-project-directory")}))
            }
            var ambiguous=try entry(400,"대화 선택이 필요한 창","codex","current-choice");ambiguous.conversationID=""
            let candidates=[TerminalProfileCandidate(id:"fixture-current-a",entry:try entry(300,"현재 API 창","codex","current-api")),
                            TerminalProfileCandidate(id:"fixture-current-b",entry:try entry(301,"현재 Claude 창","claude","current-web")),
                            TerminalProfileCandidate(id:"fixture-current-choice",entry:ambiguous,conversations:[.init(id:id(400),title:"도구 승인 안정화 작업"),.init(id:id(401),title:"프로필 복원 구현 작업")],detail:"공유 서버의 복원할 대화를 선택해주세요. 현재 창의 대화를 자동으로 추측하지 않습니다.")]
            controller=SessionProfilesController(store:store,capture:{
                try await Task.sleep(for:.milliseconds(250))
                return candidates + (await launches.entries).map {.init(id:$0.id.uuidString,entry:$0)}
            },launch:{try await launches.launch($0)})
        } catch {fatalError("Fixture setup failed: "+error.localizedDescription)}
    }
}

@main private struct ProfilesQAApplication:App {
    @StateObject private var harness=ProfileHarness()
    var body:some Scene {
        Window("세션 프로필 QA",id:"profile-qa") {
            SessionProfilesWindow(controller:harness.controller)
        }.defaultSize(width:860,height:640).windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing:.newItem) {}
            CommandMenu("QA 표시") {
                Button("기본 크기 860×640") {NSApp.keyWindow?.setContentSize(NSSize(width:860,height:640))}
                Button("최소 크기 700×480") {NSApp.keyWindow?.setContentSize(NSSize(width:700,height:480))}
                Button("넓은 크기 1100×800") {NSApp.keyWindow?.setContentSize(NSSize(width:1100,height:800))}
                Divider()
                Button("밝은 화면") {NSApp.appearance=NSAppearance(named:.aqua)}
                Button("어두운 화면") {NSApp.appearance=NSAppearance(named:.darkAqua)}
            }
        }
    }
}
