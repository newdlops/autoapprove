import Foundation
import CoreGraphics

/// Presentation rules of the conversation graph window: member names, node states,
/// which records become lines, node positions and line geometry. No SwiftUI, so the
/// checks can exercise every rule and the window only draws the results.
public enum SessionGroupGraph {

    // MARK: Node state

    /// The node's fill and marks are the same for every agent; the agent only sets the color family.
    public enum NodeShape: String, Equatable, Sendable {
        /// Dark fill and a still ring: nothing to do, so it never moves.
        case working
        /// Light fill and a thin outline.
        case idle
        /// Dark fill and a speech bubble mark: approval or input is waiting in the terminal.
        case attention
        /// Dashed outline without fill: no live session evidence.
        case unknown
    }

    /// The one name of a member waiting for approval or input, in the legend, the summary,
    /// the member list and the panel heading.
    public static let needsResponseTitle = "응답 필요"

    public struct NodeStatus: Equatable, Sendable {
        public let shape: NodeShape
        /// A red outline and warning mark take priority over the speech bubble.
        public let blocked: Bool
        /// The state name everywhere the graph names a state.
        public let phaseTitle: String
        /// Tells approval from input apart; only the panel's session details use it.
        public let detailTitle: String

        public var title: String { blocked ? "전달 막힘" : phaseTitle }
        public var filled: Bool { shape == .working || shape == .attention }
        public var needsResponse: Bool { shape == .attention }
    }

    public static func status(phase: SessionPhase?, blocked: Bool) -> NodeStatus {
        let shape: NodeShape
        switch phase {
        case .working: shape = .working
        case .idle: shape = .idle
        case .approval, .input: shape = .attention
        case .unknown, .ended, nil: shape = .unknown
        }
        let detail = phase.map(detailTitle) ?? "상태 미확인"
        return NodeStatus(shape: shape, blocked: blocked, phaseTitle: shape == .attention ? needsResponseTitle : detail, detailTitle: detail)
    }

    /// "승인 대기" and "입력 대기" are told apart only in the panel's session details.
    public static func detailTitle(_ phase: SessionPhase) -> String {
        switch phase {
        case .approval: "승인 대기"
        case .input: "입력 대기"
        default: phase.title
        }
    }

    // MARK: Names

    public static let unconfirmedTerminalTitle = "터미널 제목 미확인"

    public struct MemberName: Equatable, Sendable {
        public let text: String
        /// "폴더 · 순번" is shown only until the member has a nickname.
        public let provisional: Bool
        public init(text: String, provisional: Bool) { self.text = text; self.provisional = provisional }
    }

    /// `liveNicknames` holds the nickname of each connected member's session (empty when it has none).
    /// Members absent from it are not connected. A connected member shows its session nickname; an
    /// unconnected member shows its stored title only when that title is a real name used once in the group.
    public static func names(group: SessionGroup, liveNicknames: [UUID: String]) -> [UUID: MemberName] {
        var uses: [String: Int] = [:]
        for member in group.members { uses[clean(member.title), default: 0] += 1 }
        var result: [UUID: MemberName] = [:]
        for (index, member) in group.members.enumerated() {
            if let nickname = liveNicknames[member.id] {
                let value = clean(nickname)
                if !value.isEmpty { result[member.id] = MemberName(text: value, provisional: false); continue }
            } else {
                let stored = clean(member.title)
                if !stored.isEmpty, stored != unconfirmedTerminalTitle, uses[stored] == 1 {
                    result[member.id] = MemberName(text: stored, provisional: false); continue
                }
            }
            result[member.id] = MemberName(text: provisionalName(member, position: index + 1), provisional: true)
        }
        return result
    }

    public static func provisionalName(_ member: SessionGroupMember, position: Int) -> String {
        let folder = URL(fileURLWithPath: member.cwd).lastPathComponent
        let base = member.cwd.isEmpty || folder.isEmpty || folder == "/" ? member.agent.title : folder
        return "\(base) · \(position)"
    }

