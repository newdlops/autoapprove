import SwiftUI
import QuartzCore
import AutoApproveCore

@MainActor struct SessionGroupConversationGraph: View {
    let groupID: UUID
    let engine: ApprovalEngine
    @State private var group: SessionGroup?
    @State private var page: SessionGroupConversationPage?
    @State private var operations: [UUID: SessionGroupMemberOperation] = [:]
    @State private var error: String?
    @State private var selected: UUID?
    @State private var onlyPending = false
    @State private var replyTarget: SessionGroupConversation?
    @State private var deliveryTarget: SessionGroupConversation?
    @State private var deliveringQuestion: UUID?
    @State private var deliveryFeedback: String?
    @State private var deliveryError: String?
    @State private var movedNodes: [UUID: CGPoint] = [:]
    @State private var isDraggingNode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("대화 그래프").font(.title2.weight(.semibold))
                    if let group { Text(group.name).foregroundStyle(.secondary).lineLimit(1).help(group.name) }
                }
                Spacer()
                Picker("그래프에 표시할 질문", selection: $onlyPending) {
                    Text("미응답").tag(true)
                    Text("전체").tag(false)
                }
                .labelsHidden()
                .accessibilityLabel("그래프에 표시할 질문")
                .pickerStyle(.segmented)
                .frame(width: 160)
                .help("미응답은 답변을 기다리는 질문의 연결만 표시합니다. 전체는 저장된 대화의 연결을 모두 표시합니다.")
                Button("새로고침", systemImage: "arrow.clockwise", action: refresh)
                    .labelStyle(.iconOnly)
                    .help("로컬에 저장된 그룹 메시지와 질문·답변의 전달 상태를 다시 읽습니다.")
            }
            .padding(16)
            Divider()
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).padding(12)
                Divider()
            }
            if let deliveryFeedback {
                HStack {
                    Label(deliveryFeedback, systemImage: "checkmark.circle")
                    Spacer()
                    Button("닫기", systemImage: "xmark") { self.deliveryFeedback = nil }
                        .labelStyle(.iconOnly)
                        .help("질문 전달 결과 표시를 닫습니다.")
                }
                .font(.caption).foregroundStyle(.secondary).padding(12)
                Divider()
            }
            if let page, let group {
                if group.members.isEmpty {
                    ContentUnavailableView("구성원이 없습니다", systemImage: "person.2")
                } else {
                    operationSummary(group)
                    Divider()
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Label("발신 → 수신", systemImage: "arrow.right")
                                        .help("화살표는 수신 구성원을 가리킵니다. 양끝의 화살표는 두 구성원이 서로 메시지를 주고받았다는 뜻입니다.")
                                    Text("노드를 드래그해 이동")
                                        .help("노드를 누른 채 끌면 연결선이 따라옵니다. 클릭하면 해당 구성원의 대화를 봅니다.")
                                    Spacer()
                                    Button("배치 초기화", systemImage: "arrow.counterclockwise") { movedNodes.removeAll() }
                                        .labelStyle(.iconOnly)
                                        .disabled(movedNodes.isEmpty)
                                        .help(movedNodes.isEmpty ? "현재 노드가 자동으로 배치되어 있습니다." : "직접 이동한 노드를 자동 배치 위치로 되돌립니다.")
                                }
                                HStack(spacing: 12) {
                                    legend(AgentKind.codex.title, color: AgentKind.codex.graphColor)
                                    legend(AgentKind.claude.title, color: AgentKind.claude.graphColor)
                                    if group.members.contains(where: { $0.agent == .shell }) {
                                        legend(AgentKind.shell.title, color: AgentKind.shell.graphColor)
                                    }
                                    Spacer(minLength: 0)
                                    legend("미응답 연결", color: .orange)
                                        .help("주황색 연결선에는 아직 답변되지 않은 질문이 있습니다. 나머지 양방향 연결은 회색으로 표시합니다.")
                                }
                            }
                            .font(.caption).foregroundStyle(.secondary).padding(12)
                            Divider()
                            GroupConversationNodes(group: group, page: page, onlyPending: onlyPending,
                                                   blocked: Set(operations.filter { $0.value.isDeliveryBlocked }.keys),
                                                   selection: $selected, movedNodes: $movedNodes, isDragging: $isDraggingNode)
                        }
                        .frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        Divider()
                        inspector(group).frame(width: 320)
                            .frame(maxHeight: .infinity, alignment: .topLeading)
                    }
                    .frame(maxHeight: .infinity)
                }
                if page.hasMore {
                    Divider()
                    Text("미응답 우선 질문 300건, 기타 기록 150건까지 표시합니다.")
                        .font(.caption).foregroundStyle(.secondary).padding(12)
                }
            } else if error == nil {
                ProgressView("대화 기록 불러오는 중")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("대화 기록을 불러오지 못했습니다", systemImage: "tray")
            }
        }
        .frame(minWidth: 720, idealWidth: 860, minHeight: 460, idealHeight: 590)
        .sheet(item: $replyTarget) { item in
            let question = item.question
            GroupConversationReplyEditor(question: question,
                                         sender: group.map { title(question.recipientID, in: $0) } ?? "",
                                         recipient: group.map { title(question.senderID, in: $0) } ?? "") { text in
                defer { refresh() }
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
            let name = group.map { title(item.question.recipientID, in: $0) } ?? ""
            Text("\(name)의 터미널에 원래 질문을 보냅니다. 이미 본 질문이면 새 응답이 시작될 수 있습니다.")
        }
        .alert("질문 전달을 확인하지 못했습니다", isPresented: Binding(
            get: { deliveryError != nil }, set: { if !$0 { deliveryError = nil } }
        ), presenting: deliveryError) { _ in
            Button("확인", role: .cancel) {}
                .help("전달 결과 안내를 닫습니다.")
        } message: { Text($0) }
        .task {
            while !Task.isCancelled {
                if !isDraggingNode { refresh() }
                do { try await Task.sleep(for: .seconds(6)) } catch { return }
            }
        }
    }

    private func legend(_ title: String, color: Color) -> some View {
        Label { Text(title) } icon: { Image(systemName: "circle.fill").foregroundStyle(color) }
    }

    private func operationSummary(_ group: SessionGroup) -> some View {
        let working = operations.values.filter { $0.phase == .working }.count
        let waiting = operations.values.reduce(0) { $0 + $1.unacknowledgedCount }
        let blocked = group.treeOrder.map(\.member).filter { operations[$0.id]?.isDeliveryBlocked == true }
        return HStack(spacing: 16) {
            Label("작업 중 \(working)명", systemImage: "bolt")
                .help("확인된 세션 중 마지막 상태가 작업 중인 구성원 수입니다.")
            Label("수신 미확인 \(waiting)건", systemImage: "tray")
                .help("현재 구성원에게 저장됐지만 수신 확인이 남아 있는 그룹 메시지 수입니다. 터미널에 이미 제출된 메시지도 포함됩니다.")
            if blocked.isEmpty {
                Label("전달 막힘 0명", systemImage: "exclamationmark.triangle")
                    .help("전달할 메시지가 있고 현재 입력할 수 없거나, 첫 전달 시도가 보류된 구성원을 셉니다.")
            } else {
                Menu {
                    ForEach(blocked) { member in
                        Button(member.title) { selected = member.id }
                            .help("이 구성원의 입력 상태와 마지막 전달 보류 사유를 봅니다.")
                    }
                } label: {
                    Label("전달 막힘 \(blocked.count)명", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("전달이 막힌 구성원을 선택해 대기 건수와 보류 사유를 봅니다.")
            }
            Spacer()
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func deliver(_ item: SessionGroupConversation) {
        guard deliveringQuestion == nil else { return }
        let name = group.map { title(item.question.recipientID, in: $0) } ?? "대상"
        deliveryFeedback = nil
        deliveringQuestion = item.id
        Task {
            defer { deliveringQuestion = nil; refresh() }
            do {
                try await engine.deliverSessionGroupQuestion(groupID: groupID, questionID: item.id)
                deliveryFeedback = "\(name)의 터미널에 질문을 제출했습니다."
            } catch { deliveryError = error.localizedDescription }
        }
    }

    private func refresh() {
        do {
            guard let currentGroup = try SessionGroupStore(directory: engine.paths.directory).load().first(where: { $0.id == groupID }) else {
                group = nil
                page = nil
                operations = [:]
                selected = nil
                error = "저장된 그룹을 찾을 수 없습니다."
                return
            }
            let next = try engine.sessionGroupConversations(groupID)
            let nextOperations = try engine.sessionGroupOperations(currentGroup)
            if group != currentGroup { group = currentGroup }
            if page != next { page = next }
            if operations != nextOperations { operations = nextOperations }
            if let selected, !currentGroup.members.contains(where: { $0.id == selected }) { self.selected = nil }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    @ViewBuilder private func inspector(_ group: SessionGroup) -> some View {
        if let selected, let member = group.members.first(where: { $0.id == selected }) {
            let conversations = (page?.conversations ?? []).filter {
                $0.question.senderID == selected || $0.question.recipientID == selected
            }
            let messages = (page?.messages ?? []).filter { $0.senderID == selected || $0.recipientID == selected }
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(member.title).font(.headline).lineLimit(2).help(member.title)
                    let role = group.isLeader(member.id) ? "그룹장" : "구성원"
                    Text("\(member.agent.title) · \(role)")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(14)
                Divider()
                List {
                    if let operation = operations[member.id] {
                        Section("세션 상태") { memberOperation(operation) }
                    }
                    if conversations.isEmpty && messages.isEmpty {
                        Label("저장된 대화가 없습니다", systemImage: "bubble.left.and.bubble.right")
                            .foregroundStyle(.secondary)
                    }
                    if !conversations.isEmpty {
                        Section("질문과 답변") {
                            ForEach(conversations) { item in
                                let outbound = item.question.senderID == selected
                                let peer = outbound ? item.question.recipientID : item.question.senderID
                                VStack(alignment: .leading, spacing: 6) {
                                    DisclosureGroup {
                                        message("질문", item.question)
                                        if let answer = item.answer { message("답변", answer) }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text((outbound ? "보낸 질문 · " : "받은 질문 · ") + title(peer, in: group))
                                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                            Text(item.question.text).lineLimit(2)
                                        }
                                    }
                                    .disclosureGroupStyle(ConversationDisclosureStyle(summary: "질문과 답변 원문"))
                                    HStack {
                                        Label(status(item), systemImage: item.answer == nil ? "clock" : "checkmark.circle")
                                            .font(.caption)
                                            .foregroundStyle(item.waitExpired ? Color.orange : Color.secondary)
                                    }
                                    if item.answer == nil, group.members.contains(where: { $0.id == peer }) {
                                        HStack {
                                            if deliveringQuestion == item.id {
                                                ProgressView().controlSize(.small).accessibilityLabel("질문 전달 중")
                                            }
                                            Spacer(minLength: 4)
                                            Button("노드에 전달…") { deliveryTarget = item }
                                                .disabled(deliveringQuestion != nil)
                                                .help(deliveringQuestion == nil
                                                      ? "\(title(item.question.recipientID, in: group))의 터미널에 원래 질문을 보냅니다. 제출하기 전에 확인 창이 열립니다."
                                                      : "진행 중인 질문 전달이 끝나면 다시 사용할 수 있습니다.")
                                            Button("답변…") { replyTarget = item }
                                                .help("질문을 받은 구성원 대신 답변을 작성해 원래 질문자에게 보냅니다.")
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                }
                                .padding(.vertical, 4)
                                .accessibilityElement(children: .contain)
                            }
                        }
                    }
                    if !messages.isEmpty {
                        Section("메시지와 보고") {
                            ForEach(messages, id: \.id) { item in
                                let outgoing = item.senderID == selected
                                let peer = outgoing ? item.recipientID : item.senderID
                                let kind = item.kind == .report ? "보고" : item.kind == .reply ? "답변" : item.kind == .choiceQuestion ? "선택 질문" : "메시지"
                                DisclosureGroup {
                                    message(kind, item)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text((outgoing ? "보냄 · " : "받음 · ") + title(peer, in: group))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        Text(item.text).lineLimit(2)
                                        Text(kind + " · " + delivery(item))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .disclosureGroupStyle(ConversationDisclosureStyle(summary: "메시지 원문"))
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .id(selected)
            }
        } else {
            ContentUnavailableView("구성원을 선택하세요", systemImage: "cursorarrow",
                                   description: Text("노드를 선택하면 보낸 질문과 받은 질문을 볼 수 있습니다."))
        }
    }

    private func memberOperation(_ operation: SessionGroupMemberOperation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            let phase = operation.phase
            statusRow("세션 연결", phase.map { "대화 확인 · " + $0.title } ?? "대화 미확인")
            switch operation.input {
            case .unverified: statusRow("터미널 입력", "입력 상태 미확인")
            case .idle:
                statusRow("터미널 입력", "대기 중 · 제출 직전 확인")
                    .help("AutoApprove는 실제로 제출하기 전에 현재 터미널의 빈 입력창을 확인합니다.")
            case let .deferred(reason): statusRow("터미널 입력", reason, attention: true)
            }
            statusRow("수신 미확인", "\(operation.unacknowledgedCount)건")
            statusRow("마지막 수신 확인", formatOperationDate(operation.lastAcknowledgedAt))
            if let first = operation.firstPendingAt {
                statusRow("가장 오래된 미확인", formatOperationDate(first))
            }
            if let reason = operation.lastDeliveryFailure, !reason.isEmpty {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("이 구성원에게 먼저 전달할 메시지의 마지막 보류 사유입니다.")
            }
        }
        .font(.caption)
        .padding(.vertical, 5)
    }

    private func statusRow(_ name: String, _ value: String, attention: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(value).foregroundStyle(attention ? Color.orange : Color.primary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func formatOperationDate(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .shortened) ?? "기록 없음"
    }
    private func title(_ id: UUID, in group: SessionGroup) -> String { group.members.first { $0.id == id }?.title ?? "이전 구성원" }

    private func status(_ item: SessionGroupConversation) -> String {
        if let answer = item.answer { return "답변 있음 · " + delivery(answer) }
        return (item.waitExpired ? "대기 만료 · " : "미응답 · ") + delivery(item.question)
    }

    private func delivery(_ message: SessionGroupMessage) -> String {
        if message.acknowledgedAt != nil { return "수신 확인" }
        switch message.lastResult {
        case "direct_attempting", "direct_unknown", "unknown": return "전달 여부 미확인"
        case "direct_submitted", "submitted": return "터미널 제출"
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

@MainActor private struct GroupConversationNodes: View {
    let group: SessionGroup
    let page: SessionGroupConversationPage
    let onlyPending: Bool
    let blocked: Set<UUID>
    @Binding var selection: UUID?
    @Binding var movedNodes: [UUID: CGPoint]
    @Binding var isDragging: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var layout: [UUID: CGPoint] = [:]
    @State private var deferredLayout: [UUID: CGPoint]?
    @State private var preview = ConversationDragPreview()
    @State private var movingNode: UUID?
    @GestureState private var dragging = false
    @State private var dragOrigin: CGPoint?

    private struct Flow {
        var count = 0
        var pending = 0
    }
    private struct Edge {
        let link: ConversationGraphLayout.Link
        let twoWay: Bool
        let color: Color
        let active: Bool
        let count: Int
        var width: CGFloat { 1 + min(4, log2(CGFloat(count) + 1) * 0.65) }

        func touches(_ id: UUID?) -> Bool { link.from == id || link.to == id }
    }

    var body: some View {
        let members = group.treeOrder.map(\.member)
        let ids = members.map(\.id)
        let flows = flows(for: Set(ids))
        let topology = ConversationGraphLayout(members: ids, links: Set(flows.keys.map(\.undirected)))
        let colors = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.agent.graphColor) })
        let edges = topology.links.sorted().compactMap { link -> Edge? in
            let reverse = ConversationGraphLayout.Link(from: link.to, to: link.from)
            let forward = flows[link, default: Flow()]
            let backward = flows[reverse, default: Flow()]
            let outgoing = onlyPending ? forward.pending : forward.count
            let incoming = onlyPending ? backward.pending : backward.count
            guard outgoing + incoming > 0 else { return nil }
            let direction = outgoing > 0 ? link : reverse
            let twoWay = outgoing > 0 && incoming > 0
            let color: Color = forward.pending + backward.pending > 0 ? .orange
                : twoWay ? .secondary : colors[direction.from, default: .secondary]
            return Edge(link: direction, twoWay: twoWay, color: color,
                        active: selection == nil || link.from == selection || link.to == selection,
                        count: outgoing + incoming)
        }
        GeometryReader { proxy in
            let minimum = max(350, ceil(sqrt(CGFloat(members.count))) * 90)
            let size = CGSize(width: max(proxy.size.width, minimum),
                              height: max(proxy.size.height, minimum))
            let positions = topology.initialPositions
                .merging(layout) { _, computed in computed }
                .merging(movedNodes) { _, moved in moved }
            let points = positions.mapValues {
                CGPoint(x: 75 + $0.x * (size.width - 150), y: 48 + $0.y * (size.height - 110))
            }
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        for edge in edges where !edge.touches(movingNode) {
                            guard let from = points[edge.link.from], let to = points[edge.link.to],
                                  let path = Self.edgePath(from, to, twoWay: edge.twoWay) else { continue }
                            context.stroke(path, with: .color(edge.color.opacity(edge.active ? 0.78 : 0.24)),
                                           style: StrokeStyle(lineWidth: edge.width, lineCap: .round))
                        }
                    }
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                    ForEach(members) { member in
                        if let point = points[member.id] {
                            let label = nodeLabel(member, highlighted: selection == member.id)
                            Button { selection = member.id } label: {
                                label.opacity(movingNode == member.id ? 0.15 : 1)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(member.title + ", " + member.agent.title)
                            .accessibilityValue(blocked.contains(member.id) ? "전달 막힘" : "")
                            .accessibilityAddTraits(selection == member.id ? [.isSelected] : [])
                            .onMoveCommand { direction in
                                let offset: CGSize
                                switch direction {
                                case .left: offset = CGSize(width: -16, height: 0)
                                case .right: offset = CGSize(width: 16, height: 0)
                                case .up: offset = CGSize(width: 0, height: -16)
                                case .down: offset = CGSize(width: 0, height: 16)
                                @unknown default: return
                                }
                                movedNodes[member.id] = normalized(shift(point, by: offset, in: size), in: size)
                            }
                            .gesture(DragGesture(minimumDistance: 5, coordinateSpace: .named("conversationCanvas"))
                                .updating($dragging) { _, state, _ in state = true }
                                .onChanged { value in
                                    if dragOrigin == nil {
                                        dragOrigin = point
                                        isDragging = true
                                        let incident = edges.compactMap { edge -> ConversationDragPreview.Edge? in
                                            guard edge.touches(member.id) else { return nil }
                                            let outgoing = edge.link.from == member.id
                                            guard let anchor = points[outgoing ? edge.link.to : edge.link.from] else { return nil }
                                            return .init(anchor: anchor, outgoing: outgoing, twoWay: edge.twoWay,
                                                         color: NSColor(edge.color.opacity(0.88)), width: edge.width)
                                        }
                                        let visible = preview.begin(nodeLabel(member, highlighted: true)
                                            .environment(\.colorScheme, colorScheme), edges: incident,
                                            at: shift(point, by: value.translation, in: size))
                                        if visible { movingNode = member.id }
                                    }
                                    preview.move(to: shift(dragOrigin ?? point, by: value.translation, in: size))
                                }
                                .onEnded { value in
                                    movedNodes[member.id] = normalized(shift(dragOrigin ?? point, by: value.translation, in: size), in: size)
                                    finishDrag()
                                })
                            .help("\(member.title) · \(member.agent.title)\(blocked.contains(member.id) ? " · 전달 막힘" : "")\n클릭하면 세션 상태와 대화를 엽니다. 끌거나 방향키를 누르면 노드를 이동합니다.")
                            .position(x: point.x, y: point.y + 11)
                        }
                    }
                }
                .frame(width: size.width, height: size.height)
                .overlay { ConversationDragSurface(preview: preview).allowsHitTesting(false).accessibilityHidden(true) }
                .coordinateSpace(name: "conversationCanvas")
            }
        }
        .onChange(of: dragging) { _, active in
            if !active, dragOrigin != nil { finishDrag() }
        }
        .task(id: topology) {
            let previous = layout
            let next = await Task.detached(priority: .utility) {
                topology.positions(startingFrom: previous)
            }.value
            if !Task.isCancelled {
                if dragOrigin == nil { layout = next } else { deferredLayout = next }
            }
        }
        .onDisappear { if dragOrigin != nil { finishDrag() } }
    }

    private func finishDrag() {
        preview.end()
        movingNode = nil
        dragOrigin = nil
        isDragging = false
        if let deferredLayout {
            layout = deferredLayout
            self.deferredLayout = nil
        }
    }

    private func shift(_ point: CGPoint, by offset: CGSize, in size: CGSize) -> CGPoint {
        CGPoint(x: min(size.width - 75, max(75, point.x + offset.width)),
                y: min(size.height - 62, max(48, point.y + offset.height)))
    }

    private func normalized(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: (point.x - 75) / (size.width - 150), y: (point.y - 48) / (size.height - 110))
    }

    private func nodeLabel(_ member: SessionGroupMember, highlighted: Bool) -> some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().fill(member.agent.graphColor.opacity(0.83))
                Image(systemName: group.isLeader(member.id) ? "crown.fill" : "person.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 32, height: 32)
            .padding(3)
            .overlay { Circle().strokeBorder(highlighted ? Color.primary : .clear, lineWidth: 2) }
            .overlay(alignment: .topTrailing) {
                if blocked.contains(member.id) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.orange)
                        .padding(2)
                        .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                        .offset(x: 3, y: -2)
                }
            }
            Text(member.title)
                .font(.caption.weight(highlighted ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 4)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.92), in: Capsule())
        }
        .frame(width: 128, height: 61, alignment: .top)
    }

    private func flows(for ids: Set<UUID>) -> [ConversationGraphLayout.Link: Flow] {
        var totals: [ConversationGraphLayout.Link: Flow] = [:]
        func add(_ message: SessionGroupMessage, pending: Bool = false) {
            guard ids.contains(message.senderID), ids.contains(message.recipientID),
                  message.senderID != message.recipientID else { return }
            let link = ConversationGraphLayout.Link(from: message.senderID, to: message.recipientID)
            totals[link, default: Flow()].count += 1
            if pending { totals[link, default: Flow()].pending += 1 }
        }
        for item in page.conversations {
            add(item.question, pending: item.answer == nil)
            if let answer = item.answer { add(answer) }
        }
        for message in page.messages { add(message) }
        return totals
    }

    static func edgePath(_ from: CGPoint, _ to: CGPoint, twoWay: Bool) -> Path? {
        let distance = hypot(to.x - from.x, to.y - from.y)
        guard distance > 40 else { return nil }
        let dx = (to.x - from.x) / distance, dy = (to.y - from.y) / distance
        let bend = min(23, distance * 0.10)
        let control = CGPoint(x: (from.x + to.x) / 2 - dy * bend,
                              y: (from.y + to.y) / 2 + dx * bend)
        let startAngle = atan2(control.y - from.y, control.x - from.x)
        let endAngle = atan2(to.y - control.y, to.x - control.x)
        let start = CGPoint(x: from.x + 18 * cos(startAngle), y: from.y + 18 * sin(startAngle))
        let end = CGPoint(x: to.x - 19 * cos(endAngle), y: to.y - 19 * sin(endAngle))
        var path = Path()
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        func arrow(at tip: CGPoint, angle: CGFloat) {
            for offset in [-0.48, 0.48] {
                path.move(to: tip)
                path.addLine(to: CGPoint(x: tip.x - 7 * cos(angle + offset), y: tip.y - 7 * sin(angle + offset)))
            }
        }
        arrow(at: end, angle: endAngle)
        if twoWay { arrow(at: start, angle: startAngle + .pi) }
        return path
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
/// Core Animation presents the lifted node and its incident edges at display cadence.
@MainActor private final class ConversationDragPreview: NSObject {
    struct Edge {
        let anchor: CGPoint
        let outgoing: Bool
        let twoWay: Bool
        let color: NSColor
        let width: CGFloat
    }

    weak var surface: NSView?
    private let node = CALayer()
    private var edges: [(edge: Edge, layer: CAShapeLayer)] = []
    private var displayLink: CADisplayLink?
    private var pending: CGPoint?

    func begin(_ label: some View, edges incident: [Edge], at point: CGPoint) -> Bool {
        end()
        guard let surface, let root = surface.layer else { return false }
        let renderer = ImageRenderer(content: label)
        renderer.scale = surface.window?.backingScaleFactor ?? 1
        guard let image = renderer.cgImage else { return false }
        withoutAnimations {
            for edge in incident {
                let layer = CAShapeLayer()
                layer.frame = root.bounds
                layer.fillColor = nil
                layer.strokeColor = edge.color.cgColor
                layer.lineWidth = edge.width
                layer.lineCap = .round
                root.addSublayer(layer)
                edges.append((edge, layer))
            }
            node.contents = image
            node.contentsScale = renderer.scale
            node.bounds.size = CGSize(width: CGFloat(image.width) / renderer.scale,
                                      height: CGFloat(image.height) / renderer.scale)
            node.shadowColor = NSColor.black.cgColor
            node.shadowOpacity = 0.24
            node.shadowRadius = 4
            node.shadowOffset = CGSize(width: 0, height: -2)
            node.shadowPath = CGPath(ellipseIn: CGRect(x: node.bounds.midX - 18, y: node.bounds.height - 37,
                                                       width: 36, height: 36), transform: nil)
            root.addSublayer(node)
            present(point, height: surface.bounds.height)
        }
        let link = surface.displayLink(target: self, selector: #selector(displayFrame))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        displayLink = link
        return true
    }

    func move(to point: CGPoint) {
        guard node.superlayer != nil else { return }
        pending = point
        displayLink?.isPaused = false
    }

    func end() {
        displayLink?.invalidate()
        displayLink = nil
        pending = nil
        withoutAnimations {
            for item in edges { item.layer.removeFromSuperlayer() }
            edges.removeAll()
            node.removeFromSuperlayer()
            node.contents = nil
        }
    }

    @objc private func displayFrame() {
        displayLink?.isPaused = true
        guard let point = pending, let surface else { return }
        pending = nil
        withoutAnimations { present(point, height: surface.bounds.height) }
    }

    private func present(_ point: CGPoint, height: CGFloat) {
        node.position = CGPoint(x: point.x, y: height - point.y - 11)
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
        for (edge, layer) in edges {
            let from = edge.outgoing ? point : edge.anchor
            let to = edge.outgoing ? edge.anchor : point
            layer.path = GroupConversationNodes.edgePath(from, to, twoWay: edge.twoWay)?.cgPath.copy(using: &flip)
        }
    }

    private func withoutAnimations(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }
}

private struct ConversationGraphLayout: Equatable, Sendable {
    struct Link: Hashable, Comparable, Sendable {
        let from: UUID
        let to: UUID

        var undirected: Self {
            from.uuidString < to.uuidString ? self : .init(from: to, to: from)
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.from.uuidString, lhs.to.uuidString) < (rhs.from.uuidString, rhs.to.uuidString)
        }
    }

    let members: [UUID]
    let links: Set<Link>

    var initialPositions: [UUID: CGPoint] {
        Dictionary(uniqueKeysWithValues: members.enumerated().map { index, id in
            let angle = CGFloat(index) * .pi * (3 - sqrt(5))
            let radius = 0.45 * sqrt(CGFloat(index) / CGFloat(max(1, members.count - 1)))
            return (id, CGPoint(x: 0.5 + radius * cos(angle), y: 0.5 + radius * sin(angle)))
        })
    }

    func positions(startingFrom previous: [UUID: CGPoint]) -> [UUID: CGPoint] {
        guard members.count > 1 else { return initialPositions }
        let seed = initialPositions
        let indices = Dictionary(uniqueKeysWithValues: members.enumerated().map { ($0.element, $0.offset) })
        let connected = links.sorted().compactMap { link -> (Int, Int)? in
            guard let from = indices[link.from], let to = indices[link.to] else { return nil }
            return (from, to)
        }
        var points = members.map { previous[$0] ?? seed[$0] ?? CGPoint(x: 0.5, y: 0.5) }
        let spacing = 0.78 / sqrt(CGFloat(points.count))
        for step in 0..<90 {
            var force = points.map { CGPoint(x: (0.5 - $0.x) * 0.09, y: (0.5 - $0.y) * 0.09) }
            for left in points.indices {
                for right in (left + 1)..<points.count {
                    let x = points[left].x - points[right].x
                    let y = points[left].y - points[right].y
                    let strength = spacing * spacing / max(0.0001, x * x + y * y)
                    force[left].x += x * strength
                    force[left].y += y * strength
                    force[right].x -= x * strength
                    force[right].y -= y * strength
                }
            }
            for (from, to) in connected {
                let x = points[from].x - points[to].x
                let y = points[from].y - points[to].y
                let attraction = max(0, hypot(x, y) - spacing * 0.9) / spacing * 0.24
                force[from].x -= x * attraction
                force[from].y -= y * attraction
                force[to].x += x * attraction
                force[to].y += y * attraction
            }
            let cap = 0.029 * (1 - CGFloat(step) / 95)
            for index in points.indices {
                let magnitude = max(0.001, hypot(force[index].x, force[index].y))
                let move = min(0.16, cap / magnitude)
                points[index].x = min(1, max(0, points[index].x + force[index].x * move))
                points[index].y = min(1, max(0, points[index].y + force[index].y * move))
            }
        }
        reduceCrossings(in: &points, edges: connected)
        return Dictionary(uniqueKeysWithValues: zip(members, points))
    }

    /// Try nearby swaps after settling the layout. Compare only lines that
    /// could change and keep a swap when it removes crossings without stretching the graph.
    private func reduceCrossings(in points: inout [CGPoint], edges: [(Int, Int)]) {
        guard edges.count > 1 else { return }
        var incident = Array(repeating: [Int](), count: points.count)
        for (index, edge) in edges.enumerated() {
            incident[edge.0].append(index)
            incident[edge.1].append(index)
        }
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        func side(_ a: CGPoint, _ b: CGPoint, _ p: CGPoint) -> CGFloat {
            (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
        }
        func score(_ affected: Set<Int>, _ positions: [CGPoint]) -> (crossings: Int, length: CGFloat) {
            var crossings = 0, length: CGFloat = 0
            for index in affected.sorted() {
                let (a, b) = edges[index]
                length += distance(positions[a], positions[b])
                for (other, edge) in edges.enumerated() {
                    let (c, d) = edge
                    guard index != other, !affected.contains(other) || index < other,
                          a != c, a != d, b != c, b != d else { continue }
                    let p = positions[a], q = positions[b], r = positions[c], s = positions[d]
                    if side(p, q, r) * side(p, q, s) < -0.000001 &&
                        side(r, s, p) * side(r, s, q) < -0.000001 { crossings += 1 }
                }
            }
            return (crossings, length)
        }
        var budget = 180
        for _ in 0..<2 {
            for left in points.indices where !incident[left].isEmpty {
                let anchor = points[left]
                let nearest = points.indices.filter { $0 > left && !incident[$0].isEmpty }.sorted {
                    (distance(anchor, points[$0]), $0) < (distance(anchor, points[$1]), $1)
                }.prefix(4)
                for right in nearest {
                    guard budget > 0 else { return }
                    budget -= 1
                    let affected = Set(incident[left] + incident[right])
                    let before = score(affected, points)
                    guard before.crossings > 0 else { continue }
                    points.swapAt(left, right)
                    let after = score(affected, points)
                    if after.crossings >= before.crossings || after.length > before.length * 1.18 {
                        points.swapAt(left, right)
                    }
                }
            }
        }
    }
}
