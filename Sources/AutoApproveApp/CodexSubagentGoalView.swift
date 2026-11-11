import SwiftUI
import AutoApproveCore

struct CodexSubagentGoalView:View {
    let read:@MainActor () async throws ->CodexSubagentGoal
    let change:@MainActor (CodexSubagentGoal,CodexSubagentGoalAction,UUID) async throws ->CodexSubagentGoalReceipt
    @State private var expanded=false
    @State private var snapshot:CodexSubagentGoal?
    @State private var busy=false
    @State private var fresh=false
    @State private var error:String?
    @State private var notice:String?
    @State private var showFullObjective=false

    var body:some View {
        DisclosureGroup("Goal 관리",isExpanded:$expanded) {
            VStack(alignment:.leading,spacing:8) {
                if let value=snapshot,let goal=value.goal {
                    Text(goal.objective).font(.callout).textSelection(.enabled)
                        .lineLimit(showFullObjective ? nil:6)
                    if goal.objective.count>120 || goal.objective.filter({$0=="\n"}).count>3 {
                        Button(showFullObjective ? "목표 접기":"목표 전체 보기") {showFullObjective.toggle()}
                    }
                    if !fresh && !busy {Text("이전 조회 결과 · 현재 상태를 다시 확인해주세요.").font(.caption).foregroundStyle(.secondary)}
                    Text(status(goal.status)).font(.callout.weight(.medium))
                    Text("사용 \(goal.tokensUsed.formatted()) 토큰"+(goal.tokenBudget.map{" / 예산 \($0.formatted()) 토큰"} ?? "")+" · \(goal.timeUsedSeconds.formatted())초")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    if goal.status == .paused && value.executionState != "idle" {
                        Text("Goal은 대기 중입니다. 현재 작업의 종료는 아직 확인되지 않았습니다.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                    if goal.status == .active || goal.status == .paused {
                        HStack {
                            Button(goal.status == .active ? "Goal 일시정지":"Goal 재개") {act(value,goal.status == .active ? .pause:.resume)}
                                .disabled(busy || !fresh)
                            if busy {ProgressView().controlSize(.small).accessibilityLabel("Goal 처리 중")}
                        }
                    } else {
                        Text("이 상태의 Goal은 원래 Codex에서 확인해주세요.").font(.caption).foregroundStyle(.secondary)
                    }
                } else if snapshot != nil {
                    Text("설정된 Goal이 없습니다.").font(.callout).foregroundStyle(.secondary)
                }
                if busy && snapshot == nil {ProgressView("Goal 확인 중…").controlSize(.small)}
                if let error {Label(error,systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true)}
                if let notice {Text(notice).font(.caption).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)}
                Button("현재 Goal 다시 확인") {Task {await load()}}.disabled(busy)
                Text("일시정지는 Goal의 자동 진행을 멈춥니다. 확인한 현재 작업도 중단하며, 목표·예산·누적 사용량은 유지합니다.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }.padding(.top,6).frame(maxWidth:.infinity,alignment:.leading)
        }.font(.caption)
        .task(id:expanded) {
            guard expanded else {return}
            await load()
            while !Task.isCancelled {
                do {try await Task.sleep(for:.seconds(10))} catch {return}
                await load()
            }
        }
    }
    private func status(_ status:CodexGoal.Status)->String {
        switch status {case .active:return "진행 중";case .paused:return "일시정지";case .blocked:return "진행 불가";case .usageLimited:return "사용량 제한";case .budgetLimited:return "예산 한도 도달";case .complete:return "완료"}
    }
    @MainActor private func load() async {
        guard !busy else {return};busy=true;fresh=false;defer{busy=false}
        do {let value=try await read();try Task.checkCancellation();snapshot=value;fresh=true;error=nil}
        catch is CancellationError {} catch {self.error=error.localizedDescription}
    }
    private func act(_ value:CodexSubagentGoal,_ action:CodexSubagentGoalAction) {
        guard fresh,!busy else {return};busy=true;fresh=false;error=nil;notice=nil
        let request=UUID()
        Task { @MainActor in
            defer{busy=false}
            do {
                let receipt=try await change(value,action,request)
                if receipt.phase == .confirmed,let result=receipt.result {snapshot=result;fresh=true;notice=receipt.detail}
                else {error=receipt.detail}
            } catch {self.error=error.localizedDescription;notice="요청을 자동으로 다시 보내지 않습니다. 현재 Goal을 다시 확인해주세요."}
        }
    }
}