    private static func clean(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    // MARK: Lines

    /// Ordered by drawing priority: a line takes the highest kind among its records.
    public enum EdgeKind: Int, Comparable, Hashable, Sendable {
        case expiredQuestion, older, recent, pendingQuestion
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public enum Scope: String, CaseIterable, Sendable {
        /// Questions still waiting for an answer and the last 30 minutes of records.
        case recent
        /// Also older records and expired questions, both faded.
        case all
    }

    public enum RecordKind: Equatable, Sendable { case pendingQuestion, expiredQuestion, record }

    public struct Record: Equatable, Sendable {
        public let from: UUID
        public let to: UUID
        public let createdAt: Date
        public let kind: RecordKind
        public init(from: UUID, to: UUID, createdAt: Date, kind: RecordKind) {
            self.from = from; self.to = to; self.createdAt = createdAt; self.kind = kind
        }
    }

    public struct EdgeKey: Hashable, Sendable {
        public let from: UUID
        public let to: UUID
        public let kind: EdgeKind
    }

    public struct Edge: Equatable, Identifiable, Sendable {
        public let from: UUID
        public let to: UUID
        public let kind: EdgeKind
        /// Records drawn by this line in its scope; sets the width step.
        public let count: Int
        /// Questions still waiting for an answer, shown as "?N" on the line.
        public let pendingQuestions: Int

        public init(from: UUID, to: UUID, kind: EdgeKind, count: Int, pendingQuestions: Int) {
            self.from = from; self.to = to; self.kind = kind; self.count = count; self.pendingQuestions = pendingQuestions
        }

        public var key: EdgeKey { EdgeKey(from: from, to: to, kind: kind) }
        public var id: EdgeKey { key }
        public var width: Double { SessionGroupGraph.width(forCount: count) }
        public var faded: Bool { kind == .older || kind == .expiredQuestion }
        public var dashed: Bool { kind == .expiredQuestion }
        public func touches(_ member: UUID?) -> Bool { from == member || to == member }
    }

    public static let recentInterval: TimeInterval = 30 * 60

    /// Visibly different steps: 1 record, 2-4, 5-9, 10 or more.
    public static func width(forCount count: Int) -> Double {
        switch count {
        case ..<2: 1.5
        case 2...4: 3
        case 5...9: 4.5
        default: 6
        }
    }

    /// Every question and answer, message, report and choice question in the page.
    /// Group system notices never appear in the page and so never become lines.
    public static func records(_ page: SessionGroupConversationPage) -> [Record] {
        var result: [Record] = []
        for item in page.conversations {
            let question = item.question
            let kind: RecordKind = item.answer != nil ? .record : item.waitExpired ? .expiredQuestion : .pendingQuestion
            result.append(Record(from: question.senderID, to: question.recipientID, createdAt: question.createdAt, kind: kind))
            if let answer = item.answer {
                result.append(Record(from: answer.senderID, to: answer.recipientID, createdAt: answer.createdAt, kind: .record))
            }
        }
        for message in page.messages where message.kind != .notice && message.kind != .waitNotice {
            result.append(Record(from: message.senderID, to: message.recipientID, createdAt: message.createdAt, kind: .record))
        }
        return result
    }

    /// One line per sender and recipient pair; both directions are separate lines.
    public static func edges(_ records: [Record], members: Set<UUID>, scope: Scope, now: Date) -> [Edge] {
        struct Pair: Hashable { let from: UUID; let to: UUID }
        var totals: [Pair: (kind: EdgeKind, count: Int, pending: Int)] = [:]
        for record in records where record.from != record.to && members.contains(record.from) && members.contains(record.to) {
            let kind: EdgeKind
            switch record.kind {
            case .pendingQuestion: kind = .pendingQuestion
            case .expiredQuestion: kind = .expiredQuestion
            case .record: kind = now.timeIntervalSince(record.createdAt) <= recentInterval ? .recent : .older
            }
            if scope == .recent, kind == .older || kind == .expiredQuestion { continue }
            let pair = Pair(from: record.from, to: record.to)
            var value = totals[pair] ?? (kind, 0, 0)
            value.kind = max(value.kind, kind)
            value.count += 1
            if kind == .pendingQuestion { value.pending += 1 }
            totals[pair] = value
        }
        return totals.map { Edge(from: $0.key.from, to: $0.key.to, kind: $0.value.kind, count: $0.value.count, pendingQuestions: $0.value.pending) }
            .sorted { ($0.kind, $0.from.uuidString, $0.to.uuidString) < ($1.kind, $1.from.uuidString, $1.to.uuidString) }
    }

    /// Lines that did not exist in the previous read. Only new activity counts: a line that
    /// faded because time passed is not new.
    public static func freshKeys(previous: [Edge], current: [Edge]) -> Set<EdgeKey> {
        let old = Set(previous.map(\.key))
        return Set(current.filter { ($0.kind == .recent || $0.kind == .pendingQuestion) && !old.contains($0.key) }.map(\.key))
    }

    // MARK: Layout

    public enum Layout: String, CaseIterable, Sendable { case tree, circle }

    /// The name band is 128pt wide; 16pt separates neighbours.
    public static let leafSpacing = 144.0
    public static let layerSpacing = 104.0
    public static let minimumRadius = 160.0

    /// Points relative to an arbitrary origin, in tree order.
    public static func positions(_ order: [SessionGroupTreeEntry], hasLeader: Bool, layout: Layout) -> [UUID: CGPoint] {
        positions(order.map { (id: $0.member.id, depth: $0.depth) }, hasLeader: hasLeader, layout: layout)
    }

    /// The same with member IDs and tree depths in tree order.
    public static func positions(_ order: [(id: UUID, depth: Int)], hasLeader: Bool, layout: Layout) -> [UUID: CGPoint] {
        switch layout {
        case .tree: return treePositions(order)
        case .circle: return circlePositions(order.map(\.id), centered: hasLeader)
        }
    }

    /// The parent is the nearest earlier entry one level up. Leaves go left to right and a parent
    /// sits over the middle of its children. A group without a leader is one row.
    private static func treePositions(_ order: [(id: UUID, depth: Int)]) -> [UUID: CGPoint] {
        var children: [Int: [Int]] = [:]
        var roots: [Int] = []
        for (index, entry) in order.enumerated() {
            if entry.depth > 0, let parent = order[..<index].lastIndex(where: { $0.depth == entry.depth - 1 }) {
                children[parent, default: []].append(index)
            } else {
                roots.append(index)
            }
        }
        var result: [UUID: CGPoint] = [:]
        var nextLeaf = 0.0
        func place(_ index: Int, level: Int) -> Double {
            let x: Double
            if let kids = children[index], !kids.isEmpty {
                let xs = kids.map { place($0, level: level + 1) }
                x = (xs[0] + xs[xs.count - 1]) / 2
            } else {
                x = nextLeaf * leafSpacing
                nextLeaf += 1
            }
            result[order[index].id] = CGPoint(x: x, y: Double(level) * layerSpacing)
            return x
        }
        for root in roots { _ = place(root, level: 0) }
        return result
    }

    /// The first leader is in the middle; the rest start at 12 o'clock and go clockwise in tree order.
    private static func circlePositions(_ ids: [UUID], centered: Bool) -> [UUID: CGPoint] {
        guard let first = ids.first else { return [:] }
        let ring = centered ? Array(ids.dropFirst()) : ids
        var result: [UUID: CGPoint] = centered ? [first: .zero] : [:]
        guard ring.count > (centered ? 0 : 1) else { return ring.count == 1 ? [ring[0]: .zero] : result }
        let radius = max(minimumRadius, Double(ring.count) * leafSpacing / (2 * .pi))
        for (index, id) in ring.enumerated() {
            let angle = -Double.pi / 2 + Double(index) * 2 * .pi / Double(ring.count)
            result[id] = CGPoint(x: (radius * cos(angle)).rounded(), y: (radius * sin(angle)).rounded())
        }
        return result
    }

    public struct Frame: Equatable, Sendable {
        /// Node circle centres inside the content.
        public let points: [UUID: CGPoint]
        public let size: CGSize
    }

    /// Room around the outermost circles for the working ring, the name band and arrowheads.
    public static let horizontalMargin = 76.0
    public static let topMargin = 36.0
    public static let bottomMargin = 64.0

    public static func frame(_ positions: [UUID: CGPoint]) -> Frame {
        guard !positions.isEmpty else { return Frame(points: [:], size: CGSize(width: 2 * horizontalMargin, height: topMargin + bottomMargin)) }
        let xs = positions.values.map(\.x), ys = positions.values.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        let points = positions.mapValues { CGPoint(x: $0.x - minX + horizontalMargin, y: $0.y - minY + topMargin) }
        return Frame(points: points, size: CGSize(width: maxX - minX + 2 * horizontalMargin, height: maxY - minY + topMargin + bottomMargin))
    }

    // MARK: Zoom and pan

    public static let minimumZoom = 0.25
    public static let maximumZoom = 3.0
    /// Fitting on open and after a layout change never goes below this, so names stay readable.
    public static let automaticFitMinimum = 0.6
    /// The − and + buttons and ⌘− ⌘+ move between these steps.
    public static let zoomSteps: [Double] = [0.25, 0.33, 0.5, 0.67, 0.8, 1, 1.25, 1.5, 2, 2.5, 3]

    /// A graph point `g` appears at `g × scale + offset` in the graph area, whose top left is (0, 0).
    public struct Viewport: Equatable, Sendable {
        public var scale: Double
        public var offset: CGPoint

        public init(scale: Double, offset: CGPoint) { self.scale = scale; self.offset = offset }

        public static let identity = Viewport(scale: 1, offset: .zero)

        /// Where a graph point appears in the graph area.
        public func screen(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x * scale + offset.x, y: point.y * scale + offset.y)
        }

        /// The graph point under a point of the graph area.
        public func graph(_ point: CGPoint) -> CGPoint {
            CGPoint(x: (point.x - offset.x) / scale, y: (point.y - offset.y) / scale)
        }

        /// The part of the graph that an area of `size` shows.
        public func visible(_ size: CGSize) -> CGRect {
            let origin = graph(.zero)
            return CGRect(x: origin.x, y: origin.y, width: size.width / scale, height: size.height / scale)
        }

        /// The graph point under `anchor` stays under it, so zooming follows the pointer.
        public func zoomed(to newScale: Double, around anchor: CGPoint) -> Viewport {
            let target = SessionGroupGraph.clampZoom(newScale)
            let fixed = graph(anchor)
            return Viewport(scale: target, offset: CGPoint(x: anchor.x - fixed.x * target, y: anchor.y - fixed.y * target))
        }

        public func panned(by delta: CGVector) -> Viewport {
            Viewport(scale: scale, offset: CGPoint(x: offset.x + delta.dx, y: offset.y + delta.dy))
        }
    }

    public static func clampZoom(_ scale: Double) -> Double {
        guard scale.isFinite else { return 1 }
        return min(maximumZoom, max(minimumZoom, scale))
    }

    /// The next step above or below `scale`; a scale between steps goes to the nearest step in that direction.
    public static func steppedZoom(from scale: Double, larger: Bool) -> Double {
        let next = larger ? zoomSteps.first { $0 > scale + 0.001 } : zoomSteps.last { $0 < scale - 0.001 }
        return next ?? (larger ? maximumZoom : minimumZoom)
    }

    /// Node circle centres widened by the frame margins, so circles, rings and name bands are inside.
    public static func contentBounds(_ points: [UUID: CGPoint]) -> CGRect {
        guard let first = points.values.first else {
            return CGRect(x: 0, y: 0, width: 2 * horizontalMargin, height: topMargin + bottomMargin)
        }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.values {
            minX = min(minX, point.x); maxX = max(maxX, point.x); minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX - horizontalMargin, y: minY - topMargin,
                      width: maxX - minX + 2 * horizontalMargin, height: maxY - minY + topMargin + bottomMargin)
    }

    /// The largest scale between `minimum` and `maximum` that shows all of `content`. An axis that
    /// fits is centred. An axis that still does not fit puts `focus` (the leader) at the same share
    /// of the area as its share of the content, so the focus is in view and no empty space shows.
    public static func fit(_ content: CGRect, in size: CGSize, minimum: Double, maximum: Double = 1, focus: CGPoint?) -> Viewport {
        guard size.width > 0, size.height > 0, content.width > 0, content.height > 0 else { return .identity }
        let scale = clampZoom(min(maximum, max(minimum, min(size.width / content.width, size.height / content.height))))
        func axis(_ low: Double, _ length: Double, _ area: Double, _ focus: Double?) -> Double {
            let scaled = length * scale
            if scaled <= area + 0.001 { return (area - scaled) / 2 - low * scale }
            let share = focus.map { min(1, max(0, ($0 - low) / length)) } ?? 0.5
            return share * area - (low + share * length) * scale
        }
        return Viewport(scale: scale, offset: CGPoint(x: axis(content.minX, content.width, size.width, focus.map { Double($0.x) }),
                                                      y: axis(content.minY, content.height, size.height, focus.map { Double($0.y) })))
    }

    /// Moves the view back just enough that at least `keep` points of the content (or all of it,
    /// when smaller) stay inside the area, so panning never loses the whole graph.
    public static func constrained(_ viewport: Viewport, content: CGRect, size: CGSize, keep: Double = 80) -> Viewport {
        func axis(_ offset: Double, _ low: Double, _ high: Double, _ area: Double) -> Double {
            let start = low * viewport.scale + offset, end = high * viewport.scale + offset
            let margin = min(keep, end - start, area)
            if end < margin { return offset + margin - end }
            if start > area - margin { return offset - (start - (area - margin)) }
            return offset
        }
        return Viewport(scale: viewport.scale,
                        offset: CGPoint(x: axis(viewport.offset.x, content.minX, content.maxX, size.width),
                                        y: axis(viewport.offset.y, content.minY, content.maxY, size.height)))
    }

    // MARK: Line geometry

    public struct EdgeGeometry: Equatable, Sendable {
        public let start: CGPoint
        public let control: CGPoint
        /// Where the curve meets the base of the arrowhead.
        public let end: CGPoint
        public let tip: CGPoint
        public let headLeft: CGPoint
        public let headRight: CGPoint
        /// The middle of the curve, for the "?N" capsule.
        public let middle: CGPoint
    }

    public static let nodeRadius = 16.0

    /// The circle and name band of a node: 128pt wide, from 16pt above the circle centre to 42pt below it.
    public static func nodeArea(_ center: CGPoint) -> CGRect {
        CGRect(x: center.x - 64, y: center.y - nodeRadius, width: 128, height: 58)
    }

    /// The warning or speech bubble mark sticks out up to about 27pt from the circle centre at
    /// the upper right, past the 22pt gap of a line end; a marked end keeps this much more room.
    public static let markClearance = 8.0

    /// A quadratic curve that bends to the left of its direction (`bend` > 0), so the two
    /// directions between one pair never overlap. The filled arrowhead is width × 2.5 + 5pt long.
    /// `startClearance` and `endClearance` move a line end further out from a node with a mark.
    public static func geometry(from: CGPoint, to: CGPoint, width: Double, bend: Double,
                                startClearance: Double = 0, endClearance: Double = 0) -> EdgeGeometry? {
        let dx = to.x - from.x, dy = to.y - from.y
        let distance = hypot(dx, dy)
        guard distance > 2 * nodeRadius + 12 + startClearance + endClearance else { return nil }
        let ux = dx / distance, uy = dy / distance
        let amount = min(28, distance * 0.12) * bend
        let control = CGPoint(x: (from.x + to.x) / 2 - uy * amount, y: (from.y + to.y) / 2 + ux * amount)
        let gap = nodeRadius + 6
        let startAngle = atan2(control.y - from.y, control.x - from.x)
        let endAngle = atan2(to.y - control.y, to.x - control.x)
        let start = CGPoint(x: from.x + (gap + startClearance) * cos(startAngle), y: from.y + (gap + startClearance) * sin(startAngle))
        let tip = CGPoint(x: to.x - (gap + endClearance) * cos(endAngle), y: to.y - (gap + endClearance) * sin(endAngle))
        let head = width * 2.5 + 5
        let vx = cos(endAngle), vy = sin(endAngle)
        let base = CGPoint(x: tip.x - vx * head, y: tip.y - vy * head)
        let half = head * 0.45
        let end = CGPoint(x: tip.x - vx * head * 0.8, y: tip.y - vy * head * 0.8)
        let middle = CGPoint(x: 0.25 * start.x + 0.5 * control.x + 0.25 * end.x, y: 0.25 * start.y + 0.5 * control.y + 0.25 * end.y)
        return EdgeGeometry(start: start, control: control, end: end, tip: tip,
                            headLeft: CGPoint(x: base.x - vy * half, y: base.y + vx * half),
                            headRight: CGPoint(x: base.x + vy * half, y: base.y - vx * half), middle: middle)
    }

    /// +1 bends a line to the left of its direction. Two lines that meet at one node and continue
    /// almost straight (within 10 degrees) would read as one line through that node, so the later
    /// one bends to the other side.
    public static func bends(_ edges: [Edge], points: [UUID: CGPoint]) -> [EdgeKey: Double] {
        var result = Dictionary(uniqueKeysWithValues: edges.map { ($0.key, 1.0) })
        func side(_ edge: Edge) -> CGVector? {
            guard let a = points[edge.from], let b = points[edge.to] else { return nil }
            let length = hypot(b.x - a.x, b.y - a.y)
            guard length > 0 else { return nil }
            let sign = result[edge.key] ?? 1
            return CGVector(dx: -(b.y - a.y) / length * sign, dy: (b.x - a.x) / length * sign)
        }
        let straight = cos(170 * Double.pi / 180)
        for (index, second) in edges.enumerated() {
            for first in edges[..<index] {
                let ends: [UUID] = [second.from, second.to]
                guard let shared = ends.first(where: { (end: UUID) -> Bool in first.from == end || first.to == end }),
                      let center = points[shared] else { continue }
                let firstOther: UUID = first.from == shared ? first.to : first.from
                let secondOther: UUID = second.from == shared ? second.to : second.from
                guard firstOther != secondOther, let a = points[firstOther], let c = points[secondOther] else { continue }
                let ux: Double = a.x - center.x, uy: Double = a.y - center.y
                let vx: Double = c.x - center.x, vy: Double = c.y - center.y
                let lengths: Double = hypot(ux, uy) * hypot(vx, vy)
                guard lengths > 0 else { continue }
                let cosine: Double = (ux * vx + uy * vy) / lengths
                guard cosine <= straight, let s1 = side(first), let s2 = side(second) else { continue }
                let sameSide: Bool = s1.dx * s2.dx + s1.dy * s2.dy > 0
                guard sameSide else { continue }
                result[second.key] = -(result[second.key] ?? 1)
            }
        }
        // A line through another member's circle or name band reads as a line to that member,
        // so it bends further on its own side, or to the other side when no reverse line uses it.
        let pairs = Set(edges.map { "\($0.from.uuidString)>\($0.to.uuidString)" })
        for edge in edges {
            guard let from = points[edge.from], let to = points[edge.to] else { continue }
            let others = points.filter { $0.key != edge.from && $0.key != edge.to }.map(\.value)
            let sign = result[edge.key] ?? 1
            guard crossings(from: from, to: to, width: edge.width, bend: sign, nodes: others) > 0 else { continue }
            let steps = [1.5, 2, 3, 4, 6, 8]
            var candidates = steps.map { $0 * sign }
            if !pairs.contains("\(edge.to.uuidString)>\(edge.from.uuidString)") { candidates += ([1] + steps).map { -$0 * sign } }
            var best = (bend: sign, count: Int.max)
            for bend in candidates {
                let count = crossings(from: from, to: to, width: edge.width, bend: bend, nodes: others)
                if count < best.count { best = (bend, count) }
                if count == 0 { break }
            }
            result[edge.key] = best.bend
        }
        return result
    }

    /// How many points along the drawn line, sampled about every 4pt, fall inside the circle and
    /// name band of any of `nodes`, widened by half the line width and 4pt. 0 means it passes clear.
    public static func crossings(from: CGPoint, to: CGPoint, width: Double, bend: Double, nodes: [CGPoint]) -> Int {
        guard let shape = geometry(from: from, to: to, width: width, bend: bend), !nodes.isEmpty else { return 0 }
        let margin = width / 2 + 4
        let areas = nodes.map { nodeArea($0).insetBy(dx: -margin, dy: -margin) }
        let length = hypot(shape.tip.x - shape.start.x, shape.tip.y - shape.start.y) + abs(bend) * 28
        let count = max(16, Int(length / 4))
        var hits = 0
        for index in 0...count {
            let t = Double(index) / Double(count)
            let a = (1 - t) * (1 - t), b = 2 * (1 - t) * t, c = t * t
            let point = CGPoint(x: a * shape.start.x + b * shape.control.x + c * shape.tip.x,
                                y: a * shape.start.y + b * shape.control.y + c * shape.tip.y)
            if areas.contains(where: { $0.contains(point) }) { hits += 1 }
        }
        return hits
    }

    // MARK: Accessibility

    /// One sentence a screen reader reads after the member name: state, records sent and
    /// received per peer, questions waiting for this member's answer and a delivery block.
    public static func accessibilityValue(member: UUID, status: NodeStatus, edges: [Edge], names: [UUID: String]) -> String {
        func list(_ items: [(UUID, Int)]) -> String {
            items.sorted { (names[$0.0] ?? "", $0.0.uuidString) < (names[$1.0] ?? "", $1.0.uuidString) }
                .map { "\(names[$0.0] ?? "이전 구성원") \($0.1)건" }.joined(separator: ", ")
        }
        var parts = [status.phaseTitle]
        let sent = edges.filter { $0.from == member }.map { ($0.to, $0.count) }
        let received = edges.filter { $0.to == member }.map { ($0.from, $0.count) }
        if !sent.isEmpty { parts.append("보냄 " + list(sent)) }
        if !received.isEmpty { parts.append("받음 " + list(received)) }
        let waiting = edges.filter { $0.to == member }.reduce(0) { $0 + $1.pendingQuestions }
        if waiting > 0 { parts.append("답을 기다리는 질문 \(waiting)건") }
        if status.blocked { parts.append("전달 막힘") }
        return parts.joined(separator: ". ")
    }
}
