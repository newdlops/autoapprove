import AppKit
import SwiftUI
import AutoApproveCore

@MainActor final class GoalPreviewModel:ObservableObject {
    @Published var mode="정상"
    @Published var writes=0
    @Published var epoch=0
    var value=CodexSubagentGoal(rootThreadID:"parent",threadID:"child",parentThreadID:"parent",
        goal:CodexGoal(threadId:"child",objective:"계정 그룹 이동 후 기존 대화와 Goal의 누적 사용량이 보존되는지 확인합니다.",status:.active,createdAt:1,updatedAt:1,tokensUsed:12345,timeUsedSeconds:245,tokenBudget:100000,instanceID:"goal"),executionState:"active",turnID:"turn")
    func select(_ mode:String) {
        self.mode=mode;epoch+=1
        value.goal=CodexGoal(threadId:"child",objective:mode=="긴 목표" ? String(repeating:"서브에이전트가 기존 대화와 목표의 정보를 그대로 보존하는지 확인합니다. ",count:30):"계정 그룹 이동 후 기존 대화와 Goal의 누적 사용량이 보존되는지 확인합니다.",status:.active,createdAt:1,updatedAt:1,tokensUsed:12345,timeUsedSeconds:245,tokenBudget:100000,instanceID:"goal")
        value.executionState="active";value.turnID="turn"
        if mode=="Goal 없음" {value.goal=nil}
    }
    func read() async throws ->CodexSubagentGoal {
        try await Task.sleep(for:.milliseconds(600))
        if mode=="미지원" {throw AppError.message("이 연결 서버는 서브에이전트 Goal 관리를 지원하지 않습니다. 지원하는 관리형 서버 연결이 필요합니다.")}
        return value
    }
    func change(_ expected:CodexSubagentGoal,_ action:CodexSubagentGoalAction,_ request:UUID) async throws ->CodexSubagentGoalReceipt {
        writes+=1;try await Task.sleep(for:.milliseconds(1000))
        value.goal?.status=action == .resume ? .active:.paused
        value.executionState=action == .pause || action == .wait ? "idle":"active"
        value.turnID=action == .pause || action == .wait ? nil:"resumed"
        if mode=="응답 유실" {return .init(requestID:request,binding:"preview",phase:.unknown,detail:"요청 결과를 확인하지 못했습니다. 자동으로 다시 보내지 않습니다. 현재 상태를 새로 확인해주세요.")}
        let detail:String
        switch action {case .pause:detail="Goal과 현재 작업을 일시정지했습니다.";case .resume:detail="Goal을 재개했습니다.";case .wait:detail="현재 작업 종료를 확인했습니다."}
        return .init(requestID:request,binding:"preview",phase:.confirmed,result:value,detail:detail)
    }
}

struct GoalPreview:View {
    @StateObject private var model=GoalPreviewModel()
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                Text("서브에이전트").font(.headline)
                Text("/root/account_migration_validation").font(.callout.weight(.medium)).textSelection(.enabled)
                Text("작업 중 · 합성 UI 검사").font(.caption).foregroundStyle(.secondary)
                CodexSubagentGoalView(read:{try await model.read()},change:{try await model.change($0,$1,$2)}).id(model.epoch)
                Divider()
                Text("테스트 상태 · 실제 서버 연결 없음").font(.caption).foregroundStyle(.secondary)
                Picker("검사 상태",selection:Binding(get:{model.mode},set:{model.select($0)})) {
                    ForEach(["정상","미지원","응답 유실","Goal 없음","긴 목표"],id:\.self){Text($0)}
                }
                Text("변경 요청 \(model.writes)회").font(.caption)
                Button("밝은 화면"){NSApp.appearance=NSAppearance(named:.aqua)}
                Button("어두운 화면"){NSApp.appearance=NSAppearance(named:.darkAqua)}
            }.padding(24).frame(maxWidth:.infinity,alignment:.leading)
        }
    }
}
@main struct GoalPreviewApp {
    @MainActor static func main() {
        let app=NSApplication.shared;app.setActivationPolicy(.regular)
        let window=NSWindow(contentRect:NSRect(x:80,y:100,width:600,height:660),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title="AutoApprove · 자식 Goal 검사";window.minSize=NSSize(width:350,height:500)
        window.contentView=NSHostingView(rootView:GoalPreview());window.makeKeyAndOrderFront(nil);app.activate(ignoringOtherApps:true);app.run()
    }
}
