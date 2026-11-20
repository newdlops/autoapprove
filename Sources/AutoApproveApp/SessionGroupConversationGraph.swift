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
    @State private var replyTarget: SessionGroupConversation?
    @State private var deliveryTarget: SessionGroupConversation?
    @State private var deliveringQuestion: UUID?
    @State private var deliveryFeedback: String?
    @State private var alert: GraphAlert?
    @State private var requestingNicknames = false
    @State private var nicknameNote: String?
    private let initialScope: SessionGroupGraph.Scope
    private let forcedLayout: SessionGroupGraph.Layout?

    private struct GraphAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    /// `sources`, `initialScope` and `layout` exist for the render harness; the app uses the defaults.
    init(groupID: UUID, engine: ApprovalEngine, sources: ConversationGraphModel.Sources? = nil, initialSelection: UUID? = nil,
         initialScope: SessionGroupGraph.Scope = .recent, layout: SessionGroupGraph.Layout? = nil) {
        self.groupID = groupID
        self.engine = engine
        self.initialScope = initialScope
        forcedLayout = layout
        _selected = State(initialValue: initialSelection)
        _model = StateObject(wrappedValue: ConversationGraphModel(groupID: groupID, directory: engine.paths.directory,
                                                                 sources: sources ?? .live(engine)))
    }

    var body: some View {
        let content = model.content
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
                        .help("질문 전달 결과 표시를 닫습니다.")
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
            }
            if let content {
                if content.group.members.isEmpty {
                    ContentUnavailableView("구성원이 없습니다", systemImage: "person.2")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(spacing: 0) {
                        ConversationGraphCanvas(nodes: content.nodes, recent: content.recentEdges, all: content.allEdges,
                                                fresh: model.freshEdges, hasLeader: !content.group.leaderMemberIDs.isEmpty,
                                                selection: $selected, initialScope: initialScope, forcedLayout: forcedLayout)
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
            guard viewUpdates.isVisible else { return }
            await model.observe()
        }
        .onExitCommand { selected = nil }
        .onChange(of: content?.group.members.map(\.id)) { _, ids in
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

    private func requestNicknames(_ members: [UUID]) {
        guard !requestingNicknames else { return }
        requestingNicknames = true
        nicknameNote = nil
        Task {
            defer { requestingNicknames = false; model.reload() }
            do {
                let sent = try engine.requestSessionGroupNicknames(groupID: groupID, memberIDs: members)
                nicknameNote = sent == 0 ? "이미 요청한 구성원입니다" : "닉네임 정하기를 요청했습니다"
            } catch { alert = GraphAlert(title: "닉네임 정하기를 요청하지 못했습니다", message: error.localizedDescription) }
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
        let provisional = content.provisionalMembers
        return VStack(alignment: .leading, spacing: 8) {
            Text("구성원을 고르면 대화 기록을 봅니다")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.top, 12)
            if !provisional.isEmpty {
                HStack(spacing: 8) {
                    Button("닉네임 정하기 요청") { requestNicknames(provisional) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(requestingNicknames)
                        .help(requestingNicknames ? "요청을 저장하고 있습니다."
                              : "임시 이름(작업 폴더 · 순번)으로 보이는 구성원 \(provisional.count)명의 이름을 정해 달라고 한 번 요청합니다. 그룹장이 있으면 그룹장에게, 없으면 각 구성원에게 보냅니다.")
                    if let nicknameNote {
                        Text(nicknameNote).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
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
                    Text(node.status.title).foregroundStyle(statusColor(node.status))
                    Text("\(node.agent.title) · \(node.isLeader ? "그룹장" : "구성원")")
                        .font(.caption).foregroundStyle(.secondary)
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
            valueRow("대화 연결", operation.phase.map { "대화 확인 · " + SessionGroupGraph.detailTitle($0) } ?? "대화 미확인")
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
            if item.answer == nil, content.group.members.contains(where: { $0.id == peer }) {
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
        let kind = item.kind == .report ? "보고" : item.kind == .reply ? "답변" : item.kind == .choiceQuestion ? "선택 질문" : "메시지"
        return DisclosureGroup {
            message(kind, item)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(time(item.createdAt) + (outgoing ? " 보냄 → " : " 받음 ← ") + content.name(peer) + " · " + kind + " · " + delivery(item))
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
        case .shell: .gray
        }
    }
}

// MARK: - Graph area

/// Controls, legend and the graph. Drag state, moved positions, focus and the view choice
/// live here only, so moving a node never recomputes the window around it.
@MainActor private struct ConversationGraphCanvas: View {
    let nodes: [GraphNode]
    let recent: [SessionGroupGraph.Edge]
    let all: [SessionGroupGraph.Edge]
    let fresh: Set<SessionGroupGraph.EdgeKey>
    let hasLeader: Bool
    @Binding var selection: UUID?
    let forcedLayout: SessionGroupGraph.Layout?
    @AppStorage("sessionGroupGraph.layout") private var storedLayout: SessionGroupGraph.Layout = .tree
    @State private var scope: SessionGroupGraph.Scope
    /// Moved positions per layout, kept in memory until the window closes.
    @State private var offsets: [SessionGroupGraph.Layout: [UUID: CGSize]] = [:]
    @State private var movingNode: UUID?
    @State private var preview = ConversationDragPreview()
    @GestureState private var dragging = false
    @FocusState private var focused: UUID?
    @Environment(\.colorScheme) private var colorScheme

    private static let space = "conversationCanvas"

    init(nodes: [GraphNode], recent: [SessionGroupGraph.Edge], all: [SessionGroupGraph.Edge], fresh: Set<SessionGroupGraph.EdgeKey>,
         hasLeader: Bool, selection: Binding<UUID?>, initialScope: SessionGroupGraph.Scope, forcedLayout: SessionGroupGraph.Layout?) {
        self.nodes = nodes; self.recent = recent; self.all = all; self.fresh = fresh; self.hasLeader = hasLeader
        _selection = selection
        self.forcedLayout = forcedLayout
        _scope = State(initialValue: initialScope)
    }

    private struct Placement {
        let base: [UUID: CGPoint]
        let points: [UUID: CGPoint]
        let size: CGSize
    }

    var body: some View {
        let layout = forcedLayout ?? storedLayout
        let edges = scope == .recent ? recent : all
        let moved = offsets[layout] ?? [:]
        let frame = SessionGroupGraph.frame(SessionGroupGraph.positions(nodes.map { (id: $0.id, depth: $0.depth) },
                                                                        hasLeader: hasLeader, layout: layout))
        VStack(alignment: .leading, spacing: 0) {
            controls(layout: layout, moved: !moved.isEmpty)
            // The hidden full legend reserves the height, so a state or line kind appearing
            // never pushes the graph down and the nodes keep their places.
            ZStack(alignment: .topLeading) {
                legend(edges, everything: true).hidden().accessibilityHidden(true)
                legend(edges, everything: false)
            }
            Divider()
            GeometryReader { proxy in
                let placement = place(frame, moved: moved, viewport: proxy.size)
                let bends = SessionGroupGraph.bends(edges, points: placement.points)
                let related = selection.map { chosen in Set(edges.filter { $0.touches(chosen) }.flatMap { [$0.from, $0.to] }).union([chosen]) }
                let leader = nodes.first.flatMap { placement.points[$0.id] } ?? .zero
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { selection = nil; focused = nil }
                            .accessibilityHidden(true)
                        Canvas { context, _ in
                            draw(edges, points: placement.points, bends: bends, in: &context)
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        ForEach(nodes) { node in
                            if let point = placement.points[node.id] {
                                nodeView(node, at: point, layout: layout, placement: placement, edges: edges, bends: bends,
                                         dimmed: related.map { !$0.contains(node.id) } ?? false)
                            }
                        }
                    }
                    .frame(width: placement.size.width, height: placement.size.height)
                    .overlay { ConversationDragSurface(preview: preview).allowsHitTesting(false).accessibilityHidden(true) }
                    .coordinateSpace(name: Self.space)
                }
                // The leader's share of the content width and height lines up with the same share of
                // the viewport, so a graph larger than the window first opens with the leader in view.
                .defaultScrollAnchor(UnitPoint(x: leader.x / max(1, placement.size.width), y: leader.y / max(1, placement.size.height)))
                .overlay(alignment: .topLeading) {
                    if scope == .recent && edges.isEmpty {
                        Text("최근 30분 동안 오간 메시지가 없습니다")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 16).padding(.top, 8)
                    }
                }
            }
        }
        .onChange(of: dragging) { _, active in
            if !active, preview.isActive { finishDrag() }
        }
        .onDisappear { if preview.isActive { finishDrag() } }
    }

    // MARK: Controls and legend

    private func controls(layout: SessionGroupGraph.Layout, moved: Bool) -> some View {
        let pickers = HStack(spacing: 12) {
            Picker("보기", selection: $scope) {
                Text("최근").tag(SessionGroupGraph.Scope.recent)
                Text("전체").tag(SessionGroupGraph.Scope.all)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("최근은 답을 기다리는 질문과 최근 30분 동안 오간 메시지를 그립니다. 전체는 지난 기록과 만료된 질문을 흐리게 함께 그립니다.")
            Picker("배치", selection: Binding(get: { layout }, set: { storedLayout = $0 })) {
                Text("트리").tag(SessionGroupGraph.Layout.tree)
                Text("원형").tag(SessionGroupGraph.Layout.circle)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("트리는 그룹장을 맨 위에, 구성원을 상위 구성원 아래 층에 놓습니다. 원형은 그룹장을 가운데에, 나머지를 트리 순서대로 둘레에 놓습니다. 고른 배치는 다음에 열 때도 유지합니다.")
            // Shown only while a node is moved, so a link never sits there unclickable. It keeps
            // its width while hidden, so the row does not shift when it appears.
            Button("자동 배치로") { offsets[layout] = nil }
                .buttonStyle(.link)
                .disabled(!moved)
                .opacity(moved ? 1 : 0)
                .accessibilityHidden(!moved)
                .help("직접 옮긴 노드를 자동 배치 위치로 되돌립니다.")
        }
        .controlSize(.small)
        let hints = HStack(spacing: 12) {
            Text("노드를 드래그해 이동")
                .help("노드를 누른 채 끌면 연결선이 따라옵니다. 클릭하면 해당 구성원의 대화를 봅니다. 옮긴 위치는 창을 닫으면 자동 배치로 돌아갑니다.")
            Label("발신 → 수신", systemImage: "arrow.right")
                .help("화살표는 수신 구성원을 가리킵니다. 두 구성원이 서로 주고받으면 방향마다 선을 하나씩 그립니다.")
        }
        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { pickers; Spacer(minLength: 12); hints }
            HStack(spacing: 12) { pickers; Spacer(minLength: 0) }
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
    }

    /// Only the agents, states and line kinds on screen, then the width steps.
    private func legend(_ edges: [SessionGroupGraph.Edge], everything: Bool) -> some View {
        let agents = [AgentKind.claude, .codex, .shell].filter { agent in nodes.contains { $0.agent == agent } }
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
        let lines = lineKinds.filter { kinds.contains($0.0) }.map { ($0.1, $0.2, $0.3) }
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
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private static let gray = Color(nsColor: .systemGray)

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

    /// Centred when smaller than the viewport; never compressed. A moved node can widen the canvas.
    private func place(_ frame: SessionGroupGraph.Frame, moved: [UUID: CGSize], viewport: CGSize) -> Placement {
        let inset = CGSize(width: max(0, (viewport.width - frame.size.width) / 2), height: max(0, (viewport.height - frame.size.height) / 2))
        let base = frame.points.mapValues { CGPoint(x: $0.x + inset.width, y: $0.y + inset.height) }
        var points = base
        for (id, offset) in moved { if let point = base[id] { points[id] = CGPoint(x: point.x + offset.width, y: point.y + offset.height) } }
        var size = CGSize(width: max(frame.size.width, viewport.width), height: max(frame.size.height, viewport.height))
        for point in points.values {
            size.width = max(size.width, point.x + SessionGroupGraph.horizontalMargin)
            size.height = max(size.height, point.y + SessionGroupGraph.bottomMargin)
        }
        return Placement(base: base, points: points, size: size)
    }

    /// Room a line end keeps from a node whose warning or speech bubble mark sticks out.
    private func clearance(_ id: UUID) -> Double {
        guard let status = nodes.first(where: { $0.id == id })?.status, status.blocked || status.needsResponse else { return 0 }
        return SessionGroupGraph.markClearance
    }

    private func draw(_ edges: [SessionGroupGraph.Edge], points: [UUID: CGPoint], bends: [SessionGroupGraph.EdgeKey: Double],
                      in context: inout GraphicsContext) {
        for edge in edges where !edge.touches(movingNode) {
            guard let from = points[edge.from], let to = points[edge.to],
                  let shape = SessionGroupGraph.geometry(from: from, to: to, width: edge.width, bend: bends[edge.key] ?? 1,
                                                         startClearance: clearance(edge.from), endClearance: clearance(edge.to)) else { continue }
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

    private func nodeView(_ node: GraphNode, at point: CGPoint, layout: SessionGroupGraph.Layout, placement: Placement,
                          edges: [SessionGroupGraph.Edge], bends: [SessionGroupGraph.EdgeKey: Double], dimmed: Bool) -> some View {
        let selected = selection == node.id
        return GraphNodeView(node: node, selected: selected, dimmed: dimmed, lifted: movingNode == node.id, focused: focused == node.id)
            .equatable()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(node.name), \(node.agent.title), \(node.isLeader ? "그룹장" : "구성원")")
            .accessibilityValue(scope == .recent ? node.accessibilityRecent : node.accessibilityAll)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { selection = node.id }
            .focusable()
            .focused($focused, equals: node.id)
            .focusEffectDisabled()
            .onKeyPress(keys: [.space, .return]) { _ in selection = node.id; return .handled }
            .onMoveCommand { direction in
                let step: CGSize
                switch direction {
                case .left: step = CGSize(width: -16, height: 0)
                case .right: step = CGSize(width: 16, height: 0)
                case .up: step = CGSize(width: 0, height: -16)
                case .down: step = CGSize(width: 0, height: 16)
                @unknown default: return
                }
                move(node.id, to: clamp(CGPoint(x: point.x + step.width, y: point.y + step.height), in: placement.size), layout: layout, placement: placement)
            }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                .updating($dragging) { _, state, _ in state = true }
                .onChanged { value in
                    let target = clamp(CGPoint(x: point.x + value.translation.width, y: point.y + value.translation.height), in: placement.size)
                    if preview.isActive { preview.move(to: target); return }
                    guard !preview.attempted, hypot(value.translation.width, value.translation.height) >= 4 else { return }
                    let incident = edges.filter { $0.touches(node.id) }.compactMap { edge -> ConversationDragPreview.Edge? in
                        let outgoing = edge.from == node.id
                        guard let anchor = placement.points[outgoing ? edge.to : edge.from] else { return nil }
                        let color = edge.kind == .pendingQuestion ? NSColor.systemOrange : NSColor.systemGray
                        return .init(anchor: anchor, outgoing: outgoing, color: color.withAlphaComponent(edge.faded ? 0.35 : 0.9),
                                     width: edge.width, bend: bends[edge.key] ?? 1, dashed: edge.dashed,
                                     startClearance: clearance(edge.from), endClearance: clearance(edge.to))
                    }
                    let lifted = GraphNodeView(node: node, selected: selected, dimmed: false, lifted: false, focused: false)
                        .padding(GraphNodeView.previewPadding)
                        .environment(\.colorScheme, colorScheme)
                    if preview.begin(lifted, edges: incident, origin: point, at: target) { movingNode = node.id }
                }
                .onEnded { value in
                    let distance = hypot(value.translation.width, value.translation.height)
                    if distance < 4 && !preview.isActive {
                        selection = node.id
                    } else {
                        let start = preview.origin ?? point
                        move(node.id, to: clamp(CGPoint(x: start.x + value.translation.width, y: start.y + value.translation.height), in: placement.size),
                             layout: layout, placement: placement)
                    }
                    finishDrag()
                })
            .help("\(node.name) · \(node.agent.title) · \(node.status.title)"
                  + (node.provisional ? "\n임시 이름입니다. 닉네임이 정해지면 바뀝니다." : "")
                  + "\n클릭하면 세션 상태와 대화를 엽니다. 끌거나 방향키를 누르면 노드를 옮깁니다.")
            .position(x: point.x, y: point.y + GraphNodeView.centerOffset)
    }

    private func clamp(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: min(size.width - 64, max(64, point.x)), y: min(size.height - 48, max(28, point.y)))
    }

    private func move(_ id: UUID, to point: CGPoint, layout: SessionGroupGraph.Layout, placement: Placement) {
        guard let base = placement.base[id] else { return }
        offsets[layout, default: [:]][id] = CGSize(width: point.x - base.x, height: point.y - base.y)
    }

    private func finishDrag() {
        preview.end()
        if movingNode != nil { movingNode = nil }
    }
}

/// Marks the first legend item of a group (agents, states, line kinds, widths).
private struct LegendGroupStart: LayoutValueKey {
    static let defaultValue = false
}

/// Places legend items left to right and wraps them onto the next line when the row is full.
/// A group's first item keeps `groupSpacing` before it, other items `itemSpacing`.
private struct LegendFlow: Layout {
    let groupSpacing: CGFloat
    let itemSpacing: CGFloat
    let lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for (position, index) in row.items.enumerated() {
                if position > 0 { x += spacing(before: index, subviews: subviews) }
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width
            }
            y += row.height + lineSpacing
        }
    }

    private func spacing(before index: Int, subviews: Subviews) -> CGFloat {
        subviews[index][LegendGroupStart.self] ? groupSpacing : itemSpacing
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        // A group moves to the next line as a whole when it fits there but not in the rest of
        // this line; only a group wider than a whole line wraps between its own items.
        func groupWidth(from start: Int) -> CGFloat {
            var total = subviews[start].sizeThatFits(.unspecified).width, index = start + 1
            while index < subviews.count, !subviews[index][LegendGroupStart.self] {
                total += itemSpacing + subviews[index].sizeThatFits(.unspecified).width; index += 1
            }
            return total
        }
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let gap = spacing(before: index, subviews: subviews)
            if let last = rows.last, subviews[index][LegendGroupStart.self] {
                let group = groupWidth(from: index)
                if last.width + gap + group > width, group <= width {
                    rows.append(([index], size.width, size.height)); continue
                }
            }
            if var last = rows.last, last.width + gap + size.width <= width {
                last.items.append(index); last.width += gap + size.width; last.height = max(last.height, size.height)
                rows[rows.count - 1] = last
            } else {
                rows.append(([index], size.width, size.height))
            }
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
private struct GraphNodeView: View, Equatable {
    static let width: CGFloat = 128
    static let height: CGFloat = 58
    /// The circle centre is 16pt below the top; the view centre is 29pt below it.
    static let centerOffset: CGFloat = 13
    static let previewPadding: CGFloat = 8
    let node: GraphNode
    let selected: Bool
    let dimmed: Bool
    let lifted: Bool
    let focused: Bool
    @State private var hovering = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.node == rhs.node && lhs.selected == rhs.selected && lhs.dimmed == rhs.dimmed && lhs.lifted == rhs.lifted && lhs.focused == rhs.focused
    }

    var body: some View {
        VStack(spacing: 6) {
            GraphNodeSymbol(agent: node.agent, status: node.status, role: node.isLeader ? .leader : .member)
                .overlay {
                    if hovering && !selected { Circle().stroke(node.agent.graphColor, lineWidth: 1).padding(-8) }
                }
                .overlay {
                    if selected { Circle().stroke(Color.accentColor, lineWidth: 3).padding(-9) }
                }
                .overlay {
                    if focused { Circle().stroke(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3).padding(selected ? -13 : -9) }
                }
                .contentShape(Circle())
            Text(node.name)
                .font(.caption.weight(selected ? .semibold : .regular))
                .foregroundStyle(node.provisional ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
                .overlay(Capsule().strokeBorder(hovering ? node.agent.graphColor : Color(nsColor: .separatorColor), lineWidth: hovering ? 1 : 0.5))
                .frame(maxWidth: Self.width)
                .contentShape(Capsule())
        }
        .frame(width: Self.width, height: Self.height, alignment: .top)
        .opacity(lifted ? 0.15 : dimmed ? 0.24 : 1)
        .onHover { hovering = $0 }
        /* graph-probe: node */
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

    func begin(_ label: some View, edges incident: [Edge], origin: CGPoint, at point: CGPoint) -> Bool {
        end()
        attempted = true
        guard let surface, let root = surface.layer else { return false }
        let renderer = ImageRenderer(content: label)
        renderer.scale = surface.window?.backingScaleFactor ?? 1
        guard let image = renderer.cgImage else { return false }
        withoutAnimations {
            for edge in incident {
                let line = CAShapeLayer(), head = CAShapeLayer()
                for layer in [line, head] { layer.frame = root.bounds; root.addSublayer(layer) }
                line.fillColor = nil
                line.strokeColor = edge.color.cgColor
                line.lineWidth = edge.width
                line.lineCap = edge.dashed ? .butt : .round
                line.lineDashPattern = edge.dashed ? [6, 4] : nil
                head.fillColor = edge.color.cgColor
                head.strokeColor = nil
                edges.append((edge, line, head))
            }
            node.contents = image
            node.contentsScale = renderer.scale
            node.bounds.size = CGSize(width: CGFloat(image.width) / renderer.scale, height: CGFloat(image.height) / renderer.scale)
            node.shadowColor = NSColor.black.cgColor
            node.shadowOpacity = 0.24
            node.shadowRadius = 4
            node.shadowOffset = CGSize(width: 0, height: -2)
            let circleCenter = node.bounds.height - GraphNodeView.previewPadding - 16
            node.shadowPath = CGPath(ellipseIn: CGRect(x: node.bounds.midX - 18, y: circleCenter - 18, width: 36, height: 36), transform: nil)
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
    }

    private func present(_ point: CGPoint, height: CGFloat) {
        node.position = CGPoint(x: point.x, y: height - point.y - GraphNodeView.centerOffset)
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
        for (edge, line, head) in edges {
            let from = edge.outgoing ? point : edge.anchor
            let to = edge.outgoing ? edge.anchor : point
            guard let shape = SessionGroupGraph.geometry(from: from, to: to, width: edge.width, bend: edge.bend,
                                                         startClearance: edge.startClearance, endClearance: edge.endClearance) else {
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
