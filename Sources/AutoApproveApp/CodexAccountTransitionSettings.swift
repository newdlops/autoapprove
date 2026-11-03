import SwiftUI
import AutoApproveCore

struct CodexAccountTransitionSettings: View {
    let enabled: Bool
    let busy: Bool
    let states: [String: CodexAccountTransitionState]
    let notice: String?
    let error: String?
    let setEnabled: (Bool) -> Void
    let check: () -> Void
    let cancel: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("계정 변경 시 같은 대화로 자동 전환", isOn: Binding(get: { enabled }, set: setEnabled))
                .toggleStyle(.switch).disabled(busy)
                .help("다른 터미널에서 codex login으로 바꾼 계정을 확인합니다. 작업을 순차 중단하고 공통 서버를 전환하며, 창·탭은 유지합니다. 기본은 꺼짐입니다.")
            Text("로그인 변경을 감지하면 작업을 하나씩 중단합니다. 새 로그인으로 서버를 전환하고 기존 창·대화를 확인한 뒤, 전환으로 중단한 작업만 이어갑니다.")
                .fixedSize(horizontal: false, vertical: true)
            if !enabled, states.isEmpty {
                Label("꺼짐 · 자동으로 계정을 바꾸거나 작업을 중단하지 않습니다.", systemImage: "pause.circle")
                    .font(.caption)
            }
            ForEach(states.keys.sorted(), id: \.self) { home in
                if let state = states[home] {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Label {Text(title(state.phase)).foregroundStyle(.primary)} icon: {
                                Image(systemName:icon(state.phase)).foregroundStyle(color(state.phase))
                            }.font(.callout.weight(.semibold))
                            Spacer(minLength: 4)
                            if state.held, state.phase != .review { ProgressView().controlSize(.small).accessibilityLabel("계정 전환 진행 중") }
                        }
                        if state.held || state.phase == .complete {
                            HStack(spacing: 8) {
                                step("작업 중단", number: 0, state: state)
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                step("서버 전환", number: 1, state: state)
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                step("대화 연결", number: 2, state: state)
                            }.accessibilityElement(children: .combine)
                        }
                        Text(state.detail).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        if !state.threads.isEmpty {
                            Text("대화 \(state.threads.count)개 · 대기 전환 \(state.reservations.count)개" + (state.restartReserved ? " · 연결 확인 \(state.verified)/\(state.witnesses.count)개" : ""))
                                .font(.caption).monospacedDigit()
                        }
                        DisclosureGroup("서버 위치") {
                            Text(home).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }.font(.caption)
                        if state.canCancel {
                            Button(state.phase == .review ? "확인 후 자동 전환 중지" : state.phase == .resuming ? "나머지 이어가기 중지":"나머지 전환 중지") { cancel(home) }
                                .disabled(busy)
                                .help("추가 중단·전환을 멈춥니다. 이미 중단한 작업은 자동으로 재개하지 않습니다. 결과가 불명확한 명령은 반복하지 않습니다.")
                        }
                    }.padding(.vertical, 4)
                }
            }
            if let notice { Label(notice, systemImage: "info.circle").fixedSize(horizontal: false, vertical: true) }
            if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 8) {
                if states.values.contains(where:\.held) {
                    Button("전환 진행 확인") { check() }.disabled(busy)
                        .help("예약된 전환의 진행 상태를 확인하고 조건이 충족되면 계속합니다. 계정만 읽으려면 위의 현재 로그인 확인을 사용하세요.")
                }
                if busy { ProgressView().controlSize(.small); Text("전환 확인 중…").font(.caption) }
            }
            Text("전환으로 중단한 Goal은 기존 목표를 재개하고, 일반 작업은 같은 대화에 이어가기 요청을 한 번 보냅니다. 원래 대기 중이던 대화와 작성 중인 초안은 유지합니다. 대기 메시지가 남아 있으면 전환을 기다립니다.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            Text("공식 관리형 Codex 0.166.0 이상이 대상입니다. 대화 연결을 확인할 증거가 부족하면 ‘확인 필요’로 표시합니다.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func step(_ label: String, number: Int, state: CodexAccountTransitionState) -> some View {
        let current = state.phase == .complete ? 3 : state.restartReserved ? (state.phase == .restarting ? 1 : 2) : 0
        return Label(label, systemImage: current > number ? "checkmark.circle.fill" : current == number ? "circle.inset.filled" : "circle")
            .font(.caption).foregroundStyle(current >= number ? Color.accentColor : .secondary)
    }
    private func title(_ phase: CodexAccountTransitionState.Phase) -> String {
        switch phase {
        case .ready: return "로그인 변경 대기"
        case .stopping: return "작업 순차 중단"
        case .waiting: return "작업 대기 확인"
        case .restarting: return "공통 서버 전환"
        case .reconnecting: return "기존 대화 재연결 확인"
        case .resuming: return "중단 작업 이어가기"
        case .complete: return "연결된 세션 전환 완료"
        case .review: return "확인 필요"
        case .cancelled: return "자동 전환 중지됨"
        case .unsupported: return "지원 여부 확인 필요"
        }
    }
    private func icon(_ phase: CodexAccountTransitionState.Phase) -> String {
        switch phase {
        case .complete: return "checkmark.circle.fill"
        case .review, .unsupported: return "exclamationmark.circle"
        case .cancelled: return "pause.circle"
        default: return "arrow.triangle.2.circlepath"
        }
    }
    private func color(_ phase: CodexAccountTransitionState.Phase) -> Color {
        switch phase {
        case .complete: return .green
        case .review, .unsupported: return .orange
        default: return .primary
        }
    }
}
