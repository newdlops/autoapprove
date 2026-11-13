import SwiftUI
import AutoApproveCore

/// Group membership and the active terminal are intentionally separate: a
/// stored conversation may be offline or its live identity may be unknown.
@MainActor struct SessionGroupsWindow: View {
    @ObservedObject var engine: ApprovalEngine
    @State private var groups: [SessionGroup] = []
    @State private var live: [SessionGroupLiveSession] = []
    @State private var selectedID: UUID?
    @State private var name = ""
    @State private var loading = false
    @State private var error: String?
    @State private var notice: String?
    @State private var deleteConfirm = false
    init(engine: ApprovalEngine, initialSelection: UUID? = nil) {
        self.engine = engine
        _selectedID = State(initialValue: initialSelection)
    }
    private var store: SessionGroupStore { SessionGroupStore(directory: engine.paths.directory) }
    private var selected: SessionGroup? { groups.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            if let error {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
                    Spacer()
                    Button("닫기") { self.error = nil }
                }.font(.callout).padding(12)
                Divider()
            }
            HSplitView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("세션 그룹").font(.title2.weight(.semibold))
                        Spacer()
                        if loading { ProgressView().controlSize(.small).accessibilityLabel("세션 확인 중") }
                    }.padding(.horizontal, 16).padding(.top, 20)
                    Text("함께 작업할 Codex와 Claude Code 세션을 묶습니다.")
                        .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 16)
                    if groups.isEmpty {
                        Text("저장한 그룹이 없습니다").font(.headline).padding(16)
                        Spacer()
                    } else {
                        List(selection: $selectedID) {
                            ForEach(groups) { group in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(group.name).lineLimit(2).help(group.name)
                                    Text("세션 \(group.members.count)개").font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 5).tag(group.id)
                            }
                        }.listStyle(.inset)
                    }
                }.frame(minWidth: 210, idealWidth: 245, maxWidth: 300)
                Group {
                    if let group = selected { detail(group) }
                    else {
                        ContentUnavailableView {
                            Label("세션 그룹", systemImage: "person.2")
                        } description: {
                            Text("그룹을 선택하거나 새로 만들어 세션을 추가하세요.")
                        } actions: {
                            Button("새 그룹") { create() }.disabled(loading)
                        }
                    }
                }.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            }
            if let notice {
                Divider()
                Text(notice).font(.callout).foregroundStyle(.secondary).padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 700, minHeight: 480)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("새 그룹", systemImage: "plus") { create() }.disabled(loading)
                Button("새로고침", systemImage: "arrow.clockwise") { Task { await refresh() } }.disabled(loading)
                    .help("현재 세션과 저장된 구성원의 연결을 다시 확인합니다.")
            }
        }
        .task { await refresh() }
        .onChange(of: selectedID) { _, id in name = groups.first { $0.id == id }?.name ?? ""; notice = nil }
        .confirmationDialog("이 그룹을 삭제할까요?", isPresented: $deleteConfirm) {
            Button("그룹 삭제", role: .destructive) { deleteSelected() }
        } message: { Text("그룹만 삭제하며 원본 세션과 대화는 유지됩니다.") }
    }

    private func detail(_ group: SessionGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("그룹 이름").font(.headline)
                    HStack {
                        TextField("그룹 이름", text: $name).textFieldStyle(.roundedBorder)
                        Button("이름 저장") { rename(group) }.disabled(loading || name == group.name)
                    }
                }
                Menu {
                    Button("그룹 삭제", role: .destructive) { deleteConfirm = true }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("그룹 관리")
            }
            Text("같은 도구의 세션끼리 각 도구의 메시지 기능을 사용합니다. 다른 도구 사이의 전달은 지원하지 않습니다.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("에이전트는 AutoApprove MCP의 get_session_groups 도구로 구성원을 확인합니다. 공유 서버는 자신의 대화 ID를 지정해야 할 수 있습니다. 상태는 새로고침할 때 확인합니다.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("구성원 \(group.members.count)개").font(.headline)
                Spacer()
                Menu("세션 추가", systemImage: "plus") {
                    if live.isEmpty { Text(loading ? "확인 중…" : "추가할 실행 세션이 없습니다") }
                    ForEach(live) { candidate in
                        Button("\(candidate.session.agent.title) · \(candidate.session.displayedTerminalTitle) · \(candidate.session.project)") {
                            Task { await add(candidate, to: group) }
                        }.disabled(group.members.contains { SessionGroupMatching.match($0, in: live)?.id == candidate.id })
                    }
                }.disabled(loading)
            }
            if group.members.isEmpty {
                ContentUnavailableView("구성원이 없습니다", systemImage: "person.badge.plus", description: Text("세션 추가에서 현재 실행 중인 세션을 선택하세요."))
            } else {
                List(group.members) { member in
                    let match = SessionGroupMatching.match(member, in: live)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .top) {
                            Text(member.title.isEmpty ? member.agent.title : member.title).font(.body.weight(.medium)).lineLimit(3)
                            Spacer(minLength: 8)
                            Button("제거") { remove(member, from: group) }.disabled(loading)
                        }
                        Text("\(member.agent.title) · \(match == nil ? "연결 확인 필요" : "실행 중")")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(member.cwd).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                        Text(member.conversationID.isEmpty ? "대화 ID 확인 필요" : member.conversationID)
                            .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        if (member.conversationID.isEmpty || member.providerHome == nil), let match, match.conversationID != nil, match.providerHome != nil {
                            Button("현재 대화 연결") { Task { await bind(member, to: match, in: group) } }.disabled(loading)
                                .help("같은 실행 세션의 확인된 대화 ID를 그룹에 저장합니다.")
                        }
                        if match == nil {
                            Menu("실행 중인 세션에 연결…") {
                                let choices = live.filter { $0.session.agent == member.agent }
                                if choices.isEmpty { Text("같은 도구의 실행 세션이 없습니다") }
                                ForEach(choices) { candidate in
                                    Button("\(candidate.session.displayedTerminalTitle) · \(candidate.session.project)") {
                                        Task { await reconnect(member, to: candidate, in: group) }
                                    }
                                }
                            }.disabled(loading)
                                .help("선택한 실행 세션의 대화 ID가 저장된 ID와 일치할 때만 연결합니다. ID가 없는 항목은 선택한 대화로 연결합니다.")
                        }
                    }.padding(.vertical, 5)
                }.listStyle(.inset)
            }
        }.padding(20)
    }

    private func refresh() async {
        guard !loading else { return }; loading = true; defer { loading = false }
        do {
            let saved = try store.load()
            let sessions = try await engine.sessionGroupSessions()
            groups = saved; live = sessions; error = nil
            if let id = selectedID, !groups.contains(where: { $0.id == id }) { selectedID = nil }
            if let id = selectedID, name.isEmpty { name = groups.first { $0.id == id }?.name ?? "" }
            notice = "현재 세션과 저장된 그룹을 확인했습니다."
        } catch { self.error = error.localizedDescription }
    }
    private func persist(_ next: [SessionGroup], message: String) -> Bool {
        do { try store.save(next, expected: groups); groups = try store.load(); error = nil; notice = message; return true }
        catch { self.error = error.localizedDescription; return false }
    }
    private func create() {
        let group = SessionGroup(name: "새 그룹")
        if persist(groups + [group], message: "그룹을 만들었습니다.") { selectedID = group.id; name = group.name }
    }
    private func rename(_ group: SessionGroup) {
        var changed = group; changed.name = name
        if persist(groups.map { $0.id == group.id ? changed : $0 }, message: "그룹 이름을 저장했습니다.") { name = selected?.name ?? name }
    }
    private func add(_ candidate: SessionGroupLiveSession, to group: SessionGroup) async {
        guard !loading else { return }; loading = true; defer { loading = false }
        do {
            let current = try await engine.sessionGroupSessions(); live = current
            guard let fresh = current.first(where: { $0.id == candidate.id }),
                  fresh.session.cwd == candidate.session.cwd, fresh.session.agent == candidate.session.agent,
                  let latest = groups.first(where: { $0.id == group.id }) else {
                throw AppError.message("세션 또는 그룹이 변경되었습니다. 현재 목록을 다시 확인해주세요.")
            }
            guard !latest.members.contains(where: { SessionGroupMatching.match($0, in: current)?.id == fresh.id }) else { return }
            var changed = latest; changed.members.append(fresh.member)
            _ = persist(groups.map { $0.id == latest.id ? changed : $0 }, message: "세션을 그룹에 추가했습니다.")
        } catch { self.error = error.localizedDescription }
    }
    private func remove(_ member: SessionGroupMember, from group: SessionGroup) {
        var changed = group; changed.members.removeAll { $0.id == member.id }
        _ = persist(groups.map { $0.id == group.id ? changed : $0 }, message: "그룹에서 세션을 제거했습니다.")
    }
    private func bind(_ member: SessionGroupMember, to candidate: SessionGroupLiveSession, in group: SessionGroup) async {
        guard !loading else { return }; loading = true; defer { loading = false }
        do {
            let current = try await engine.sessionGroupSessions(); live = current
            guard let latest = groups.first(where: { $0.id == group.id }), latest.members.contains(member),
                  let fresh = SessionGroupMatching.match(member, in: current), fresh.id == candidate.id,
                  fresh.conversationID != nil, fresh.providerHome != nil,
                  fresh.conversationID == candidate.conversationID, fresh.providerHome == candidate.providerHome else {
                throw AppError.message("현재 대화 연결이 변경되었습니다. 새로고침 후 다시 확인해주세요.")
            }
            var updated = fresh.member; updated.id = member.id
            var changed = latest; changed.members = latest.members.map { $0.id == member.id ? updated : $0 }
            _ = persist(groups.map { $0.id == latest.id ? changed : $0 }, message: "현재 대화 연결을 저장했습니다.")
        } catch { self.error = error.localizedDescription }
    }
    private func reconnect(_ member: SessionGroupMember, to candidate: SessionGroupLiveSession, in group: SessionGroup) async {
        guard !loading else { return }; loading = true; defer { loading = false }
        do {
            let current = try await engine.sessionGroupSessions(); live = current
            guard let latest = groups.first(where: { $0.id == group.id }), latest.members.contains(member),
                  let fresh = current.first(where: { $0.id == candidate.id }), fresh.session.agent == member.agent,
                  let id = fresh.conversationID.flatMap(UUID.init(uuidString:)), let home = fresh.providerHome,
                  fresh.conversationID == candidate.conversationID, fresh.providerHome == candidate.providerHome else {
                throw AppError.message("선택한 실행 세션의 대화 ID와 설정 홈을 확인하지 못했습니다. 새로고침 후 다시 시도해주세요.")
            }
            if !member.conversationID.isEmpty {
                guard UUID(uuidString: member.conversationID) == id,
                      member.providerHome == nil || member.providerHome == home else {
                    throw AppError.message("선택한 세션은 저장된 대화와 다릅니다. 원래 대화를 선택해주세요.")
                }
            }
            var updated = fresh.member; updated.id = member.id
            var changed = latest; changed.members = latest.members.map { $0.id == member.id ? updated : $0 }
            _ = persist(groups.map { $0.id == latest.id ? changed : $0 }, message: "선택한 현재 대화에 연결했습니다.")
        } catch { self.error = error.localizedDescription }
    }
    private func deleteSelected() {
        guard let id = selectedID else { return }
        if persist(groups.filter { $0.id != id }, message: "그룹을 삭제했습니다.") { selectedID = nil }
    }
}
