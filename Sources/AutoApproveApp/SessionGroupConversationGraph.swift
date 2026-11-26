import SwiftUI
import Combine
import QuartzCore
import AutoApproveCore

/// The conversation graph window of one session group. Data comes from
/// `ConversationGraphModel`, which reads storage off the main thread and publishes only
/// changes; dragging a node lives entirely in `ConversationGraphCanvas`.
@MainActor struct SessionGroupConversationGraph: View {
    let groupID: UUID
    let engine: ApprovalEngine
    @StateObject private var model: ConversationGraphModel
    @StateObject private var viewUpdates = WindowViewUpdates()
    @State private var selected: UUID?
    @State private var revealTask: Task<Void, Never>?
    let openTerminal: (AgentSession, ApprovalEngine) async throws -> Void
    @State private var replyTarget: SessionGroupConversation?
    @State private var deliveryTarget: SessionGroupConversation?
    @State private var deliveringQuestion: UUID?
    @State private var prioritizing: Set<UUID> = []
    @State private var deliveryFeedback: String?
    @State private var alert: GraphAlert?
    @State private var confirmClearMessages = false
    @State private var clearingMessages = false
    @State private var requestingNicknames = false
    @State private var nicknameNote: String?
    private let initialScope: SessionGroupGraph.Scope
    private let forcedLayout: SessionGroupGraph.Layout?
    private let initialZoom: Double?

    private struct GraphAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    init(groupID: UUID, engine: ApprovalEngine, sources: ConversationGraphModel.Sources? = nil, initialSelection: UUID? = nil,
         initialScope: SessionGroupGraph.Scope = .recent, layout: SessionGroupGraph.Layout? = nil, zoom: Double? = nil,
         openTerminal: @escaping (AgentSession, ApprovalEngine) async throws -> Void = TerminalNavigator.open) {
        self.openTerminal = openTerminal
        self.groupID = groupID
        self.engine = engine
        self.initialScope = initialScope
        forcedLayout = layout
        initialZoom = zoom
        _selected = State(initialValue: initialSelection)
        _model = StateObject(wrappedValue: ConversationGraphModel(groupID: groupID, directory: engine.paths.directory,
                                                                 sources: sources ?? .live(engine)))
    }

