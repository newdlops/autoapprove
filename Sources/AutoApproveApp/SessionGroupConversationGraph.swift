import SwiftUI
import AutoApproveCore

@MainActor struct SessionGroupConversationGraph: View {
    let group: SessionGroup
    let engine: ApprovalEngine
    @Environment(\.dismiss) private var dismiss
    @State private var page: SessionGroupConversationPage?
    @State private var error: String?
    @State private var selected: UUID?
    @State private var onlyPending = true

    private var shown: [SessionGroupConversation] {
        (page?.conversations ?? []).filter { !onlyPending || $0.answer == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("대화 그래프").font(.title2.weight(.semibold))
                    Text(group.name).foregroundStyle(.secondary).lineLimit(1).help(group.name)
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
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).padding(12)
                Divider()
            }
            if let page {
                if group.members.isEmpty {
                    ContentUnavailableView("구성원이 없습니다", systemImage: "person.2")
                } else {
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Label("보낸 쪽 → 받는 쪽", systemImage: "arrow.right")
                                Spacer()
                                Label("미응답", systemImage: "circle.fill").foregroundStyle(.orange)
                                if !onlyPending { Label("답변 있음", systemImage: "circle.fill") }
                            }
                            .font(.caption).foregroundStyle(.secondary).padding(12)
                            Divider()
                            GroupConversationNodes(members: group.treeOrder.map(\.member),
                                                   conversations: shown, selection: $selected)
                        }
                        .frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        Divider()
                        inspector.frame(width: 320)
                            .frame(maxHeight: .infinity, alignment: .topLeading)
                    }
                    .frame(maxHeight: .infinity)
                }
                if page.hasMore {
                    Divider()
                    Text("미응답을 우선해 최대 300건을 표시합니다.")
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
        .task {
            while !Task.isCancelled {
                refresh()
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
            }
        }
    }

    private func refresh() {
        do {
            let next = try engine.sessionGroupConversations(group.id)
            if page != next { page = next }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    @ViewBuilder private var inspector: some View {
        if let selected, let member = group.members.first(where: { $0.id == selected }) {
            let conversations = (page?.conversations ?? []).filter {
                $0.question.senderID == selected || $0.question.recipientID == selected
            }
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(member.title).font(.headline).lineLimit(2).help(member.title)
                    Text(member.agent.title + " · " + String(conversations.count) + "건")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(14)
                Divider()
                if conversations.isEmpty {
                    ContentUnavailableView("질문 기록이 없습니다",
                                           systemImage: "bubble.left.and.bubble.right")
                } else {
                    List(conversations) { item in
                        let outbound = item.question.senderID == selected
                        let peer = outbound ? item.question.recipientID : item.question.senderID
                        DisclosureGroup {
                            message("질문", item.question)
                            if let answer = item.answer { message("답변", answer) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text((outbound ? "보낸 질문 · " : "받은 질문 · ") + title(peer))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Text(item.question.text).lineLimit(2)
                                Label(status(item), systemImage: item.answer == nil ? "clock" : "checkmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(item.waitExpired ? Color.orange : Color.secondary)
                            }
                        }
                        .padding(.vertical, 4)
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

    private func title(_ id: UUID) -> String { group.members.first { $0.id == id }?.title ?? "이전 구성원" }

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

private struct GroupConversationNodes: View {
    let members: [SessionGroupMember]
    let conversations: [SessionGroupConversation]
    @Binding var selection: UUID?

    private struct Edge: Hashable {
        let from: UUID
        let to: UUID
    }

    var body: some View {
        GeometryReader { proxy in
            let columns = max(2, Int(proxy.size.width / 210))
            let stride = max(190, proxy.size.width / CGFloat(columns))
            let rowHeight: CGFloat = 108
            let nodeSize = CGSize(width: stride - 42, height: 60)
            let height = CGFloat((members.count + columns - 1) / columns) * rowHeight
            let positions = Dictionary(uniqueKeysWithValues: members.enumerated().map { index, member in
                (member.id, CGPoint(x: (CGFloat(index % columns) + 0.5) * stride,
                                    y: (CGFloat(index / columns) + 0.5) * rowHeight))
            })
            let edges = Dictionary(grouping: conversations) { Edge(from: $0.question.senderID, to: $0.question.recipientID) }
            let counts = involvement
            ScrollView([.vertical, .horizontal]) {
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        for (edge, items) in edges {
                            guard let from = positions[edge.from], let to = positions[edge.to], from != to else { continue }
                            let active = selection == nil || selection == edge.from || selection == edge.to
                            let pending = items.contains { $0.answer == nil }
                            let color = pending ? Color.orange : Color.secondary
                            draw(from, to, nodeSize: nodeSize, curved: edges[Edge(from: edge.to, to: edge.from)] != nil,
                                 color: color.opacity(active ? 0.9 : 0.13), context: context)
                        }
                    }
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                    ForEach(members) { member in
                        if let position = positions[member.id] {
                            Button { selection = member.id } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(member.title).font(.callout.weight(.semibold)).lineLimit(1)
                                    Text(member.agent.title + " · " + String(counts[member.id, default: 0]) + "건")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 9)
                                .frame(width: nodeSize.width, height: nodeSize.height, alignment: .leading)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(selection == member.id ? Color.accentColor : Color.secondary.opacity(0.35),
                                                      lineWidth: selection == member.id ? 2 : 1)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selection == member.id ? [.isSelected] : [])
                            .help(member.title)
                            .position(position)
                        }
                    }
                }
                .frame(width: stride * CGFloat(columns), height: height)
                .frame(minHeight: proxy.size.height, alignment: .topLeading)
            }
        }
    }

    private var involvement: [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for item in conversations {
            counts[item.question.senderID, default: 0] += 1
            counts[item.question.recipientID, default: 0] += 1
        }
        return counts
    }

    private func draw(_ from: CGPoint, _ to: CGPoint, nodeSize: CGSize, curved: Bool,
                      color: Color, context: GraphicsContext) {
        let delta = CGVector(dx: to.x - from.x, dy: to.y - from.y)
        let distance = hypot(delta.dx, delta.dy)
        let dx = delta.dx / distance, dy = delta.dy / distance
        let inset = min((nodeSize.width / 2 + 3) / abs(dx), (nodeSize.height / 2 + 3) / abs(dy))
        let start = CGPoint(x: from.x + dx * inset, y: from.y + dy * inset)
        let end = CGPoint(x: to.x - dx * inset, y: to.y - dy * inset)
        let bend: CGFloat = curved ? 20 : 0
        let control = CGPoint(x: (start.x + end.x) / 2 - dy * bend,
                              y: (start.y + end.y) / 2 + dx * bend)
        let angle = atan2(end.y - control.y, end.x - control.x)
        var path = Path()
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        for offset in [-0.45, 0.45] {
            path.move(to: end)
            path.addLine(to: CGPoint(x: end.x - 8 * cos(angle + offset), y: end.y - 8 * sin(angle + offset)))
        }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
    }
}
