import SwiftUI
import AutoApproveCore

@MainActor struct SessionGroupConversationGraph: View {
    let groupID: UUID
    let engine: ApprovalEngine
    @State private var group: SessionGroup?
    @State private var page: SessionGroupConversationPage?
    @State private var error: String?
    @State private var selected: UUID?
    @State private var onlyPending = false
    @State private var replyTarget: SessionGroupConversation?
    @State private var deliveryTarget: SessionGroupConversation?
    @State private var deliveringQuestion: UUID?
    @State private var deliveryFeedback: String?
    @State private var deliveryError: String?
    @State private var movedNodes: [UUID: CGPoint] = [:]

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
                Button("새로고침", systemImage: "arrow.clockwise", action: refresh)
                    .labelStyle(.iconOnly)
                    .help("질문과 답변 상태 새로고침")
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
                }
                .font(.caption).foregroundStyle(.secondary).padding(12)
                Divider()
            }
            if let page, let group {
                if group.members.isEmpty {
                    ContentUnavailableView("구성원이 없습니다", systemImage: "person.2")
                } else {
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Label("발신 → 수신", systemImage: "arrow.right")
                                Text("노드를 드래그해 이동")
                                Spacer()
                                Label { Text("미응답") } icon: { Image(systemName: "circle.fill").foregroundStyle(.orange) }
                                if !onlyPending { Label("기타 기록", systemImage: "circle.fill") }
                                Button("배치 초기화", systemImage: "arrow.counterclockwise") { movedNodes.removeAll() }
                                    .labelStyle(.iconOnly)
                                    .help("노드 자동 배치로 돌아가기")
                                    .disabled(movedNodes.isEmpty)
                            }
                            .font(.caption).foregroundStyle(.secondary).padding(12)
                            Divider()
                            GroupConversationNodes(group: group, page: page, onlyPending: onlyPending,
                                                   selection: $selected, movedNodes: $movedNodes)
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
            Button("취소", role: .cancel) {}
        } message: { item in
            let name = group.map { title(item.question.recipientID, in: $0) } ?? ""
            Text("\(name)의 터미널에 원래 질문을 보냅니다. 이미 본 질문이면 새 응답이 시작될 수 있습니다.")
        }
        .alert("질문 전달을 확인하지 못했습니다", isPresented: Binding(
            get: { deliveryError != nil }, set: { if !$0 { deliveryError = nil } }
        ), presenting: deliveryError) { _ in
            Button("확인", role: .cancel) {}
        } message: { Text($0) }
        .task {
            while !Task.isCancelled {
                refresh()
                do { try await Task.sleep(for: .seconds(6)) } catch { return }
            }
        }
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
                selected = nil
                error = "저장된 그룹을 찾을 수 없습니다."
                return
            }
            let next = try engine.sessionGroupConversations(groupID)
            if group != currentGroup { group = currentGroup }
            if page != next { page = next }
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
                    Text(member.agent.title + " · " + String(conversations.count + messages.count) + "건")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(14)
                Divider()
                if conversations.isEmpty && messages.isEmpty {
                    ContentUnavailableView("저장된 대화가 없습니다",
                                           systemImage: "bubble.left.and.bubble.right")
                } else {
                    List {
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
                                        .disclosureGroupStyle(QuestionDisclosureStyle())
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
                                                Button("답변…") { replyTarget = item }
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
                                    }.padding(.vertical, 4)
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                    .id(selected)
                }
            }
        } else {
            ContentUnavailableView("구성원을 선택하세요", systemImage: "cursorarrow",
                                   description: Text("노드를 선택하면 보낸 질문과 받은 질문을 볼 수 있습니다."))
        }
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

private struct QuestionDisclosureStyle: DisclosureGroupStyle {
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
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("답변 보내기") {
                    do { try send(body); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent)
                .disabled(body.isEmpty || body.count > limit || body.contains("\0"))
            }
        }
        .padding(20)
        .frame(width: 460)
        .defaultFocus($focused, true)
    }
}

// Only the moving node and its incident edges observe pointer updates.
@Observable private final class ConversationNodeMotion {
    var point: CGPoint?
}

private struct GroupConversationNodes: View {
    let group: SessionGroup
    let page: SessionGroupConversationPage
    let onlyPending: Bool
    @Binding var selection: UUID?
    @Binding var movedNodes: [UUID: CGPoint]
    @State private var layout: [UUID: CGPoint] = [:]
    @State private var motion = ConversationNodeMotion()
    @State private var movingNode: UUID?
    @GestureState private var dragging = false
    @State private var dragOrigin: CGPoint?

    private static let palette: [Color] = [.blue, .purple, .teal, .pink, .green, .indigo, .cyan, .mint]
    private struct Flow {
        var count = 0
        var pending = 0
    }
    private struct Edge {
        let link: ConversationGraphLayout.Link
        let color: Color
        let count: Int

        func touches(_ id: UUID?) -> Bool { link.from == id || link.to == id }
    }

