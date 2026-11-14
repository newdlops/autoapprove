import SwiftUI
import AutoApproveCore

/// Group membership and the active terminal are intentionally separate: a
/// stored conversation may be offline or its live identity may be unknown.
@MainActor struct SessionGroupsWindow: View {
    @ObservedObject var engine: ApprovalEngine
    @State private var groups: [SessionGroup] = []
    @State private var live: [SessionGroupLiveSession] = []
    @State private var assignments: [SessionGroupAssignment] = []
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
            Text(group.leaderMemberID == nil
                 ? "그룹장을 지정하면 구성원을 트리로 관리하고, 상위 세션이 하위 세션에 작업을 지시할 수 있습니다."
                 : "상위 세션은 AutoApprove MCP의 assign_group_task로 직속 구성원에게 작업을 지시합니다. 작업을 받은 구성원은 권한 확인에서 멈추지 않도록 자동 승인이 켜집니다. 작업자가 응답을 마치면 결과 요약이 지시한 세션의 터미널에 입력됩니다.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("에이전트는 get_session_groups와 get_group_status로 구성원과 작업 상태를 확인합니다. 공유 서버는 자신의 대화 ID를 지정해야 할 수 있습니다. 상태는 새로고침할 때 확인합니다.")
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
                List(group.treeOrder) { entry in
                    let member = entry.member
                    let match = SessionGroupMatching.match(member, in: live)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .top) {
                            if group.leaderMemberID == member.id {
                                Image(systemName: "crown").foregroundStyle(.orange).accessibilityLabel("그룹장")
                            }
                            Text(member.title.isEmpty ? member.agent.title : member.title).font(.body.weight(.medium)).lineLimit(3)
                            Spacer(minLength: 8)
                            roleMenu(member, in: group)
                            Button("제거") { remove(member, from: group) }.disabled(loading)
                        }
                        Text("\(member.agent.title) · \(match == nil ? "연결 확인 필요" : "실행 중") · \(roleText(member, in: group))")
                            .font(.caption).foregroundStyle(.secondary)
                        if let task = currentTask(member, in: group) {
                            Label(taskText(task), systemImage: task.question != nil ? "questionmark.bubble" : task.status == .working ? "hourglass" : "checkmark.circle")
                                .font(.caption).foregroundStyle(task.deliveryError == nil && task.question == nil ? Color.secondary : Color.orange)
                                .lineLimit(2).help(task.deliveryError ?? task.question?.text ?? task.task)
                        }
                        Text(member.cwd).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                        HStack(alignment: .top) {
                            Text(member.conversationID.isEmpty ? "대화 ID 확인 필요" : member.conversationID)
                                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            Spacer(minLength: 8)
                            Button("세션 ID 갱신") { Task { await refreshIdentity(member, in: group) } }
                                .fixedSize().disabled(loading)
                                .help("원래 터미널에 /status를 입력하고 화면에서 현재 세션 ID를 읽어 저장합니다. 입력창이 빈 대기 상태에서만 실행합니다.")
                        }
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
                    }.padding(.vertical, 5).padding(.leading, CGFloat(min(entry.depth, 6)) * 20)
                }.listStyle(.inset)
            }
        }.padding(20)
    }

    private func roleMenu(_ member: SessionGroupMember, in group: SessionGroup) -> some View {
        Menu {
            if group.leaderMemberID == member.id {
                Button("그룹장 해제") { clearLeader(in: group) }
            } else {
                Button("그룹장으로 지정") { makeLeader(member, in: group) }
                if group.leaderMemberID != nil {
                    Menu("상위 구성원") {
                        ForEach(group.parentCandidates(for: member.id)) { candidate in
                            Button {
                                setParent(candidate, for: member, in: group)
                            } label: {
                                if group.parentID(of: member.id) == candidate.id { Label(candidate.title, systemImage: "checkmark") }
                                else { Text(candidate.title) }
                            }
                        }
                    }
                }
            }
        } label: { Image(systemName: "point.3.connected.trianglepath.dotted") }
            .menuStyle(.borderlessButton).fixedSize().disabled(loading)
            .accessibilityLabel("역할과 상위 구성원").help("그룹장과 상위 구성원을 지정합니다.")
    }

    private func roleText(_ member: SessionGroupMember, in group: SessionGroup) -> String {
        if group.leaderMemberID == member.id { return "그룹장" }
        guard let parent = group.parentID(of: member.id),
              let title = group.members.first(where: { $0.id == parent })?.title else { return "그룹장 없음" }
        return "지시: " + (title.isEmpty ? "구성원" : title)
    }

    private func currentTask(_ member: SessionGroupMember, in group: SessionGroup) -> SessionGroupAssignment? {
        SessionGroupOrchestration(assignments: assignments).current(groupID: group.id, workerMemberID: member.id)
    }

    private func taskText(_ task: SessionGroupAssignment) -> String {
        switch task.status {
        case .working:
            guard let question = task.question else { return "작업 중 · " + task.task }
            return (question.reportedAt == nil ? "질문 보고 대기 · " : "지시한 세션의 답을 기다림 · ") + question.text
        case .completed: return task.deliveryError == nil ? "완료 · 보고 전달 대기" : "완료 · 보고 전달 재시도 중"
        case .reported: return "완료 · 보고 전달됨"
        case .superseded: return task.task
        }
    }

    private func makeLeader(_ member: SessionGroupMember, in group: SessionGroup) {
        _ = persist(groups.map { $0.id == group.id ? group.settingLeader(member.id) : $0 }, message: "그룹장을 지정했습니다.")
    }

    private func clearLeader(in group: SessionGroup) {
        var changed = group; changed.leaderMemberID = nil
        for index in changed.members.indices { changed.members[index].parentMemberID = nil }
        _ = persist(groups.map { $0.id == group.id ? changed : $0 }, message: "그룹장을 해제했습니다. 구성원은 다시 평면 목록이 됩니다.")
    }

    private func setParent(_ parent: SessionGroupMember, for member: SessionGroupMember, in group: SessionGroup) {
        _ = persist(groups.map { $0.id == group.id ? group.settingParent(parent.id, for: member.id) : $0 }, message: "상위 구성원을 변경했습니다.")
    }

    private func refreshIdentity(_ member: SessionGroupMember, in group: SessionGroup) async {
        guard !loading else { return }; loading = true; defer { loading = false }
        do {
            notice = "터미널에서 세션 ID를 조회하고 있습니다…"
            try await engine.refreshSessionGroupMemberID(groupID: group.id, memberID: member.id)
            groups = try store.load(); live = try await engine.sessionGroupSessions()
            error = nil; notice = "터미널에서 확인한 현재 세션 ID를 저장했습니다."
        } catch { notice = nil; self.error = error.localizedDescription }
    }

    private func refresh() async {
        guard !loading else { return }; loading = true; defer { loading = false }
        do {
            let saved = try store.load()
            let sessions = try await engine.sessionGroupSessions()
            groups = saved; live = sessions; assignments = try engine.sessionGroupAssignments(); error = nil
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
        let changed = group.removing(member.id)
        _ = persist(groups.map { $0.id == group.id ? changed : $0 },
                    message: group.leaderMemberID == member.id ? "그룹장을 제거했습니다. 구성원은 다시 평면 목록이 됩니다." : "그룹에서 세션을 제거했습니다. 하위 구성원은 제거한 세션의 상위로 옮겼습니다.")
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
