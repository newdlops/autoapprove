import SwiftUI
import AutoApproveCore

/// An explicit binding is necessary for daemon-backed CLIs: their open files
/// identify the server, but cannot identify which root conversation is selected.
struct CodexApprovalConnectionView: View {
    let session: AgentSession
    let engine: ApprovalEngine
    @State private var choices: [CodexQueueConversation] = []
    @State private var selection = ""
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("서브에이전트 승인 연결").font(.headline)
            if let binding = session.codexApprovalBinding {
                Text(binding.title).font(.callout).fixedSize(horizontal: false, vertical: true)
                Text(binding.threadID).font(.caption.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(binding.status).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("연결 해제") { perform { try await engine.connectCodexApprovals(sessionID: session.id, threadID: nil) } }
                    .disabled(loading)
            } else {
                Text("이 터미널의 부모 대화를 선택하면, 열지 않은 서브에이전트의 명령·파일 변경·도구 사용 권한도 처리합니다. 자동 승인 스위치와 전체 일시정지를 따릅니다.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Codex /status의 대화 ID를 확인해 선택하세요.")
                    .font(.caption).foregroundStyle(.secondary)
                if !choices.isEmpty {
                    Picker("부모 대화", selection: $selection) {
                        Text("대화를 선택하세요").tag("")
                        ForEach(choices, id: \.id) { choice in
                            Text(choice.title + " · " + choice.id).tag(choice.id)
                        }
                    }.frame(maxWidth: .infinity)
                    Button("선택한 부모 대화 연결") {
                        perform { try await engine.connectCodexApprovals(sessionID: session.id, threadID: selection) }
                    }.disabled(loading || selection.isEmpty)
                } else if loaded {
                    Text("이 프로젝트에서 연결할 수 있는 부모 대화가 없습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(loaded ? "대화 목록 새로고침" : "부모 대화 찾기") {
                    perform {
                        choices = try await engine.codexApprovalConversations(sessionID: session.id)
                        selection = ""; loaded = true
                    }
                }.disabled(loading)
            }
            if loading { ProgressView("연결 확인 중…").controlSize(.small) }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        loading = true; error = nil
        Task { @MainActor in
            defer { loading = false }
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
}