    var body: some View {
        let members = group.treeOrder.map(\.member)
        let ids = members.map(\.id)
        let flows = flows(for: Set(ids))
        let topology = ConversationGraphLayout(members: ids, links: Set(flows.keys.map(\.undirected)))
        let colors = memberColors(members)
        let edges = flows.keys.sorted().compactMap { link -> Edge? in
            guard let flow = flows[link], !onlyPending || flow.pending > 0 else { return nil }
            let color = flow.pending > 0 ? Color.orange : colors[link.from, default: .secondary]
            return Edge(link: link, color: color.opacity(selection == nil || link.from == selection || link.to == selection ? 0.78 : 0.12),
                        count: onlyPending ? flow.pending : flow.count)
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
                    EdgeLayer(edges: edges.filter { !$0.touches(movingNode) }, points: points)
                    if let movingNode {
                        EdgeLayer(edges: edges.filter { $0.touches(movingNode) }, points: points,
                                  movingNode: movingNode, motion: motion)
                    }
                    ForEach(members) { member in
                        if let point = points[member.id] {
                            Button { selection = member.id } label: {
                                VStack(spacing: 3) {
                                    let color = colors[member.id, default: .blue]
                                    ZStack {
                                        Circle().fill(color.opacity(0.83))
                                        Image(systemName: group.isLeader(member.id) ? "crown.fill" : "person.fill")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(.white)
                                    }
                                    .frame(width: 32, height: 32)
                                    .padding(3)
                                    .overlay {
                                        Circle().strokeBorder(selection == member.id ? Color.primary : .clear, lineWidth: 2)
                                    }
                                    Text(member.title)
                                        .font(.caption.weight(selection == member.id ? .semibold : .regular))
                                        .lineLimit(1)
                                        .padding(.horizontal, 4)
                                        .background(Color(nsColor: .windowBackgroundColor).opacity(0.92), in: Capsule())
                                }
                                .frame(width: 128, height: 61, alignment: .top)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(member.title + ", " + member.agent.title)
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
                                        movingNode = member.id
                                    }
                                    motion.point = shift(dragOrigin ?? point, by: value.translation, in: size)
                                }
                                .onEnded { value in
                                    movedNodes[member.id] = normalized(shift(dragOrigin ?? point, by: value.translation, in: size), in: size)
                                    finishDrag()
                                })
                            .help(member.title + " · " + member.agent.title)
                            .modifier(NodePosition(point: point, motion: movingNode == member.id ? motion : nil))
                        }
                    }
                }
                .frame(width: size.width, height: size.height)
                .coordinateSpace(name: "conversationCanvas")
            }
        }
        .onChange(of: dragging) { _, active in
            if !active, movingNode != nil { finishDrag() }
        }
        .task(id: topology) {
            let previous = layout
            let next = await Task.detached(priority: .utility) {
                topology.positions(startingFrom: previous)
            }.value
            if !Task.isCancelled { layout = next }
        }
    }

    private func finishDrag() {
        movingNode = nil
        dragOrigin = nil
        motion.point = nil
    }

    private func shift(_ point: CGPoint, by offset: CGSize, in size: CGSize) -> CGPoint {
        CGPoint(x: min(size.width - 75, max(75, point.x + offset.width)),
                y: min(size.height - 62, max(48, point.y + offset.height)))
    }

    private func normalized(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: (point.x - 75) / (size.width - 150), y: (point.y - 48) / (size.height - 110))
    }

    private struct NodePosition: ViewModifier {
        let point: CGPoint
        let motion: ConversationNodeMotion?

        func body(content: Content) -> some View {
            let position = motion?.point ?? point
            content.position(x: position.x, y: position.y + 11)
        }
    }

    private struct EdgeLayer: View {
        let edges: [Edge]
        let points: [UUID: CGPoint]
        var movingNode: UUID?
        var motion: ConversationNodeMotion?

        var body: some View {
            let position = motion?.point
            Canvas { context, _ in
                for edge in edges {
                    let from = edge.link.from == movingNode ? position ?? points[edge.link.from] : points[edge.link.from]
                    let to = edge.link.to == movingNode ? position ?? points[edge.link.to] : points[edge.link.to]
                    guard let from, let to else { continue }
                    GroupConversationNodes.draw(from, to, color: edge.color, count: edge.count, context: context)
                }
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
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

    private func memberColors(_ members: [SessionGroupMember]) -> [UUID: Color] {
        var roots: [UUID: UUID] = [:]
        var palettes: [UUID: Int] = [:]
        var result: [UUID: Color] = [:]
        for member in members {
            let branch = member.parentMemberID.flatMap { parent in
                group.isLeader(parent) ? nil : roots[parent]
            } ?? member.id
            roots[member.id] = branch
            let index = palettes[branch] ?? palettes.count
            palettes[branch] = index
            result[member.id] = Self.palette[index % Self.palette.count]
        }
        return result
    }

    private static func draw(_ from: CGPoint, _ to: CGPoint, color: Color, count: Int, context: GraphicsContext) {
        let distance = hypot(to.x - from.x, to.y - from.y)
        guard distance > 40 else { return }
        let dx = (to.x - from.x) / distance, dy = (to.y - from.y) / distance
        let bend = min(47, max(15, distance * 0.22))
        let control = CGPoint(x: (from.x + to.x) / 2 - dy * bend,
                              y: (from.y + to.y) / 2 + dx * bend)
        let startAngle = atan2(control.y - from.y, control.x - from.x)
        let endAngle = atan2(to.y - control.y, to.x - control.x)
        let start = CGPoint(x: from.x + 18 * cos(startAngle), y: from.y + 18 * sin(startAngle))
        let end = CGPoint(x: to.x - 19 * cos(endAngle), y: to.y - 19 * sin(endAngle))
        let width = 1 + min(4, log2(CGFloat(count) + 1) * 0.65)
        var path = Path()
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        for offset in [-0.48, 0.48] {
            path.move(to: end)
            path.addLine(to: CGPoint(x: end.x - 7 * cos(endAngle + offset), y: end.y - 7 * sin(endAngle + offset)))
        }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
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
