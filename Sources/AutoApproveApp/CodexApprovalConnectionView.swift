import SwiftUI
import AutoApproveCore

struct CodexApprovalConnectionView: View {
    let session: AgentSession
    let engine: ApprovalEngine
    @State private var choices: [CodexQueueConversation] = []
    @State private var selection = ""
    @State private var loading = false
    @State private var error: String?
    @State private var subagents: [CodexSubagentRow] = []
    @State private var loaded = false
    @State private var showConnection = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("서브에이전트").font(.headline)
                if loaded { Text("\(subagents.count)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("새로고침") { refresh() }.disabled(loading)
            }
            if loading && !loaded { ProgressView("서브에이전트 확인 중…").controlSize(.small) }
            if loaded && subagents.isEmpty {
                Text("현재 실행 중인 서브에이전트가 없습니다.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(subagents) { child in
                VStack(alignment: .leading, spacing: 3) {
                    Text(child.title).font(.callout.weight(.medium)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(child.status).font(.caption).foregroundStyle(.secondary)
                    Text(child.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button { showConnection.toggle() } label: {
                Label("대화 연결 확인", systemImage: showConnection ? "chevron.down" : "chevron.right")
            }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            if showConnection {
                VStack(alignment: .leading, spacing: 8) {
                    if let binding = session.codexApprovalBinding {
                        Text(binding.title).font(.caption).fixedSize(horizontal: false, vertical: true)
                        Text(binding.threadID).font(.caption.monospaced()).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(binding.status).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("현재 세션의 대화가 다르게 연결된 경우에만 변경하세요.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !choices.isEmpty {
                        Picker("이 세션의 대화", selection: $selection) {
                            Text("대화를 선택하세요").tag("")
                            ForEach(choices, id: \.id) { choice in Text(choice.title + " · " + choice.id).tag(choice.id) }
                        }
                        Button("선택한 대화로 변경") {
                            perform {
                                try await engine.connectCodexApprovals(sessionID: session.id, threadID: selection)
                                subagents = []; loaded = false
                                subagents = try await engine.codexApprovalSubagents(sessionID: session.id); loaded = true
                                showConnection = false
                            }
                        }.disabled(loading || selection.isEmpty)
                    }
                    Button("다른 대화 선택") {
                        perform { choices = try await engine.codexApprovalConversations(sessionID: session.id); selection = "" }
                    }.disabled(loading)
                }.padding(.top, 6)
            }
        }
        .task(id: session.id) { await load() }
    }
    private func refresh() { Task { await load() } }
    @MainActor private func load() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            try await engine.connectCurrentCodexApprovals(sessionID: session.id)
            subagents = try await engine.codexApprovalSubagents(sessionID: session.id)
            loaded = true
        } catch { self.error = error.localizedDescription }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        loading = true; error = nil
        Task { @MainActor in
            defer { loading = false }
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
}