    var body: some View {
        let content = model.content.map { stored in
            var value = stored
            let labels = Dictionary(uniqueKeysWithValues: stored.group.members.map { ($0.id, viewUpdates.modelLabel($0)) })
            for i in value.nodes.indices { value.nodes[i].modelLabel = labels[value.nodes[i].id] ?? "" }
            return value
        }
        VStack(alignment: .leading, spacing: 0) {
            header(content)
            if let content, !content.group.members.isEmpty { summary(content) }
            Divider()
            if let deliveryFeedback {
                HStack {
                    Label(deliveryFeedback, systemImage: "checkmark.circle")
                    Spacer()
                    Button("닫기", systemImage: "xmark") { self.deliveryFeedback = nil }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("결과 표시를 닫습니다.")
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
            }
            if let content {
                if content.group.members.isEmpty {
                    ContentUnavailableView {
                        Label("구성원이 없습니다", systemImage: "person.2")
                    } actions: {
                        clearMessagesButton
                    }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(spacing: 0) {
                        ConversationGraphCanvas(nodes: content.nodes, recent: content.recentEdges, all: content.allEdges,
                                                fresh: model.freshEdges, hasLeader: !content.group.leaderMemberIDs.isEmpty,
                                                selection: $selected, initialScope: initialScope, forcedLayout: forcedLayout,
                                                initialZoom: initialZoom, openNode: openNode)
                            .frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        Divider()
                        inspector(content)
                            .frame(width: 320)
                            .frame(maxHeight: .infinity, alignment: .topLeading)
                    }
                    .frame(maxHeight: .infinity)
                }
                if content.page.hasMore {
                    Divider()
                    Text("미응답 우선 질문 300건, 기타 기록 150건까지 표시합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                }
            } else if let loadError = model.loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                Divider()
                ContentUnavailableView("대화 기록을 불러오지 못했습니다", systemImage: "tray")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("대화 기록 불러오는 중")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, idealWidth: 860, minHeight: 460, idealHeight: 590)
        .navigationTitle(content.map { "\($0.group.name) · 대화 그래프" } ?? "대화 그래프")
        .windowUpdates(viewUpdates, sources: [AnyPublisher<Void, Never>]())
        .task(id: viewUpdates.isVisible) {
            if viewUpdates.isVisible { await viewUpdates.observeModels(engine) }
        }
        .task(id: viewUpdates.isVisible) {
            guard viewUpdates.isVisible else { return }
            await model.observe()
        }
        .onDisappear { revealTask?.cancel() }
        .onExitCommand { selected = nil }
        .onChange(of: content?.group.members.map(\.id), initial: true) { _, ids in
            if let group = content?.group {
                let missing = group.members.filter { $0.nickname == nil || $0.role == nil }.map(\.id)
                if !missing.isEmpty {
                    do { try engine.requestSessionGroupNicknames(groupID: group.id, memberIDs: missing) }
                    catch { nicknameNote = error.localizedDescription }
                }
            }
            if let selected, ids?.contains(selected) != true { self.selected = nil }
        }
        .sheet(item: $replyTarget) { item in
            let question = item.question
            GroupConversationReplyEditor(question: question,
                                         sender: content?.name(question.recipientID) ?? "",
                                         recipient: content?.name(question.senderID) ?? "") { text in
                defer { model.reload() }
                _ = try engine.queueSessionGroupReply(groupID: groupID, questionID: question.id, text: text)
            }
        }
        .confirmationDialog("모든 메시지를 비울까요?", isPresented: $confirmClearMessages, titleVisibility: .visible) {
            Button("모든 메시지 비우기", role: .destructive) { clearMessages() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("‘\(content?.group.name ?? "선택한 그룹")’ 및 하위 그룹의 대기 메시지를 삭제하고 실행 중인 그룹 작업에 중단을 요청합니다.")
        }
        .confirmationDialog("원래 수신 노드에 질문 전달", isPresented: Binding(
            get: { deliveryTarget != nil }, set: { if !$0 { deliveryTarget = nil } }
        ), titleVisibility: .visible, presenting: deliveryTarget) { item in
            Button("터미널에 전달") { deliver(item) }
                .help("원래 질문을 수신 구성원의 터미널에 제출합니다.")
            Button("취소", role: .cancel) {}
                .help("질문을 전달하지 않고 돌아갑니다.")
        } message: { item in
            Text("\(content?.name(item.question.recipientID) ?? "")의 터미널에 원래 질문을 보냅니다. 이미 본 질문이면 새 응답이 시작될 수 있습니다.")
        }
        .alert(alert?.title ?? "", isPresented: Binding(
            get: { alert != nil }, set: { if !$0 { alert = nil } }
        ), presenting: alert) { _ in
            Button("확인", role: .cancel) {}
                .help("안내를 닫습니다.")
        } message: { Text($0.message) }
    }

    private func header(_ content: ConversationGraphModel.Content?) -> some View {
        let name = content?.group.name ?? "대화 그래프"
        return HStack(alignment: .firstTextBaseline) {
            Text(name)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(name)
            Spacer(minLength: 12)
            Button("새로고침", systemImage: "arrow.clockwise") { model.reload() }
                .labelStyle(.iconOnly)
                .help("로컬에 저장된 그룹 메시지와 질문·답변의 전달 상태를 다시 읽습니다.")
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, content == nil || content?.group.members.isEmpty == true ? 16 : 6)
    }

    /// Three counts in one size and color; only the icon of a delivery block turns red. The two
    /// member counts open a menu that selects a member, marked by a small chevron.
    private func summary(_ content: ConversationGraphModel.Content) -> some View {
        let responding = content.nodes.filter(\.status.needsResponse)
        let waiting = content.nodes.reduce(0) { $0 + $1.unacknowledged }
        let blocked = content.nodes.filter(\.status.blocked)
        return HStack(spacing: 16) {
            memberCount(SessionGroupGraph.needsResponseTitle, responding, symbol: "bubble.left", tint: .secondary,
                        help: "터미널에서 승인이나 입력을 기다리는 구성원 수입니다.",
                        menuHelp: "승인이나 입력을 기다리는 구성원을 선택해 상태와 대화를 봅니다.",
                        itemHelp: "이 구성원의 상태와 대화를 봅니다.")
            Label("수신 미확인 \(waiting)건", systemImage: "tray")
                .help("현재 구성원에게 저장됐지만 수신 확인이 남아 있는 그룹 메시지 수입니다. 터미널에 이미 제출된 메시지도 포함됩니다.")
            memberCount("전달 막힘", blocked, symbol: "exclamationmark.triangle", tint: .red,
                        help: "전달할 메시지가 있고 현재 입력할 수 없거나, 첫 전달 시도가 보류된 구성원을 셉니다.",
                        menuHelp: "전달이 막힌 구성원을 선택해 대기 건수와 보류 사유를 봅니다.",
                        itemHelp: "이 구성원의 입력 상태와 마지막 전달 보류 사유를 봅니다.")
            Spacer(minLength: 8)
            ConversationReadStatusLine(status: model.readStatus)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    /// "제목 N명": plain text at zero, otherwise a menu of those members with a chevron after the count.
    @ViewBuilder private func memberCount(_ title: String, _ members: [GraphNode], symbol: String, tint: Color,
                                          help: String, menuHelp: String, itemHelp: String) -> some View {
        if members.isEmpty {
            Label("\(title) 0명", systemImage: symbol)
                .help(help)
        } else {
            Menu {
                ForEach(members) { node in
                    Button(node.name) { selected = node.id }
                        .help(itemHelp)
                }
            } label: {
                Label {
                    Text("\(title) \(members.count)명 \(Text(Image(systemName: "chevron.down")).font(.caption2.weight(.semibold)))")
                } icon: {
                    Image(systemName: symbol + ".fill").foregroundStyle(tint)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(menuHelp)
            .accessibilityLabel("\(title) \(members.count)명")
            .accessibilityHint("구성원을 고르는 메뉴를 엽니다.")
        }
    }

    private func openNode(_ id: UUID) {
        selected = id
        revealTask?.cancel()
        revealTask = Task {
            do {
                let live = try await engine.sessionGroupSessions()
                try Task.checkCancellation()
                guard selected == id else { return }
                let group = try SessionGroupStore(directory: engine.paths.directory).load().first { $0.id == groupID }
                guard let member = group?.members.first(where: { $0.id == id }),
                      let target = SessionGroupMatching.connection(member, in: live),
                      member.conversationID.isEmpty || target.conversationID == nil ||
                        member.conversationID.caseInsensitiveCompare(target.conversationID ?? "") == .orderedSame else {
                    throw AppError.message("현재 이 구성원에 연결된 터미널을 확인할 수 없습니다. 그룹에서 세션 연결을 확인해주세요.")
                }
                try await openTerminal(target.session, engine)
            } catch {
                if !Task.isCancelled { alert = GraphAlert(title: "터미널을 열 수 없습니다", message: error.localizedDescription) }
            }
        }
    }

    private func deliver(_ item: SessionGroupConversation) {
        guard deliveringQuestion == nil else { return }
        let name = model.content?.name(item.question.recipientID) ?? "대상"
        deliveryFeedback = nil
        deliveringQuestion = item.id
        Task {
            defer { deliveringQuestion = nil; model.reload() }
            do {
                try await engine.deliverSessionGroupQuestion(groupID: groupID, questionID: item.id)
                deliveryFeedback = "\(name)의 터미널에 질문을 제출했습니다."
            } catch { alert = GraphAlert(title: "질문 전달을 확인하지 못했습니다", message: error.localizedDescription) }
        }
    }

    private var clearMessagesButton: some View {
        Button(clearingMessages ? "비우는 중…" : "모든 메시지 비우기", role: .destructive) {
            confirmClearMessages = true
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(clearingMessages || requestingNicknames)
    }

    private func clearMessages() {
        guard !clearingMessages else { return }
        clearingMessages = true
        nicknameNote = nil
        Task {
            defer { clearingMessages = false; model.reload() }
            do {
                deliveryFeedback = try await engine.clearSessionGroupMessages(groupID: groupID)
            } catch { alert = GraphAlert(title: "메시지 큐를 비우지 못했습니다", message: error.localizedDescription) }
        }
    }

    private func requestNicknames(_ members: [UUID]?) {
        guard !requestingNicknames else { return }
        requestingNicknames = true
        nicknameNote = nil
        Task {
            defer { requestingNicknames = false; model.reload() }
            do {
                let sent = try engine.requestSessionGroupNicknames(groupID: groupID, memberIDs: members, byUser: true)
                nicknameNote = sent == 0 ? "요청할 구성원이 없습니다"
                    : (engine.snapshot.paused ? "\(sent)명의 메시지 큐 맨 앞에 등록했습니다. 일시정지를 해제하면 우선 전달합니다." : "\(sent)명의 메시지 큐 맨 앞에 등록했습니다. 수신 세션이 입력 가능해지면 우선 전달합니다.")
            } catch { alert = GraphAlert(title: "이름 다시 정하기를 요청하지 못했습니다", message: error.localizedDescription) }
        }
    }

    private func nicknameNoteView() -> some View {
        Group {
            if let nicknameNote {
                Text(nicknameNote).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    // MARK: Right panel

    /// The text of a list item, a panel heading and a section title all start after the
    /// disclosure arrow (10pt) and its 5pt gap.
    private static let textInset: CGFloat = 16 + 10 + 5

    @ViewBuilder private func inspector(_ content: ConversationGraphModel.Content) -> some View {
        if let selected, let node = content.nodes.first(where: { $0.id == selected }) {
            memberDetail(node, content)
        } else {
            memberList(content)
        }
    }

    private func memberList(_ content: ConversationGraphModel.Content) -> some View {
        return VStack(alignment: .leading, spacing: 8) {
            Text("구성원을 고르면 대화 기록을 봅니다")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.top, 12)
            if !content.nodes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Button("전체 다시 정하기") { requestNicknames(nil) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(requestingNicknames || clearingMessages)
                            .help(requestingNicknames ? "요청을 저장하고 있습니다."
                                  : "구성원 \(content.nodes.count)명 각각의 큐에 자기 이름과 역할을 정하는 요청을 맨 앞에 등록합니다.")
                        clearMessagesButton
                    }
                    nicknameNoteView()
                }
                .padding(.horizontal, 16)
            }
            List(selection: $selected) {
                ForEach(content.nodes) { node in
                    memberRow(node).tag(node.id).listRowSeparator(.hidden)
                }
            }
            .listStyle(.inset)
            .accessibilityLabel("구성원 목록")
        }
    }

    private func memberRow(_ node: GraphNode) -> some View {
        HStack(spacing: 6) {
            GraphNodeSymbol(agent: node.agent, status: node.status, diameter: 14)
                .frame(width: 22, height: 22)
            Text(node.name)
                .foregroundStyle(node.provisional ? .secondary : .primary)
                .lineLimit(1).truncationMode(.middle)
            Text(node.status.title)
                .font(.caption)
                .foregroundStyle(node.status.blocked ? Color.red : Color.secondary)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if node.unacknowledged > 0 {
                Text("\(node.unacknowledged)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .background(.quaternary, in: Capsule())
                    .help("수신 미확인 \(node.unacknowledged)건")
                    .accessibilityLabel("수신 미확인 \(node.unacknowledged)건")
            }
        }
        .padding(.leading, CGFloat(node.depth) * 16)
        .accessibilityElement(children: .combine)
        .help("\(node.name) · \(node.agent.title) · \(node.status.title)" + (node.provisional ? "\n임시 이름입니다. 닉네임이 정해지면 바뀝니다." : ""))
    }

    private func memberDetail(_ node: GraphNode, _ content: ConversationGraphModel.Content) -> some View {
        let id = node.id
        let conversations = content.page.conversations.filter { $0.question.senderID == id || $0.question.recipientID == id }
        let messages = content.page.messages.filter { $0.senderID == id || $0.recipientID == id }
        let inset = Self.textInset
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Button { selected = nil } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left").font(.caption.weight(.semibold)).frame(width: 10)
                        Text("구성원 목록")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .padding(.leading, 16).padding(.top, 12)
                .help("구성원 목록으로 돌아갑니다. Esc 키를 누르거나 그래프의 빈 곳을 클릭해도 됩니다.")
                VStack(alignment: .leading, spacing: 3) {
                    Text(node.name).font(.headline).lineLimit(2).help(node.name)
                    Text(node.modelLabel).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(node.status.title).foregroundStyle(statusColor(node.status))
                    Text("\(node.agent.title) · \(node.isLeader ? "그룹장" : "구성원")")
                        .font(.caption).foregroundStyle(.secondary)
                    if let role = node.role {
                        Text("역할: " + role).font(.callout).lineLimit(3).padding(.top, 2).help(role)
                    }
                    Button {
                        guard prioritizing.insert(id).inserted else { return }
                        Task {
                            defer { prioritizing.remove(id); model.reload() }
                            do { deliveryFeedback = try await engine.prioritizeSessionGroupReplies(groupID: groupID, memberID: id) }
                            catch { alert = GraphAlert(title: "우선 회신을 요청할 수 없습니다", message: error.localizedDescription) }
                        }
                    } label: {
                        Label(prioritizing.contains(id) ? "우선 회신 요청 중…" : "미응답 질문 먼저 회신", systemImage: "arrowshape.turn.up.left")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(prioritizing.contains(id) || (!content.page.hasMore && !conversations.contains {
                        $0.question.recipientID == id && $0.answer == nil && !$0.waitExpired
                    }))
                    .help("이 구성원의 작업을 보류하고 오래된 질문부터 답한 뒤 원래 작업을 이어가도록 요청합니다.")
                    Button("이 구성원 이름 다시 정하기") { requestNicknames([node.id]) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(requestingNicknames)
                        .padding(.top, 6)
                        .help(requestingNicknames ? "요청을 저장하고 있습니다."
                              : "이 구성원의 큐에 자기 이름과 역할을 정하는 요청을 맨 앞에 등록합니다.")
                    nicknameNoteView()
                }
                .padding(.leading, inset).padding(.trailing, 16).padding(.top, 8).padding(.bottom, 12)
                Divider()
                if let operation = content.operations[id] {
                    sectionTitle("세션 상태")
                    memberOperation(operation, blocked: node.status.blocked)
                        .padding(.leading, inset).padding(.trailing, 16)
                }
                if conversations.isEmpty && messages.isEmpty {
                    Label("저장된 대화가 없습니다", systemImage: "bubble.left.and.bubble.right")
                        .foregroundStyle(.secondary)
                        .padding(.leading, inset).padding(.top, 14)
                }
                if !conversations.isEmpty {
                    sectionTitle("질문과 답변")
                    ForEach(conversations) { item in questionItem(item, member: id, content) }
                }
                if !messages.isEmpty {
                    sectionTitle("메시지와 보고")
                    ForEach(messages, id: \.id) { item in messageItem(item, member: id, content) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 16)
        }
        .id(id)
    }

    private func statusColor(_ status: SessionGroupGraph.NodeStatus) -> Color {
        if status.blocked { return .red }
        return status.shape == .unknown ? .secondary : .primary
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .padding(.leading, Self.textInset)
            .padding(.top, 16).padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }

    private func memberOperation(_ operation: GraphMemberOperation, blocked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            valueRow("수신 미확인", "\(operation.unacknowledgedCount)건")
            switch operation.input {
            case .unverified: valueRow("터미널 입력", "입력 상태 미확인")
            case .idle:
                valueRow("터미널 입력", "대기 중 · 제출 직전 확인")
                    .help("AutoApprove는 실제로 제출하기 전에 현재 터미널의 빈 입력창을 확인합니다.")
            case let .deferred(reason): valueRow("터미널 입력", reason, attention: blocked)
            }
            // The only place that tells approval from input; everywhere else both are "응답 필요".
            valueRow("대화 연결", operation.phase.map { "대화 확인 · " + SessionGroupGraph.detailTitle($0) } ?? (operation.terminalPhase != nil ? "터미널 연결 · 대화 ID 미확인" : "대화 미확인"))
            VStack(alignment: .leading, spacing: 2) {
                Text("마지막 수신 확인 " + formatOperationDate(operation.lastAcknowledgedAt))
                if let first = operation.firstPendingAt {
                    Text("가장 오래된 미확인 " + formatOperationDate(first))
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if let reason = operation.lastDeliveryFailure, !reason.isEmpty {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("이 구성원에게 먼저 전달할 메시지의 마지막 보류 사유입니다.")
            }
        }
    }

    private func valueRow(_ name: String, _ value: String, attention: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text(value).foregroundStyle(attention ? Color.red : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func questionItem(_ item: SessionGroupConversation, member: UUID, _ content: ConversationGraphModel.Content) -> some View {
        let outbound = item.question.senderID == member
        let peer = outbound ? item.question.recipientID : item.question.senderID
        let (state, color): (String, Color) = item.answer != nil ? ("답변 있음", .secondary)
            : item.waitExpired ? ("대기 만료", Color.secondary.opacity(0.6)) : ("미응답", .orange)
        return VStack(alignment: .leading, spacing: 4) {
            DisclosureGroup {
                message("질문", item.question)
                if let answer = item.answer { message("답변", answer) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    (Text(state).fontWeight(.semibold).foregroundColor(color)
                     + Text(outbound ? "  보냄 → " : "  받음 ← ") + Text(content.name(peer)))
                        .lineLimit(1)
                    Text(time(item.question.createdAt) + " · " + delivery(item.answer ?? item.question))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(item.question.text).font(.caption).lineLimit(1)
                }
            }
            .disclosureGroupStyle(ConversationDisclosureStyle(summary: "질문과 답변 원문"))
            if item.answer == nil, !item.question.isExpired, content.group.members.contains(where: { $0.id == peer }) {
                HStack(spacing: 12) {
                    Button("노드에 전달…") { deliveryTarget = item }
                        .disabled(deliveringQuestion != nil)
                        .help(deliveringQuestion == nil
                              ? "\(content.name(item.question.recipientID))의 터미널에 원래 질문을 보냅니다. 제출하기 전에 확인 창이 열립니다."
                              : "진행 중인 질문 전달이 끝나면 다시 사용할 수 있습니다.")
                    Button("답변…") { replyTarget = item }
                        .help("질문을 받은 구성원 대신 답변을 작성해 원래 질문자에게 보냅니다.")
                    if deliveringQuestion == item.id {
                        ProgressView().controlSize(.small).accessibilityLabel("질문 전달 중")
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .padding(.leading, 15)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    private func messageItem(_ item: SessionGroupMessage, member: UUID, _ content: ConversationGraphModel.Content) -> some View {
        let outgoing = item.senderID == member
        let peer = outgoing ? item.recipientID : item.senderID
        let kind = item.isNicknameRequest ? "닉네임·역할 요청" : item.kind == .report ? "보고" : item.kind == .reply ? "답변" : item.kind == .choiceQuestion ? "선택 질문" : "메시지"
        return DisclosureGroup {
            message(kind, item)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(time(item.createdAt) + (item.isNicknameRequest ? "" : (outgoing ? " 보냄 → " : " 받음 ← ") + content.name(peer)) + " · " + kind + " · " + delivery(item))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(item.text).lineLimit(2)
            }
        }
        .disclosureGroupStyle(ConversationDisclosureStyle(summary: "메시지 원문"))
        .padding(.horizontal, 16).padding(.vertical, 6)
    }

    private func time(_ date: Date) -> String {
        date.formatted(.dateTime.month().day().hour().minute())
    }

    private func formatOperationDate(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .shortened) ?? "기록 없음"
    }

    private func delivery(_ message: SessionGroupMessage) -> String {
        if message.acknowledgedAt != nil { return "수신 확인" }
        switch message.lastResult {
        case "expired": return "수신 기한 만료"
        case "direct_attempting", "direct_unknown", "unknown": return "전달 여부 미확인"
        case "direct_submitted", "submitted": return "터미널 제출"
        case "redeliver": return "다시 전달 대기"
        case "undelivered": return "자동 전달 중단"
        case "late": return "기한 후 수신함 보관"
        case "batched": return "묶음 전달 대기"
        default: return "전달 대기"
        }
    }

    private func message(_ label: String, _ message: SessionGroupMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label + " · " + message.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(message.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 5)
    }
}

/// The time of the last check, or since when reading has failed. Its own observed object
/// changes every second, so only this line is redrawn.
private struct ConversationReadStatusLine: View {
    @ObservedObject var status: ConversationGraphModel.ReadStatus

    private static let second: DateFormatter = { let value = DateFormatter(); value.dateFormat = "HH:mm:ss"; return value }()
    private static let minute: DateFormatter = { let value = DateFormatter(); value.dateFormat = "HH:mm"; return value }()

    var body: some View {
        if let failure = status.failure {
            Text(status.failedSince.map { "\(Self.minute.string(from: $0)) 이후 다시 읽지 못함" } ?? "다시 읽지 못함")
                .foregroundStyle(.red)
                .help("로컬 수신함이나 그룹 파일을 다시 읽지 못했습니다. 화면은 마지막으로 읽은 기록입니다. " + failure)
        } else if let checked = status.checkedAt {
            Text("\(Self.second.string(from: checked)) 다시 읽음")
                .help("창이 보이는 동안 로컬 수신함과 그룹 파일을 1초마다 확인하고, 바뀐 내용이 있을 때만 다시 그립니다.")
        }
    }
}

private struct ConversationDisclosureStyle: DisclosureGroupStyle {
    let summary: String

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                        .padding(.top, 2)
                    configuration.label
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "펼침" : "접힘")
            .help(summary + (configuration.isExpanded ? " 접기" : " 펼치기"))
            if configuration.isExpanded {
                configuration.content.padding(.leading, 15)
            }
        }
    }
}

private struct GroupConversationReplyEditor: View {
    let question: SessionGroupMessage
    let sender: String
    let recipient: String
    let send: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = SessionGroupOrchestration.maximumTaskLength
        VStack(alignment: .leading, spacing: 12) {
            Text("질문에 답변").font(.headline)
            Text("\(sender) 대신 \(recipient)에게").foregroundStyle(.secondary)
            ScrollView {
                Text(question.text).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 100)
            .accessibilityLabel("원래 질문")
            TextEditor(text: $text)
                .focused($focused)
                .accessibilityLabel("답변 내용")
                .frame(minHeight: 110)
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary).allowsHitTesting(false) }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            HStack {
                Text("\(body.count) / \(limit)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(body.count > limit ? Color.red : Color.secondary)
                Spacer()
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help("작성 중인 답변을 보관하지 않고 닫습니다.")
                Button("답변 보내기") {
                    do { try send(body); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent)
                .disabled(body.isEmpty || body.count > limit || body.contains("\0"))
                .help(body.isEmpty ? "답변 내용을 입력하면 보낼 수 있습니다."
                      : body.count > limit ? "답변을 \(limit)자 이하로 줄여주세요."
                      : "답변을 원래 질문에 연결하고 \(recipient)의 로컬 그룹 수신함에 저장합니다.")
            }
        }
        .padding(20)
        .frame(width: 460)
        .defaultFocus($focused, true)
    }
}

private extension AgentKind {
    var graphColor: Color {
        switch self {
        case .codex: .blue
        case .claude: .purple
        case .agy: .green
        case .shell: .gray
        }
    }
}

// MARK: - Graph area

/// Controls, legend and the graph. Drag state, moved positions, zoom, pan, focus and the view
/// choice live here only, so moving, zooming or panning never recomputes the window around it.
@MainActor private struct ConversationGraphCanvas: View {
    let nodes: [GraphNode]
    let recent: [SessionGroupGraph.Edge]
    let all: [SessionGroupGraph.Edge]
    let fresh: Set<SessionGroupGraph.EdgeKey>
    let openNode: (UUID) -> Void
    let hasLeader: Bool
    @Binding var selection: UUID?
    let forcedLayout: SessionGroupGraph.Layout?
    @AppStorage("sessionGroupGraph.layout") private var storedLayout: SessionGroupGraph.Layout = .circle
    @State private var scope: SessionGroupGraph.Scope
    /// Moved positions per layout, kept in memory until the window closes.
    @State private var offsets: [SessionGroupGraph.Layout: [UUID: CGSize]] = [:]
    private final class ForceCache {
        var ids: [UUID] = []
        var depths: [Int] = []
        var sizes: [UUID: Double] = [:]
        var edges: [SessionGroupGraph.Edge] = []
        var points: [UUID: CGPoint] = [:]
    }
    @State private var forceCache = ForceCache()
    @State private var movingNode: UUID?
    @State private var preview = ConversationDragPreview()
    @GestureState private var dragging = false
    @FocusState private var focused: UUID?
    /// The matrix element with keyboard focus.
    @FocusState private var matrixFocus: SessionGroupGraph.MatrixSpot?
    /// The one matrix element in the Tab order; arrow keys move it, so Tab never walks every cell.
    @State private var matrixCurrent: SessionGroupGraph.MatrixSpot = .cell(row: 0, column: 0)
    /// The matrix element last pressed, outlined while its member stays selected.
    @State private var matrixPressed: SessionGroupGraph.MatrixSpot?
    @Environment(\.colorScheme) private var colorScheme
    /// Fitted until the user zooms, pans or moves a node; after that data updates keep the view.
    @State private var mode: ViewMode
    /// The view when an empty-space drag passed 4pt or a pinch began.
    @State private var panStart: SessionGroupGraph.Viewport?
    @State private var pinchStart: SessionGroupGraph.Viewport?
    /// The graph area size, for the zoom buttons in its corner.
    @State private var areaSize: CGSize = .zero
    /// The zoom buttons' size, so scrolls over them do not pan the graph underneath.
    @State private var zoomControlsSize: CGSize = .zero

    /// The graph area, before zoom and pan: gestures in it report pointer positions in this space.
    private static let space = "conversationViewport"

    private enum ViewMode: Equatable {
        /// Recomputed from the nodes and the area size; 60% to 100% on open and after a layout change,
        /// 25% to 100% after "맞춤", one fixed scale for the render harness.
        case fitted(minimum: Double, maximum: Double)
        case manual(SessionGroupGraph.Viewport)

        static let automatic = ViewMode.fitted(minimum: SessionGroupGraph.automaticFitMinimum, maximum: 1)
    }

    init(nodes: [GraphNode], recent: [SessionGroupGraph.Edge], all: [SessionGroupGraph.Edge], fresh: Set<SessionGroupGraph.EdgeKey>,
         hasLeader: Bool, selection: Binding<UUID?>, initialScope: SessionGroupGraph.Scope, forcedLayout: SessionGroupGraph.Layout?,
         initialZoom: Double? = nil, openNode: @escaping (UUID) -> Void) {
        self.openNode = openNode
        self.nodes = nodes; self.recent = recent; self.all = all; self.fresh = fresh; self.hasLeader = hasLeader
        _selection = selection
        self.forcedLayout = forcedLayout
        _scope = State(initialValue: initialScope)
        _mode = State(initialValue: initialZoom.map { .fitted(minimum: $0, maximum: $0) } ?? .automatic)
    }

    /// Node centres in graph coordinates: the automatic layout and, on top of it, moved positions.
    private struct Placement {
        let base: [UUID: CGPoint]
        let points: [UUID: CGPoint]
        /// Circle diameters from each member's message step in the current view; the spacing
        /// between nodes comes from the "전체" view's steps instead.
        let diameters: [UUID: Double]
        var radii: [UUID: Double] { diameters.mapValues { $0 / 2 } }
        /// Every node with its ring and name band, for fitting and for the pan limit.
        let content: CGRect
        let leader: CGPoint?
        /// A table reads from its top, so a matrix that fits starts at the top instead of the middle.
        var topAligned = false
    }

    var body: some View {
        let layout = forcedLayout ?? storedLayout
        let edges = scope == .recent ? recent : all
        let moved = offsets[layout] ?? [:]
        let placement = place(layout: layout, moved: moved)
        VStack(alignment: .leading, spacing: 0) {
            controls(layout: layout, moved: !moved.isEmpty)
            // The hidden full legend reserves the height, so a state or line kind appearing
            // never pushes the graph down and the nodes keep their places.
            ZStack(alignment: .topLeading) {
                legend(edges, everything: true, matrix: !layout.drawsNodes).hidden().accessibilityHidden(true)
                legend(edges, everything: false, matrix: !layout.drawsNodes)
            }
            Divider()
            GeometryReader { proxy in
                let size = proxy.size
                let view = viewport(placement, size: size)
                /* graph-probe: viewport */
                /* graph-probe: selection */
                let bends = layout.drawsNodes ? SessionGroupGraph.bends(edges, points: placement.points, radii: placement.radii) : [:]
                let related = selection.map { chosen in Set(edges.filter { $0.touches(chosen) }.flatMap { [$0.from, $0.to] }).union([chosen]) }
                // A scroll view that never scrolls: zoom and pan move the graph instead. Its container
                // takes the first click in an inactive window, as the graph did when it scrolled, so
                // pressing a node there starts the drag or selection at once.
                ScrollView([]) {
                ZStack(alignment: .topLeading) {
                    // A click on empty space clears the selection; a drag of 4pt or more pans.
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(panGesture(view, placement, size) { selection = nil; focused = nil; matrixFocus = nil; matrixPressed = nil })
                        .accessibilityHidden(true)
                    if layout.drawsNodes {
                        Canvas { context, _ in
                            context.translateBy(x: view.offset.x, y: view.offset.y)
                            context.scaleBy(x: view.scale, y: view.scale)
                            draw(edges, placement: placement, bends: bends, in: &context)
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        ForEach(nodes) { node in
                            if let point = placement.points[node.id] {
                                nodeView(node, at: point, layout: layout, placement: placement, view: view, size: size, edges: edges, bends: bends,
                                         dimmed: related.map { !$0.contains(node.id) } ?? false)
                            }
                        }
                    } else {
                        matrixGrid(edges, view: view, placement: placement, size: size)
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .clipped()
                .contentShape(Rectangle())
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { value in
                        let start = pinchStart ?? view
                        if pinchStart == nil { pinchStart = view }
                        adjust(start.zoomed(to: start.scale * value.magnification, around: value.startLocation), placement, size)
                    }
                    .onEnded { _ in pinchStart = nil })
                .overlay { ConversationDragSurface(preview: preview).allowsHitTesting(false).accessibilityHidden(true) }
                .background {
                    ConversationScrollEvents(excluded: zoomControlsFrame(in: size)) { delta, pointer, zooming in
                        if zooming {
                            adjust(view.zoomed(to: view.scale * exp(delta.dy / 100), around: pointer), placement, size)
                        } else {
                            adjust(view.panned(by: delta), placement, size)
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .coordinateSpace(name: Self.space)
                }
                .scrollDisabled(true)
                .onAppear { areaSize = size }
                .onChange(of: size) { _, value in areaSize = value }
            }
            // Over the graph area's lower right corner, so the control row stays one line in a
            // narrow window. A node under the buttons is seen by panning the graph.
            .overlay(alignment: .bottomTrailing) {
                zoomControls(viewport(placement, size: areaSize), placement: placement)
                    .onGeometryChange(for: CGSize.self, of: \.size) { zoomControlsSize = $0 }
                    .padding(Self.zoomControlsMargin)
            }
            .overlay(alignment: .topLeading) {
                if scope == .recent && edges.isEmpty {
                    Text("최근 30분 동안 오간 메시지가 없습니다")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
        }
        .onChange(of: dragging) { _, active in
            if !active, preview.isActive { finishDrag() }
        }
        .onChange(of: storedLayout) { _, _ in
            if forcedLayout == nil { mode = .automatic }
        }
        .onDisappear { if preview.isActive { finishDrag() } }
    }

    // MARK: Zoom and pan

    private func viewport(_ placement: Placement, size: CGSize) -> SessionGroupGraph.Viewport {
        switch mode {
        case let .fitted(minimum, maximum):
            let fitCircle = [.circle, .force].contains(forcedLayout ?? storedLayout)
            return SessionGroupGraph.fit(placement.content, in: size, minimum: mode == .automatic && fitCircle ? SessionGroupGraph.minimumZoom : minimum, maximum: maximum, focus: placement.leader,
                                  topAligned: placement.topAligned)
        case let .manual(view): return view
        }
    }

    /// A zoom or pan by the user: the view stays as set until the user fits it again.
    private func adjust(_ view: SessionGroupGraph.Viewport, _ placement: Placement, _ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        mode = .manual(SessionGroupGraph.constrained(view, content: placement.content, size: size))
    }

    /// A press that moves 4pt or more pans the graph; a shorter press is a click and runs `tap`.
    /// Empty space and matrix cells share it, so a matrix pans wherever the drag starts.
    private func panGesture(_ view: SessionGroupGraph.Viewport, _ placement: Placement, _ size: CGSize,
                            tap: @escaping () -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if panStart == nil {
                    guard hypot(value.translation.width, value.translation.height) >= 4 else { return }
                    panStart = view
                }
                guard let start = panStart else { return }
                adjust(start.panned(by: CGVector(dx: value.translation.width, dy: value.translation.height)), placement, size)
            }
            .onEnded { _ in
                if panStart == nil { tap() }
                panStart = nil
            }
    }

    private static let zoomControlsMargin: CGFloat = 12

    /// The zoom buttons in graph area coordinates.
    private func zoomControlsFrame(in size: CGSize) -> CGRect {
        CGRect(x: size.width - Self.zoomControlsMargin - zoomControlsSize.width,
               y: size.height - Self.zoomControlsMargin - zoomControlsSize.height,
               width: zoomControlsSize.width, height: zoomControlsSize.height)
    }

    /// Buttons and shortcuts zoom around the middle of the graph area.
    private func zoom(to scale: Double, from view: SessionGroupGraph.Viewport, placement: Placement) {
        adjust(view.zoomed(to: scale, around: CGPoint(x: areaSize.width / 2, y: areaSize.height / 2)), placement, areaSize)
    }

    // MARK: Controls and legend

    private func controls(layout: SessionGroupGraph.Layout, moved: Bool) -> some View {
        let layoutPicker = Picker("배치", selection: Binding(get: { layout }, set: { storedLayout = $0 })) {
                Text("트리").tag(SessionGroupGraph.Layout.tree)
                Text("원형").tag(SessionGroupGraph.Layout.circle)
                Text("방사형").tag(SessionGroupGraph.Layout.radial)
                Text("포스").tag(SessionGroupGraph.Layout.force)
                Text("행렬").tag(SessionGroupGraph.Layout.matrix)
            }
        let pickers = HStack(spacing: 12) {
            Picker("보기", selection: $scope) {
                Text("최근").tag(SessionGroupGraph.Scope.recent)
                Text("전체").tag(SessionGroupGraph.Scope.all)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("최근은 답을 기다리는 질문과 최근 30분 동안 오간 메시지를 그립니다. 전체는 지난 기록과 만료된 질문을 흐리게 함께 그립니다.")
            Group {
                if areaSize.width < 490 {
                    layoutPicker.pickerStyle(.menu)
                } else {
                    layoutPicker.pickerStyle(.segmented)
                }
            }
            .fixedSize()
            .help("포스는 상하 관계와 대화량에 따라 구성원을 가깝게 놓습니다. 배치 선택은 다음에 열 때도 유지합니다.")
            // Shown only while a node is moved, so a link never sits there unclickable. It keeps
            // its width while hidden, so the row does not shift when it appears. The matrix has no
            // nodes to move, so it never shows there.
            let showReset = moved && layout.drawsNodes
            Button("자동 배치로") { offsets[layout] = nil }
                .buttonStyle(.link)
                .disabled(!showReset)
                .opacity(showReset ? 1 : 0)
                .accessibilityHidden(!showReset)
                .help("직접 옮긴 노드를 자동 배치 위치로 되돌립니다.")
        }
        .controlSize(.small)
        let hints = HStack(spacing: 12) {
            if layout.drawsNodes {
                Text("노드를 드래그해 이동")
                    .help("노드를 누른 채 끌면 연결선이 따라옵니다. 클릭하면 해당 구성원의 대화를 봅니다. 옮긴 위치는 창을 닫으면 자동 배치로 돌아갑니다. 빈 곳을 끌거나 두 손가락으로 스크롤하면 그래프를 옮기고, 핀치나 ⌘ 키를 누른 채 스크롤하면 포인터 위치를 기준으로 확대하거나 축소합니다.")
                Label("발신 → 수신", systemImage: "arrow.right")
                    .help("화살표는 수신 구성원을 가리킵니다. 두 구성원이 서로 주고받으면 방향마다 선을 하나씩 그립니다.")
            } else {
                Text("칸을 눌러 보낸 구성원 선택")
                    .help("칸을 누르면 그 칸의 보낸 구성원을, 행이나 열 머리를 누르면 그 구성원을 고릅니다. 화살표 키로 칸과 머리 사이를 옮기고 스페이스나 리턴 키로 고릅니다. 칸이나 빈 곳을 끌거나 두 손가락으로 스크롤하면 표를 옮기고, 핀치나 ⌘ 키를 누른 채 스크롤하면 포인터 위치를 기준으로 확대하거나 축소합니다.")
                Label("행 보냄 → 열 받음", systemImage: "arrow.right")
                    .help("행은 보낸 구성원, 열은 받은 구성원입니다. 칸의 숫자는 지금 보기에서 그 방향으로 오간 메시지 수입니다.")
            }
        }
        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        // The hints show at the right end only when they fit beside the pickers.
        return ControlRowLayout(spacing: 12) {
            pickers
            ViewThatFits(in: .horizontal) { hints; Color.clear.frame(width: 0, height: 0) }
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
    }

    /// − NN% + 맞춤. ⌘− ⌘+ ⌘0 work while this window is the key window, since a button's
    /// shortcut belongs to its window. The percentage returns to 100%.
    private func zoomControls(_ view: SessionGroupGraph.Viewport, placement: Placement) -> some View {
        let percent = Int((view.scale * 100).rounded())
        let smallest = view.scale <= SessionGroupGraph.minimumZoom + 0.001
        let largest = view.scale >= SessionGroupGraph.maximumZoom - 0.001
        let value = "\(percent)%"
        let larger = { zoom(to: SessionGroupGraph.steppedZoom(from: view.scale, larger: true), from: view, placement: placement) }
        return HStack(spacing: 2) {
            Button { zoom(to: SessionGroupGraph.steppedZoom(from: view.scale, larger: false), from: view, placement: placement) } label: {
                Image(systemName: "minus").frame(width: 12)
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(smallest)
            .help(smallest ? "가장 작은 배율(25%)입니다." : "그래프를 축소합니다(⌘−).")
            .accessibilityLabel("축소")
            .accessibilityValue(value)
            Button { zoom(to: 1, from: view, placement: placement) } label: {
                Text(value).monospacedDigit().frame(minWidth: 34)
            }
            .help("지금 배율은 \(value)입니다. 누르면 100%로 되돌립니다.")
            .accessibilityLabel("배율")
            .accessibilityValue(value)
            .accessibilityHint("누르면 100%로 되돌립니다.")
            Button(action: larger) {
                Image(systemName: "plus").frame(width: 12)
            }
            .keyboardShortcut("=", modifiers: .command)
            .disabled(largest)
            .help(largest ? "가장 큰 배율(300%)입니다." : "그래프를 확대합니다(⌘+).")
            .accessibilityLabel("확대")
            .accessibilityValue(value)
            Button("맞춤") { mode = .fitted(minimum: SessionGroupGraph.minimumZoom, maximum: 1) }
                .keyboardShortcut("0", modifiers: .command)
                .help("구성원 전체가 보이도록 배율과 위치를 맞춥니다(⌘0).")
                .accessibilityHint("구성원 전체가 보이도록 배율과 위치를 맞춥니다.")
        }
        .buttonStyle(GraphZoomButtonStyle())
        .focusEffectDisabled()
        .padding(1)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .background {
            // ⌘+ typed with Shift, or on the numeric keypad. Invisible and outside the Tab order.
            Button("확대", action: larger)
                .keyboardShortcut("+", modifiers: .command)
                .disabled(largest)
                .opacity(0)
                .frame(width: 0, height: 0)
                .focusable(false)
                .accessibilityHidden(true)
        }
        // The window background under the light fill keeps the buttons readable over lines and nodes.
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        // A press or drag that starts on the group, also between two buttons, stays here and
        // never pans the graph or clears the selection underneath.
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .fixedSize()
        /* graph-probe: zoom */
        .accessibilityElement(children: .contain)
        .accessibilityLabel("확대와 축소")
    }

    /// Only the agents, states and line kinds on screen, then the width steps. The matrix draws no
    /// lines or sized circles, so it shows its cell shades and the "?N" mark instead.
    private func legend(_ edges: [SessionGroupGraph.Edge], everything: Bool, matrix: Bool) -> some View {
        let agents = [AgentKind.claude, .codex, .agy, .shell].filter { agent in nodes.contains { $0.agent == agent } }
        let idle = SessionGroupGraph.status(phase: .idle, blocked: false)
        let states: [(SessionGroupGraph.NodeStatus, String)] = [
            (SessionGroupGraph.status(phase: .working, blocked: false), "작업 중"), (idle, "대기"),
            (SessionGroupGraph.status(phase: .input, blocked: false), "응답 필요"),
            (SessionGroupGraph.status(phase: .idle, blocked: true), "전달 막힘"),
            (SessionGroupGraph.status(phase: nil, blocked: false), "상태 미확인")
        ].filter { state, _ in
            everything || nodes.contains { state.blocked ? $0.status.blocked : (!$0.status.blocked && $0.status.shape == state.shape) }
        }
        // The hidden height reservation lists every line kind of both views, so switching
        // between recent and all never changes the legend height and the graph stays put.
        let possible: Set<SessionGroupGraph.EdgeKind> = [.pendingQuestion, .recent, .older, .expiredQuestion]
        let kinds = everything ? possible : Set(edges.map(\.kind))
        let faded = Self.gray.opacity(0.35)
        let lineKinds: [(SessionGroupGraph.EdgeKind, String, Color, Bool)] = [
            (.pendingQuestion, "답을 기다리는 질문", .orange, false), (.recent, "최근 30분 메시지", Self.gray, false),
            (.older, "지난 기록", faded, false), (.expiredQuestion, "만료된 질문", faded, true)
        ]
        let lines = matrix ? [] : lineKinds.filter { kinds.contains($0.0) }.map { ($0.1, $0.2, $0.3) }
        // Every item is its own piece of the flow, so a narrow graph wraps between items.
        // The first item of a group keeps 20pt before it; items inside a group keep 12pt.
        return LegendFlow(groupSpacing: 20, itemSpacing: 12, lineSpacing: 6) {
            ForEach(Array(agents.enumerated()), id: \.element) { index, agent in
                Label { Text(agent.title) } icon: { Circle().fill(agent.graphColor).frame(width: 10, height: 10) }
                    .layoutValue(key: LegendGroupStart.self, value: index == 0)
            }
            ForEach(Array(states.enumerated()), id: \.element.1) { index, item in
                Label { Text(item.1) } icon: { GraphNodeSymbol(agent: .shell, status: item.0, diameter: 12).frame(width: 18, height: 18) }
                    .layoutValue(key: LegendGroupStart.self, value: index == 0)
            }
            if !lines.isEmpty {
                ForEach(Array(lines.enumerated()), id: \.element.0) { index, line in
                    lineLegend(line.0, color: line.1, dashed: line.2)
                        .layoutValue(key: LegendGroupStart.self, value: index == 0)
                }
                HStack(spacing: 8) {
                    Text("굵기")
                    ForEach([(1.5, "1"), (3.0, "2-4"), (4.5, "5-9"), (6.0, "10+건")], id: \.1) { width, title in
                        HStack(spacing: 3) {
                            Capsule().fill(Self.gray).frame(width: 16, height: width)
                            Text(title)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("선 굵기는 건수입니다. 1건, 2에서 4건, 5에서 9건, 10건 이상")
                .layoutValue(key: LegendGroupStart.self, value: true)
            }
            if matrix {
                HStack(spacing: 8) {
                    Text("칸 진하기")
                    ForEach([(1, "1"), (2, "2-4"), (3, "5-9"), (4, "10+건")], id: \.0) { shade, title in
                        HStack(spacing: 3) {
                            Rectangle().fill(Self.matrixFill(shade))
                                .overlay { Rectangle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5) }
                                .frame(width: 14, height: 12)
                            Text(title)
                        }
                    }
                }
                .fixedSize()
                .help("칸이 진할수록 지금 보기에서 그 방향으로 오간 메시지가 많습니다. 사선이 그어진 칸은 자기 자신이라 비어 있습니다. 선 굵기와 같은 1건, 2~4건, 5~9건, 10건 이상의 네 단계입니다.")
                .accessibilityElement(children: .combine)
                .accessibilityLabel("칸 진하기는 메시지 수입니다. 1건, 2에서 4건, 5에서 9건, 10건 이상")
                .layoutValue(key: LegendGroupStart.self, value: true)
                if everything || edges.contains(where: { $0.pendingQuestions > 0 }) {
                    Label {
                        Text("답을 기다리는 질문")
                    } icon: {
                        Text("?N").font(.caption2.weight(.bold)).foregroundStyle(Color.orange)
                            .padding(.horizontal, 3)
                            .overlay { Rectangle().strokeBorder(Color.orange, lineWidth: 1.5) }
                    }
                    .help("주황 테두리와 ?N 은 그 칸의 보낸 구성원이 답을 기다리는 질문 수입니다.")
                    .layoutValue(key: LegendGroupStart.self, value: false)
                }
            } else {
            // Circles at 40% of the node diameters (11 to 16pt), so the four steps read as growing sizes.
            HStack(spacing: 8) {
                Text("크기")
                ForEach(SessionGroupGraph.NodeSize.allCases, id: \.self) { size in
                    HStack(spacing: 3) {
                        Circle().strokeBorder(Self.gray, lineWidth: 1)
                            .frame(width: size.diameter * 0.4, height: size.diameter * 0.4)
                            .frame(width: 16, height: 16)
                        Text(size.title)
                    }
                }
            }
            .help("원 크기는 지금 보기에 그려진 선에서 그 구성원이 보내고 받은 메시지 수입니다. 0건, 1~4건, 5~19건, 20건 이상의 네 단계로 나눕니다.")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("원 크기는 주고받은 메시지 수입니다. 0건, 1에서 4건, 5에서 19건, 20건 이상")
            .layoutValue(key: LegendGroupStart.self, value: true)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private static let gray = Color(nsColor: .systemGray)

    /// The cell shades 1 to 4 over the window background, light enough for the count on top to read.
    static func matrixFill(_ shade: Int) -> Color {
        Color.primary.opacity([0, 0.06, 0.13, 0.22, 0.34][min(4, max(0, shade))])
    }

    private func lineLegend(_ title: String, color: Color, dashed: Bool = false) -> some View {
        Label {
            Text(title)
        } icon: {
            Canvas { context, size in
                var line = Path()
                line.move(to: CGPoint(x: 1, y: size.height / 2)); line.addLine(to: CGPoint(x: size.width - 8, y: size.height / 2))
                context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dashed ? [4, 3] : []))
                var head = Path()
                head.move(to: CGPoint(x: size.width, y: size.height / 2))
                head.addLine(to: CGPoint(x: size.width - 9, y: size.height / 2 - 4))
                head.addLine(to: CGPoint(x: size.width - 9, y: size.height / 2 + 4))
                head.closeSubpath()
                context.fill(head, with: .color(color))
            }
            .frame(width: 26, height: 10)
        }
    }

    // MARK: Graph

    private func circleOrder() -> [(id: UUID, depth: Int)] {
        var leaders: [UUID] = []
        var rings: [UUID: [UUID]] = [:]
        var ancestry: [UUID] = []
        for node in nodes {
            if ancestry.count > node.depth { ancestry.removeLast(ancestry.count - node.depth) }
            if node.isLeader {
                leaders.append(node.id)
                ancestry.append(node.id)
            } else if let leader = ancestry.last {
                rings[leader, default: []].append(node.id)
                ancestry.append(leader)
            }
        }
        return leaders.flatMap { leader in
            [(id: leader, depth: 0)] + (rings[leader] ?? []).map { (id: $0, depth: 1) }
        }
    }

    private func place(layout: SessionGroupGraph.Layout, moved: [UUID: CGSize]) -> Placement {
        guard layout.drawsNodes else {
            let content = SessionGroupGraph.matrixContent(count: nodes.count)
            return Placement(base: [:], points: [:], diameters: [:], content: content, leader: content.origin, topAligned: true)
        }
        let diameters = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.size(scope).diameter) })
        let spacing = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.size(.all).diameter) })
        let largest = spacing.values.max() ?? SessionGroupGraph.standardDiameter
        let order = layout == .circle && nodes.contains(where: { $0.isLeader && $0.depth > 0 })
            ? circleOrder() : nodes.map { (id: $0.id, depth: $0.depth) }
        let base: [UUID: CGPoint]
        if layout == .force, forceCache.ids == order.map(\.id), forceCache.depths == order.map(\.depth),
           forceCache.sizes == spacing, forceCache.edges == all {
            base = forceCache.points
        } else {
            let positions = SessionGroupGraph.positions(order, hasLeader: hasLeader, layout: layout, diameters: spacing, edges: all)
            base = SessionGroupGraph.frame(positions, largestDiameter: largest).points
            if layout == .force {
                forceCache.ids = order.map(\.id); forceCache.depths = order.map(\.depth)
                forceCache.sizes = spacing; forceCache.edges = all; forceCache.points = base
            }
        }
        var points = base
        for (id, offset) in moved { if let point = base[id] { points[id] = CGPoint(x: point.x + offset.width, y: point.y + offset.height) } }
        return Placement(base: base, points: points, diameters: diameters,
                         content: SessionGroupGraph.contentBounds(points, largestDiameter: largest),
                         leader: nodes.first.flatMap { points[$0.id] })
    }

    // MARK: Matrix

    /// The caption sizes at 100%, scaled with the zoom like the node names so text stays sharp.
    private static let captionSize = NSFont.preferredFont(forTextStyle: .caption1).pointSize
    private static let smallCaptionSize = NSFont.preferredFont(forTextStyle: .caption2).pointSize

    /// Row and column headers and one cell per sender and recipient pair, each drawn at the zoom
    /// and placed by the viewport like the nodes. The selected member's row and column keep full
    /// strength and the other cells fade.
    @ViewBuilder private func matrixGrid(_ edges: [SessionGroupGraph.Edge], view: SessionGroupGraph.Viewport,
                                         placement: Placement, size: CGSize) -> some View {
        let count = nodes.count
        let grid = SessionGroupGraph.matrix(order: nodes.map(\.id), edges: edges)
        let chosen = selection.flatMap { id in nodes.firstIndex { $0.id == id } }
        let current = Self.clamped(matrixCurrent, count: count)
        let spots: [SessionGroupGraph.MatrixSpot] = (0..<count).map { .columnHeader($0) } + (0..<count).map { .rowHeader($0) }
            + (0..<count).flatMap { row in (0..<count).map { .cell(row: row, column: $0) } }
        // Elements are placed by `position`, so the stack only groups them for accessibility.
        ZStack(alignment: .topLeading) {
            ForEach(spots, id: \.self) { spot in
                matrixItem(spot, grid: grid, chosen: chosen, current: current, view: view, placement: placement, size: size)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("인접 행렬. 행은 보낸 구성원, 열은 받은 구성원")
    }

    private static func clamped(_ spot: SessionGroupGraph.MatrixSpot, count: Int) -> SessionGroupGraph.MatrixSpot {
        let last = max(0, count - 1)
        switch spot {
        case let .rowHeader(row): return .rowHeader(min(row, last))
        case let .columnHeader(column): return .columnHeader(min(column, last))
        case let .cell(row, column): return .cell(row: min(row, last), column: min(column, last))
        }
    }

    private func matrixItem(_ spot: SessionGroupGraph.MatrixSpot, grid: [[SessionGroupGraph.MatrixCell]], chosen: Int?,
                            current: SessionGroupGraph.MatrixSpot, view: SessionGroupGraph.Viewport,
                            placement: Placement, size: CGSize) -> some View {
        let scale = CGFloat(view.scale)
        let rect = spot.rect()
        let origin = view.screen(rect.origin)
        let member: GraphNode
        let probeName: String, label: String, hint: String
        var selected = false, related = false, header = false
        var fill = Color.clear, border: Color?
        let content: AnyView
        switch spot {
        case let .rowHeader(row), let .columnHeader(row):
            let column: Bool = { if case .columnHeader = spot { return true }; return false }()
            member = nodes[row]
            header = true
            selected = chosen == row
            related = selected
            probeName = (column ? "col:" : "row:") + member.name
            label = "\(member.name), \(member.status.title), \(member.modelLabel)"
            hint = column ? "받은 메시지 열의 머리입니다. 누르면 이 구성원을 고릅니다." : "보낸 메시지 행의 머리입니다. 누르면 이 구성원을 고릅니다."
            let symbol = GraphNodeSymbol(agent: member.agent, status: member.status, role: member.isLeader ? .leader : .member, diameter: 18 * scale)
                .frame(width: 26 * scale, height: 26 * scale)
            let name = VStack(alignment: column ? .center : .leading, spacing: scale) {
                Text(member.name).lineLimit(1)
                Text(member.modelLabel).font(.system(size: 10 * scale)).foregroundStyle(.secondary).lineLimit(1)
            }
            .help(member.modelLabel)
                .font(.system(size: Self.captionSize * scale, weight: selected ? .semibold : .regular))
                .foregroundStyle(member.provisional ? .secondary : .primary)
                .truncationMode(.middle)
            content = column
                ? AnyView(VStack(spacing: 2 * scale) { symbol; name.lineLimit(2).multilineTextAlignment(.center) }
                    .padding(.horizontal, 3 * scale).padding(.bottom, 4 * scale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom))
                : AnyView(HStack(spacing: 4 * scale) { symbol; name.lineLimit(1) }
                    .padding(.horizontal, 6 * scale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading))
        case let .cell(row, column):
            let cell = grid[row][column]
            member = nodes[row]
            let recipient = nodes[column]
            selected = chosen == row
            related = chosen == row || chosen == column
            probeName = member.name + ">" + recipient.name
            label = SessionGroupGraph.matrixCellAccessibility(from: member.name, to: recipient.name, cell: cell)
            hint = "누르면 보낸 구성원 \(member.name)을 고릅니다."
            // The diagonal is crossed out instead of filled, so it never reads as a one-message shade.
            fill = cell.isSelf ? .clear : Self.matrixFill(cell.shade)
            border = cell.pendingQuestions > 0 ? .orange : nil
            content = AnyView(ZStack(alignment: .topTrailing) {
                if cell.isSelf {
                    Canvas { context, size in
                        var slash = Path()
                        slash.move(to: CGPoint(x: 0, y: size.height)); slash.addLine(to: CGPoint(x: size.width, y: 0))
                        context.stroke(slash, with: .color(Color(nsColor: .separatorColor)), lineWidth: 1)
                    }
                }
                Text(cell.count > 0 ? "\(cell.count)" : "")
                    .font(.system(size: Self.captionSize * scale).monospacedDigit())
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if cell.pendingQuestions > 0 {
                    Text("?\(cell.pendingQuestions)")
                        .font(.system(size: Self.smallCaptionSize * scale, weight: .bold))
                        .foregroundStyle(Color.orange)
                        .padding(.top, 4 * scale).padding(.trailing, 5 * scale)
                }
            })
        }
        let pressed = matrixPressed == spot && selected
        return GraphMatrixItem(fill: fill, tint: related ? Color.accentColor.opacity(header ? 0.16 : 0.08) : nil, border: border,
                               grid: !header, pressed: pressed, focused: matrixFocus == spot,
                               dimmed: chosen != nil && !header && !related, scale: scale, content: content)
            .frame(width: rect.width * scale, height: rect.height * scale)
            .accessibilityIdentifier(probeName)
            /* graph-probe: cell */
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityHint(hint)
            .accessibilityAddTraits(header ? (selected ? [.isHeader, .isButton, .isSelected] : [.isHeader, .isButton])
                                    : (selected ? [.isButton, .isSelected] : .isButton))
            .accessibilityAction { activate(spot, member: member.id) }
            .help(label + "\n" + hint)
            .focusable(spot == current)
            .focused($matrixFocus, equals: spot)
            .focusEffectDisabled()
            .onKeyPress(keys: [.space, .return]) { _ in activate(spot, member: member.id); return .handled }
            .onMoveCommand { direction in
                let step: SessionGroupGraph.MatrixDirection
                switch direction {
                case .left: step = .left
                case .right: step = .right
                case .up: step = .up
                case .down: step = .down
                @unknown default: return
                }
                let next = SessionGroupGraph.matrixMove(spot, step, count: nodes.count)
                guard next != spot else { return }
                matrixCurrent = next
                reveal(next.rect(), view: view, placement: placement, size: size)
                // The next element becomes focusable in this update and takes focus in the next one.
                DispatchQueue.main.async { matrixFocus = next }
            }
            .gesture(panGesture(view, placement, size) { activate(spot, member: member.id) })
            .position(x: origin.x + rect.width * scale / 2, y: origin.y + rect.height * scale / 2)
    }

    /// A header selects its member and a cell its sender.
    private func activate(_ spot: SessionGroupGraph.MatrixSpot, member: UUID) {
        selection = member
        matrixPressed = spot
        matrixCurrent = spot
    }

    /// Pans just enough that a matrix element moved to with the keyboard is inside the area.
    private func reveal(_ rect: CGRect, view: SessionGroupGraph.Viewport, placement: Placement, size: CGSize) {
        let shown = CGRect(origin: view.screen(rect.origin), size: CGSize(width: rect.width * view.scale, height: rect.height * view.scale))
        let area = CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8)
        func shift(_ low: CGFloat, _ high: CGFloat, _ areaLow: CGFloat, _ areaHigh: CGFloat) -> CGFloat {
            low < areaLow ? areaLow - low : high > areaHigh ? areaHigh - high : 0
        }
        let dx = shift(shown.minX, shown.maxX, area.minX, area.maxX), dy = shift(shown.minY, shown.maxY, area.minY, area.maxY)
        guard dx != 0 || dy != 0 else { return }
        adjust(view.panned(by: CGVector(dx: dx, dy: dy)), placement, size)
    }

    /// Room a line end keeps from a node whose warning or speech bubble mark sticks out.
    private func clearance(_ id: UUID, _ placement: Placement) -> Double {
        guard let status = nodes.first(where: { $0.id == id })?.status, status.blocked || status.needsResponse else { return 0 }
        return SessionGroupGraph.markClearance(radius: placement.radii[id] ?? SessionGroupGraph.nodeRadius)
    }

    private func draw(_ edges: [SessionGroupGraph.Edge], placement: Placement, bends: [SessionGroupGraph.EdgeKey: Double],
                      in context: inout GraphicsContext) {
        let points = placement.points, radii = placement.radii
        for edge in edges where !edge.touches(movingNode) {
            guard let from = points[edge.from], let to = points[edge.to],
                  let shape = SessionGroupGraph.geometry(from: from, to: to, width: edge.width, bend: bends[edge.key] ?? 1,
                                                         startClearance: clearance(edge.from, placement), endClearance: clearance(edge.to, placement),
                                                         startRadius: radii[edge.from] ?? SessionGroupGraph.nodeRadius,
                                                         endRadius: radii[edge.to] ?? SessionGroupGraph.nodeRadius) else { continue }
            let color = edge.kind == .pendingQuestion ? Color.orange : Self.gray
            var opacity = edge.faded ? 0.35 : 1
            if let selection, !edge.touches(selection) { opacity = min(opacity, 0.24) }
            var curve = Path()
            curve.move(to: shape.start)
            curve.addQuadCurve(to: shape.end, control: shape.control)
            if fresh.contains(edge.key) {
                context.stroke(curve, with: .color(Color.accentColor.opacity(0.35 * opacity)),
                               style: StrokeStyle(lineWidth: edge.width + 6, lineCap: .round))
            }
            context.stroke(curve, with: .color(color.opacity(opacity)),
                           style: StrokeStyle(lineWidth: edge.width, lineCap: edge.dashed ? .butt : .round, dash: edge.dashed ? [6, 4] : []))
            var head = Path()
            head.move(to: shape.tip); head.addLine(to: shape.headLeft); head.addLine(to: shape.headRight); head.closeSubpath()
            context.fill(head, with: .color(color.opacity(opacity)))
            if edge.pendingQuestions > 0 {
                let label = context.resolve(Text("?\(edge.pendingQuestions)").font(.caption2.weight(.bold)).foregroundStyle(Color.orange))
                let size = label.measure(in: CGSize(width: 80, height: 40))
                let rect = CGRect(x: shape.middle.x - size.width / 2 - 6, y: shape.middle.y - size.height / 2 - 2,
                                  width: size.width + 12, height: size.height + 4)
                var capsule = context
                capsule.opacity = opacity
                capsule.fill(Capsule().path(in: rect), with: .color(Color(nsColor: .windowBackgroundColor)))
                capsule.fill(Capsule().path(in: rect), with: .color(Color.orange.opacity(0.14)))
                capsule.stroke(Capsule().path(in: rect), with: .color(Color.orange), lineWidth: 1)
                capsule.draw(label, at: shape.middle)
            }
        }
    }

    /// `point` is in graph coordinates. Pointer movement is divided by the scale, so the node
    /// stays under the pointer at every zoom; the node is drawn at `view.screen(point)`.
    private func nodeView(_ node: GraphNode, at point: CGPoint, layout: SessionGroupGraph.Layout, placement: Placement,
                          view: SessionGroupGraph.Viewport, size: CGSize,
                          edges: [SessionGroupGraph.Edge], bends: [SessionGroupGraph.EdgeKey: Double], dimmed: Bool) -> some View {
        let selected = selection == node.id
        let scale = view.scale
        let shown = view.screen(point)
        let visible = view.visible(size)
        let diameter = CGFloat(placement.diameters[node.id] ?? SessionGroupGraph.standardDiameter)
        return GraphNodeView(node: node, selected: selected, dimmed: dimmed, lifted: movingNode == node.id, focused: focused == node.id,
                             scale: CGFloat(scale), diameter: diameter)
            .equatable()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(node.name), \(node.agent.title), \(node.isLeader ? "그룹장" : "구성원")")
            .accessibilityValue((node.role.map { $0 + ", " } ?? "") + node.modelLabel + ", " + (scope == .recent ? node.accessibilityRecent : node.accessibilityAll))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { selection = node.id }
            .accessibilityAction(named: Text("터미널 열기")) { openNode(node.id) }
            .focusable()
            .focused($focused, equals: node.id)
            .focusEffectDisabled()
            .onKeyPress(keys: [.space, .return]) { _ in selection = node.id; return .handled }
            .onMoveCommand { direction in
                // 16pt on screen at every zoom.
                let unit = 16 / scale
                let step: CGSize
                switch direction {
                case .left: step = CGSize(width: -unit, height: 0)
                case .right: step = CGSize(width: unit, height: 0)
                case .up: step = CGSize(width: 0, height: -unit)
                case .down: step = CGSize(width: 0, height: unit)
                @unknown default: return
                }
                move(node.id, to: clamp(CGPoint(x: point.x + step.width, y: point.y + step.height), in: visible),
                     layout: layout, placement: placement, view: view)
            }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                .updating($dragging) { _, state, _ in state = true }
                .onChanged { value in
                    let target = clamp(CGPoint(x: point.x + value.translation.width / scale, y: point.y + value.translation.height / scale), in: visible)
                    if preview.isActive { preview.move(to: target); return }
                    guard !preview.attempted, hypot(value.translation.width, value.translation.height) >= 4 else { return }
                    let incident = edges.filter { $0.touches(node.id) }.compactMap { edge -> ConversationDragPreview.Edge? in
                        let outgoing = edge.from == node.id
                        guard let anchor = placement.points[outgoing ? edge.to : edge.from] else { return nil }
                        let color = edge.kind == .pendingQuestion ? NSColor.systemOrange : NSColor.systemGray
                        return .init(anchor: anchor, outgoing: outgoing, color: color.withAlphaComponent(edge.faded ? 0.35 : 0.9),
                                     width: edge.width, bend: bends[edge.key] ?? 1, dashed: edge.dashed,
                                     startClearance: clearance(edge.from, placement), endClearance: clearance(edge.to, placement),
                                     startRadius: placement.radii[edge.from] ?? SessionGroupGraph.nodeRadius,
                                     endRadius: placement.radii[edge.to] ?? SessionGroupGraph.nodeRadius)
                    }
                    let lifted = GraphNodeView(node: node, selected: selected, dimmed: false, lifted: false, focused: false,
                                               scale: CGFloat(scale), diameter: diameter)
                        .padding(GraphNodeView.previewPadding * CGFloat(scale))
                        .environment(\.colorScheme, colorScheme)
                    if preview.begin(lifted, edges: incident, origin: point, at: target, view: view, diameter: diameter) { movingNode = node.id }
                }
                .onEnded { value in
                    let distance = hypot(value.translation.width, value.translation.height)
                    if distance < 4 && !preview.isActive {
                        selection = node.id
                    } else {
                        let start = preview.origin ?? point
                        move(node.id, to: clamp(CGPoint(x: start.x + value.translation.width / scale, y: start.y + value.translation.height / scale),
                                                in: visible),
                             layout: layout, placement: placement, view: view)
                    }
                    finishDrag()
                })
            .simultaneousGesture(TapGesture(count: 2).onEnded { openNode(node.id) })
            .help("\(node.name) · \(node.agent.title) · \(node.status.title)"
                  + (node.provisional ? "\n임시 이름입니다. 닉네임이 정해지면 바뀝니다." : "")
                  + (node.role.map { "\n" + $0 } ?? "") + "\n" + node.modelLabel + "\n주고받은 메시지 \(node.messages(scope))건(지금 보기 기준)"
                  + "\n클릭하면 세션 상태와 대화를 봅니다. 더블클릭하면 연결된 터미널을 엽니다. 끌거나 방향키를 누르면 노드를 옮깁니다.")
            .position(x: shown.x, y: shown.y + GraphNodeView.centerOffset * scale)
    }

    /// Keeps a moved node's circle and name band inside the visible part of the graph.
    private func clamp(_ point: CGPoint, in visible: CGRect) -> CGPoint {
        func limit(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { low > high ? (low + high) / 2 : min(high, max(low, value)) }
        return CGPoint(x: limit(point.x, visible.minX + 64, visible.maxX - 64), y: limit(point.y, visible.minY + 28, visible.maxY - 48))
    }

    /// Moving a node while the view is fitted keeps the current zoom and position, so the
    /// graph does not jump to fit the new bounds when the node is dropped.
    private func move(_ id: UUID, to point: CGPoint, layout: SessionGroupGraph.Layout, placement: Placement, view: SessionGroupGraph.Viewport) {
        guard let base = placement.base[id] else { return }
        if case .fitted = mode { mode = .manual(view) }
        offsets[layout, default: [:]][id] = CGSize(width: point.x - base.x, height: point.y - base.y)
    }

    private func finishDrag() {
        preview.end()
        if movingNode != nil { movingNode = nil }
    }
}

private struct ControlRowLayout: Layout {
    let spacing: CGFloat

    struct Cache {
        let pickers: CGSize
        let hints: CGSize
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(pickers: subviews[0].sizeThatFits(.unspecified), hints: subviews[1].sizeThatFits(.unspecified))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        CGSize(width: proposal.width ?? cache.pickers.width + spacing + cache.hints.width,
               height: max(cache.pickers.height, cache.hints.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(cache.pickers))
        let room = max(0, bounds.width - cache.pickers.width - spacing)
        subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(width: room, height: nil))
    }
}

private struct LegendGroupStart: LayoutValueKey {
    static let defaultValue = false
}

private struct LegendFlow: Layout {
    let groupSpacing: CGFloat
    let itemSpacing: CGFloat
    let lineSpacing: CGFloat

    struct Item {
        let size: CGSize
        let startsGroup: Bool
    }

    struct Row {
        var items: Range<Int>
        var width: CGFloat
        var height: CGFloat
    }

    func makeCache(subviews: Subviews) -> [Item] {
        subviews.map { Item(size: $0.sizeThatFits(.unspecified), startsGroup: $0[LegendGroupStart.self]) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout [Item]) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, items: cache)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout [Item]) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, items: cache) {
            var x = bounds.minX
            for index in row.items {
                let item = cache[index]
                if index != row.items.lowerBound { x += item.startsGroup ? groupSpacing : itemSpacing }
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2), proposal: ProposedViewSize(item.size))
                x += item.size.width
            }
            y += row.height + lineSpacing
        }
    }

    private func arrange(width: CGFloat, items: [Item]) -> [Row] {
        var rows: [Row] = []
        func groupWidth(from start: Int) -> CGFloat {
            var total = items[start].size.width
            for item in items[(start + 1)...] {
                if item.startsGroup { break }
                total += itemSpacing + item.size.width
            }
            return total
        }
        for (index, item) in items.enumerated() {
            let gap = item.startsGroup ? groupSpacing : itemSpacing
            if let last = rows.last, last.width + gap + item.size.width <= width {
                let group = item.startsGroup ? groupWidth(from: index) : item.size.width
                if group > width || last.width + gap + group <= width {
                    rows[rows.count - 1] = Row(items: last.items.lowerBound..<(index + 1),
                                               width: last.width + gap + item.size.width, height: max(last.height, item.size.height))
                    continue
                }
            }
            rows.append(Row(items: index..<(index + 1), width: item.size.width, height: item.size.height))
        }
        return rows
    }
}

/// One member's circle: the agent sets the color family, the state sets the shape.
private struct GraphNodeSymbol: View {
    enum Role { case leader, member }
    let agent: AgentKind
    let status: SessionGroupGraph.NodeStatus
    var role: Role? = nil
    var diameter: CGFloat = 32

    var body: some View {
        let color = agent.graphColor
        ZStack {
            switch status.shape {
            case .unknown:
                Circle().strokeBorder(color, style: StrokeStyle(lineWidth: max(1, diameter * 0.047), dash: [diameter * 0.125, diameter * 0.094]))
            case .idle:
                Circle().fill(color.opacity(0.25))
                Circle().strokeBorder(color, lineWidth: 1)
            case .working, .attention:
                Circle().fill(color.opacity(0.9))
            }
            if status.blocked { Circle().strokeBorder(Color.red, lineWidth: max(1.5, diameter / 16)) }
            if let role {
                Image(systemName: role == .leader ? "crown.fill" : "person.fill")
                    .font(.system(size: diameter * 0.375, weight: .semibold))
                    .foregroundStyle(status.filled ? Color.white : color)
            }
        }
        .frame(width: diameter, height: diameter)
        .overlay {
            // A still ring: working needs nothing from the user, so it does not move and
            // does not draw the eye away from members that need a response.
            if status.shape == .working {
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(color, style: StrokeStyle(lineWidth: max(1.2, diameter / 16), lineCap: .round))
                    .frame(width: diameter * 1.31, height: diameter * 1.31)
            }
        }
        .overlay(alignment: .topTrailing) {
            if status.blocked || status.shape == .attention {
                Image(systemName: status.blocked ? "exclamationmark.triangle.fill" : "bubble.left.fill")
                    .font(.system(size: max(5, diameter * 0.34), weight: .bold))
                    .foregroundStyle(status.blocked ? Color.red : color)
                    .padding(diameter * 0.05)
                    .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                    .offset(x: diameter * 0.16, y: -diameter * 0.16)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A node with its name band. Equatable, so a change elsewhere in the graph does not redraw it.
/// Sizes in the comments are at 100%; `scale` draws the circle, text and spacing at the zoom
/// itself, so names stay sharp instead of being a stretched bitmap. `diameter` is the circle
/// size from the member's message step.
private struct GraphNodeView: View, Equatable {
    static let width: CGFloat = 128
    /// The circle, a 6pt gap and the 20pt name band.
    static func height(diameter: CGFloat) -> CGFloat { diameter + CGFloat(SessionGroupGraph.nameBandDrop) }
    /// The circle centre is half a diameter below the top and the view centre half a height, so
    /// the view centre is always 13pt below the circle centre.
    static let centerOffset: CGFloat = CGFloat(SessionGroupGraph.nameBandDrop) / 2
    static let previewPadding: CGFloat = 8
    /// The caption text style's size, so the name at 100% is the same as before zooming existed.
    private static let nameSize = NSFont.preferredFont(forTextStyle: .caption1).pointSize
    let node: GraphNode
    let selected: Bool
    let dimmed: Bool
    let lifted: Bool
    let focused: Bool
    var scale: CGFloat = 1
    var diameter: CGFloat = 32
    @State private var hovering = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.node == rhs.node && lhs.selected == rhs.selected && lhs.dimmed == rhs.dimmed && lhs.lifted == rhs.lifted && lhs.focused == rhs.focused
            && lhs.scale == rhs.scale && lhs.diameter == rhs.diameter
    }

    var body: some View {
        VStack(spacing: node.role == nil ? 6 * scale : 0) {
            GraphNodeSymbol(agent: node.agent, status: node.status, role: node.isLeader ? .leader : .member, diameter: diameter * scale)
                .overlay {
                    if hovering && !selected { Circle().stroke(node.agent.graphColor, lineWidth: 1).padding(-8 * scale) }
                }
                .overlay {
                    if selected { Circle().stroke(Color.accentColor, lineWidth: 3).padding(-9 * scale) }
                }
                .overlay {
                    if focused { Circle().stroke(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3).padding((selected ? -13 : -9) * scale) }
                }
                .contentShape(Circle())
                .padding(.bottom, node.role == nil ? 0 : 2 * scale)
            Text(node.name)
                .font(.system(size: Self.nameSize * scale, weight: selected ? .semibold : .regular))
                .foregroundStyle(node.provisional ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 6 * scale).padding(.vertical, 2 * scale)
                .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
                .overlay(Capsule().strokeBorder(hovering ? node.agent.graphColor : Color(nsColor: .separatorColor), lineWidth: hovering ? 1 : 0.5))
                .frame(maxWidth: Self.width * scale)
                .contentShape(Capsule())
            if let role = node.role, !role.isEmpty {
                Text(role)
                    .font(.system(size: 11 * scale))
                    .lineLimit(1)
                    .help(role)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
            Text(node.modelLabel)
                .font(.system(size: 10 * scale))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 2 * scale)
                .background(Color(nsColor: .windowBackgroundColor))
                .help(node.modelLabel)
        }
        .frame(width: Self.width * scale, height: Self.height(diameter: diameter) * scale, alignment: .top)
        .opacity(lifted ? 0.15 : dimmed ? 0.24 : 1)
        .onHover { hovering = $0 }
        /* graph-probe: node */
    }
}

/// A matrix header or cell: a light fill on hover, an accent tint for the selected member's row,
/// column and headers, an accent outline on the element last pressed, an orange inner border for
/// waiting questions and the keyboard focus ring colour when focused.
private struct GraphMatrixItem: View {
    let fill: Color
    let tint: Color?
    let border: Color?
    /// Cells draw grid lines; headers do not.
    let grid: Bool
    let pressed: Bool
    let focused: Bool
    let dimmed: Bool
    let scale: CGFloat
    let content: AnyView
    @State private var hovering = false

    var body: some View {
        ZStack {
            Rectangle().fill(fill)
            if let tint { Rectangle().fill(tint) }
            if hovering { Rectangle().fill(Color.primary.opacity(0.06)) }
            content
        }
        .overlay { if grid { Rectangle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5) } }
        .overlay { if let border { Rectangle().strokeBorder(border, lineWidth: max(1, 1.5 * scale)).padding(2 * scale) } }
        .overlay { if hovering && !pressed { Rectangle().strokeBorder(Color.primary.opacity(0.45), lineWidth: 1) } }
        .overlay { if pressed { Rectangle().strokeBorder(Color.accentColor, lineWidth: 2) } }
        .overlay { if focused { Rectangle().strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3) } }
        .opacity(dimmed ? 0.3 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Two-finger scrolls and mouse wheels over the graph area pan it; with ⌘ held they zoom around
/// the pointer. A local event monitor reads them, so clicks and drags still reach the nodes.
@MainActor private struct ConversationScrollEvents: NSViewRepresentable {
    /// Scroll distance in points, the pointer in the graph area, and whether ⌘ is held.
    let action: (CGVector, CGPoint, Bool) -> Void
    /// Part of the graph area covered by controls; scrolls there are left alone.
    let excluded: CGRect

    init(excluded: CGRect = .null, _ action: @escaping (CGVector, CGPoint, Bool) -> Void) { self.excluded = excluded; self.action = action }

    func makeNSView(context: Context) -> EventView {
        let view = EventView()
        view.action = action
        view.excluded = excluded
        return view
    }

    func updateNSView(_ view: EventView, context: Context) { view.action = action; view.excluded = excluded }

    static func dismantleNSView(_ view: EventView, coordinator: ()) { view.stopMonitoring() }

    final class EventView: NSView {
        var action: ((CGVector, CGPoint, Bool) -> Void)?
        var excluded: CGRect = .null
        private var monitor: Any?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                // Local monitors run on the main thread while the app dispatches the event.
                nonisolated(unsafe) let scroll = event
                let handled = MainActor.assumeIsolated { self?.handle(scroll) == true }
                return handled ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, !isHiddenOrHasHiddenAncestor, let action else { return false }
            let pointer = convert(event.locationInWindow, from: nil)
            guard bounds.contains(pointer), !excluded.contains(pointer) else { return false }
            // A mouse wheel reports lines; about 10pt each.
            let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            let delta = CGVector(dx: event.scrollingDeltaX * factor, dy: event.scrollingDeltaY * factor)
            if event.modifierFlags.contains(.command) {
                // Wheel away from the user zooms in, whatever the natural scrolling setting.
                let away = event.isDirectionInvertedFromDevice ? -delta.dy : delta.dy
                action(CGVector(dx: 0, dy: away), pointer, true)
            } else {
                action(delta, pointer, false)
            }
            return true
        }
    }
}

/// The zoom buttons: no bezel at rest, a light fill on hover, a darker one while pressed, the
/// keyboard focus ring colour when focused, and faded text when disabled.
private struct GraphZoomButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { ZoomButton(configuration: configuration) }

    private struct ZoomButton: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
            configuration.label
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.5))
                .padding(.horizontal, 5)
                .frame(minWidth: 22, minHeight: 20)
                .background(shape.fill(Color.primary.opacity(!enabled ? 0 : configuration.isPressed ? 0.16 : hovering ? 0.08 : 0)))
                .overlay { if focused { shape.stroke(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3).padding(-1) } }
                .contentShape(shape)
                .onHover { hovering = $0 }
        }
    }
}

@MainActor private struct ConversationDragSurface: NSViewRepresentable {
    let preview: ConversationDragPreview

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        preview.surface = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// The canvas and SwiftUI controls keep their layout while the pointer is held.
/// Core Animation presents the lifted node and its incident lines at display cadence.
/// Points are in graph coordinates; the zoom and pan at the start of the drag place them
/// in the graph area, and the surface layer covers that area.
@MainActor private final class ConversationDragPreview: NSObject {
    struct Edge {
        let anchor: CGPoint
        let outgoing: Bool
        let color: NSColor
        let width: CGFloat
        let bend: CGFloat
        let dashed: Bool
        let startClearance: Double
        let endClearance: Double
        let startRadius: Double
        let endRadius: Double
    }

    weak var surface: NSView?
    /// The node's centre when the drag began; nil when no node is lifted.
    private(set) var origin: CGPoint?
    /// One attempt per press, so a failed snapshot is not retried on every pointer event.
    private(set) var attempted = false
    var isActive: Bool { origin != nil }
    private let node = CALayer()
    private var edges: [(edge: Edge, line: CAShapeLayer, head: CAShapeLayer)] = []
    private var displayLink: CADisplayLink?
    private var pending: CGPoint?
    private var transform = SessionGroupGraph.Viewport.identity

    func begin(_ label: some View, edges incident: [Edge], origin: CGPoint, at point: CGPoint, view: SessionGroupGraph.Viewport,
               diameter: CGFloat) -> Bool {
        end()
        attempted = true
        guard let surface, let root = surface.layer else { return false }
        transform = view
        let scale = CGFloat(view.scale)
        let backing = surface.window?.backingScaleFactor ?? 1
        // The label is already drawn at the zoom, so the lifted node matches the nodes around it.
        let renderer = ImageRenderer(content: label)
        renderer.scale = backing
        guard let image = renderer.cgImage else { return false }
        withoutAnimations {
            for edge in incident {
                let line = CAShapeLayer(), head = CAShapeLayer()
                for layer in [line, head] { layer.frame = root.bounds; root.addSublayer(layer) }
                line.fillColor = nil
                line.strokeColor = edge.color.cgColor
                line.lineWidth = edge.width * scale
                line.lineCap = edge.dashed ? .butt : .round
                line.lineDashPattern = edge.dashed ? [NSNumber(value: 6 * scale), NSNumber(value: 4 * scale)] : nil
                head.fillColor = edge.color.cgColor
                head.strokeColor = nil
                edges.append((edge, line, head))
            }
            node.contents = image
            node.contentsScale = backing
            node.bounds.size = CGSize(width: CGFloat(image.width) / backing, height: CGFloat(image.height) / backing)
            node.shadowColor = NSColor.black.cgColor
            node.shadowOpacity = 0.24
            node.shadowRadius = 4
            node.shadowOffset = CGSize(width: 0, height: -2)
            let circleCenter = node.bounds.height - (GraphNodeView.previewPadding + diameter / 2) * scale
            let shadow = (diameter / 2 + 2) * scale
            node.shadowPath = CGPath(ellipseIn: CGRect(x: node.bounds.midX - shadow, y: circleCenter - shadow,
                                                       width: 2 * shadow, height: 2 * shadow), transform: nil)
            root.addSublayer(node)
            present(point, height: surface.bounds.height)
        }
        self.origin = origin
        // A display link created or resumed inside a SwiftUI gesture callback never fires.
        // Create it on the next turn of the main run loop and keep it running until the drag ends.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive, self.displayLink == nil, let surface = self.surface else { return }
            let link = surface.displayLink(target: self, selector: #selector(self.displayFrame))
            link.add(to: .main, forMode: .common)
            self.displayLink = link
        }
        return true
    }

    func move(to point: CGPoint) {
        guard node.superlayer != nil else { return }
        pending = point
    }

    func end() {
        displayLink?.invalidate()
        displayLink = nil
        pending = nil
        origin = nil
        attempted = false
        withoutAnimations {
            for item in edges { item.line.removeFromSuperlayer(); item.head.removeFromSuperlayer() }
            edges.removeAll()
            node.removeFromSuperlayer()
            node.contents = nil
        }
    }

    @objc private func displayFrame() {
        guard let point = pending, let surface else { return }
        pending = nil
        withoutAnimations { present(point, height: surface.bounds.height) }
        /* graph-probe: preview */
    }

    /// The surface layer's origin is at the bottom left of the graph area, so graph y grows downward
    /// after the zoom and pan are applied.
    private func present(_ point: CGPoint, height: CGFloat) {
        let scale = CGFloat(transform.scale)
        let shown = transform.screen(point)
        node.position = CGPoint(x: shown.x, y: height - shown.y - GraphNodeView.centerOffset * scale)
        var flip = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: transform.offset.x, ty: height - transform.offset.y)
        for (edge, line, head) in edges {
            let from = edge.outgoing ? point : edge.anchor
            let to = edge.outgoing ? edge.anchor : point
            guard let shape = SessionGroupGraph.geometry(from: from, to: to, width: edge.width, bend: edge.bend,
                                                         startClearance: edge.startClearance, endClearance: edge.endClearance,
                                                         startRadius: edge.startRadius, endRadius: edge.endRadius) else {
                line.path = nil; head.path = nil; continue
            }
            let curve = CGMutablePath()
            curve.move(to: shape.start)
            curve.addQuadCurve(to: shape.end, control: shape.control)
            line.path = curve.copy(using: &flip)
            let arrow = CGMutablePath()
            arrow.addLines(between: [shape.tip, shape.headLeft, shape.headRight])
            arrow.closeSubpath()
            head.path = arrow.copy(using: &flip)
        }
    }

    private func withoutAnimations(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }
}
