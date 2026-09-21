// THESIS: Manage the agent sessions already open in the user's terminals.
// OWN-WORLD: macOS system surfaces, native lists and switches, restrained semantic color.
// STORY: Find a session, see whether it can be controlled, enable approval, return to work.
// FIRST VIEWPORT: toolbar, searchable session list on the left, request and history on the right.
// FORM: The native split view established in the user-approved DESIGN.md; no new visual direction.
import SwiftUI
import AppKit
import AutoApproveCore

struct SessionWindow: View {
    @ObservedObject var engine: ApprovalEngine
    @ObservedObject var notifications: QuestionNotifications
    @Environment(\.openWindow) private var openWindow
    @State private var selection: Set<String> = []
    @State private var search = ""
    @State private var filter = "전체"
    @State private var settings = false
    @State private var error: String?
    @State private var refreshing = false
    @State private var openingTerminal = false
    private var disconnectedAutomaticCount: Int { engine.snapshot.sessions.filter(\.automaticWaitingForConnection).count }
    private var visible: [AgentSession] {
        engine.snapshot.sessions.filter { session in
            let match = search.isEmpty || "\(session.project) \(session.terminalTitle ?? "") \(session.cwd) \(session.agent.title) \(session.pid) \(session.tty)".localizedCaseInsensitiveContains(search)
            let state: Bool
            switch filter {
            case "대기 중": state = session.phase == .idle
            case "자동 승인": state = session.automatic && session.phase != .ended
            case "연결 필요": state = session.agent != .shell && !session.canApprove && session.phase != .ended
            case "확인 필요": state = session.needsReview
            default: state = session.phase != .ended
            }
            return match && state
        }
    }
    private var emptyTitle: String {
        if !search.isEmpty { return "검색 결과가 없습니다" }
        switch filter {
        case "대기 중": return "대기 중인 터미널이 없습니다"
        case "자동 승인": return "자동 승인을 켠 세션이 없습니다"
        case "확인 필요": return "응답이 필요한 요청이 없습니다"
        case "연결 필요": return "연결이 필요한 세션이 없습니다"
        default: return "표시할 세션이 없습니다"
        }
    }
    private var emptyMessage: String {
        if !search.isEmpty { return "다른 검색어나 필터를 사용해보세요." }
        if filter == "자동 승인" { return "전체 목록에서 세션을 연결하고 자동 승인을 켜세요." }
        if filter == "대기 중" { return "실행 중인 Claude Code·Codex 중 다음 지시를 기다리는 세션이 여기에 표시됩니다." }
        if filter != "전체" { return "전체 필터에서 다른 세션을 확인할 수 있습니다." }
        return "Terminal 또는 VS Code에서 Claude Code나 Codex를 실행하면 여기에 나타납니다."
    }
    var body: some View {
        VStack(spacing: 0) {
            if notifications.authorization == .denied || notifications.error != nil {
                HStack(spacing: 10) {
                    Image(systemName: "bell.slash")
                    Text(notifications.error ?? "응답 알림이 꺼져 있습니다. 질문을 놓치지 않도록 알림을 허용해주세요.")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("알림 설정") { settings = true }.help("응답 알림 권한과 시스템 설정을 확인합니다.")
                }.font(.callout).padding(.horizontal, 20).padding(.vertical, 10).background(Color.orange.opacity(0.10))
            }
            if disconnectedAutomaticCount > 0 {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("자동 승인을 켠 \(disconnectedAutomaticCount)개 세션이 연결되지 않아 요청을 감지할 수 없습니다.")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("연결 설정") { settings = true }
                        .help(AppHelp.connections)
                }.font(.callout).padding(.horizontal, 20).padding(.vertical, 10).background(Color.orange.opacity(0.10))
            }
            if engine.snapshot.paused {
                HStack(spacing: 8) {
                    Image(systemName: "pause.circle.fill")
                    Text("새 자동 승인을 멈췄습니다. 이미 전달 중인 입력과 터미널 작업은 계속됩니다.")
                    Spacer()
                    Button("재개") { perform { try engine.setPaused(false) } }
                        .help(AppHelp.pause(true))
                }.font(.callout).padding(.horizontal, 20).padding(.vertical, 10).background(Color.orange.opacity(0.10))
            }
            if let error = engine.snapshot.health.discoveryError {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = engine.snapshot.health.auditError {
                Label("승인 내역 저장 오류: \(error)", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            HSplitView {
                VStack(spacing: 0) {
                    HStack {
                        Text("세션").font(.title2.weight(.semibold))
                        Text("\(visible.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            .help("현재 검색·필터에 맞는 Claude Code·Codex 세션 수입니다. ⌘ 키를 누르고 클릭하면 여러 세션을 선택할 수 있습니다.")
                        Spacer()
                        Picker("세션 필터", selection: $filter) {
                            ForEach(["전체", "대기 중", "자동 승인", "확인 필요", "연결 필요"], id: \.self) { Text($0) }
                        }.labelsHidden().frame(width: 110)
                            .help("대기 중, 자동 승인, 응답 확인, 연결 필요 상태별로 세션을 좁혀 봅니다.")
                    }.padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 12)
                    HStack(spacing: 12) {
                        Button { filter = "대기 중" } label: {
                            Label("대기 중 \(engine.snapshot.idleCount)개", systemImage: "checkmark.circle")
                        }.buttonStyle(.borderless).help("다음 지시를 기다리는 Claude Code·Codex 보기")
                        Text("작업 중 \(engine.snapshot.sessions.filter { $0.phase == .working }.count)개").foregroundStyle(.secondary)
                            .help("현재 작업을 진행 중인 것으로 감지한 Claude Code·Codex 세션 수입니다.")
                        Spacer(minLength: 0)
                    }.font(.caption).padding(.horizontal, 16).padding(.bottom, 12)
                    TextField("프로젝트, 터미널 제목, TTY, PID 검색", text: $search)
                        .textFieldStyle(.roundedBorder).padding(.horizontal, 16).padding(.bottom, 12)
                        .accessibilityLabel("세션 검색")
                        .help(AppHelp.search)
                    if !engine.initialDiscoveryComplete && engine.snapshot.sessions.isEmpty {
                        ProgressView("실행 중인 세션을 찾고 있습니다…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if visible.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: search.isEmpty ? "terminal" : "magnifyingglass").font(.system(size: 30)).foregroundStyle(.secondary)
                            Text(emptyTitle).font(.headline)
                            Text(emptyMessage)
                                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(selection: $selection) {
                            ForEach(visible) { session in
                                SessionRow(session: session, paused: engine.snapshot.paused) { enabled in perform { try engine.setAutomatic(session.id, enabled: enabled) } }
                                    .tag(session.id)
                                    .padding(.vertical, 6)
                            }
                        }.listStyle(.inset)
                    }
                    Divider()
                    HStack {
                        Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                        Text("이 Mac의 터미널").foregroundStyle(.secondary)
                        Spacer()
                        Text("로컬 연결").foregroundStyle(.secondary)
                    }.font(.caption).padding(12)
                }.frame(minWidth: 300, idealWidth: 380, maxWidth: 500)
                detail.frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 780, minHeight: 560)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { openWindow(id: "history") } label: { Label("승인 내역", systemImage: "clock.arrow.circlepath") }
                    .help(AppHelp.history)
                Button { settings = true } label: { Label("연결 설정", systemImage: "point.3.connected.trianglepath.dotted") }
                    .help(AppHelp.connections)
                Button {
                    refreshing = true
                    Task { await engine.refresh(); refreshing = false }
                } label: { Label("새로고침", systemImage: "arrow.clockwise") }
                .disabled(refreshing).keyboardShortcut("r").help(refreshing ? "세션과 연결 상태를 확인하고 있습니다." : "실행 중인 세션과 연결 상태를 지금 다시 확인합니다. ⌘R")
                Button { perform { try engine.setPaused(!engine.snapshot.paused) } } label: {
                    Label(engine.snapshot.paused ? "재개" : "일시정지", systemImage: engine.snapshot.paused ? "play.fill" : "pause.fill")
                }.help(AppHelp.pause(engine.snapshot.paused))
            }
        }
        .sheet(isPresented: $settings) { ConnectionSettings(engine: engine, notifications: notifications) }
        .alert("요청을 처리하지 못했습니다", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("확인") { error = nil }
        } message: { Text(error ?? "") }
        .onChange(of: visible.map(\.id)) { _, ids in
            selection.formIntersection(ids)
            if selection.isEmpty, let first = ids.first { selection = [first] }
        }
    }
    @ViewBuilder private var detail: some View {
        if selection.count > 1 {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(selection.count)개 세션 선택됨").font(.title2.weight(.semibold))
                Text("연결된 세션의 자동 승인을 함께 변경합니다.").foregroundStyle(.secondary)
                HStack {
                    Button("자동 승인 켜기") { for id in selection where engine.snapshot.sessions.first(where: { $0.id == id })?.canApprove == true { perform { try engine.setAutomatic(id, enabled: true) } } }
                        .disabled(!engine.snapshot.sessions.contains { selection.contains($0.id) && $0.canApprove })
                        .help("선택한 연결 세션의 자동 승인을 켭니다. Claude 훅의 명확한 예·아니오 질문에는 ‘예’로 답하며, 그 밖의 선택 질문은 알림으로 알려줍니다.")
                    Button("자동 승인 끄기") { for id in selection { perform { try engine.setAutomatic(id, enabled: false) } } }
                        .disabled(!engine.snapshot.sessions.contains { selection.contains($0.id) && $0.automatic })
                        .help("선택한 모든 세션의 자동 승인을 끕니다. 진행 중인 작업은 계속됩니다.")
                }
                Spacer()
            }.padding(24)
        } else if let id = selection.first, let session = engine.snapshot.sessions.first(where: { $0.id == id }) {
            SessionDetail(session: session, events: engine.snapshot.events.filter { $0.sessionID == id }, paused: engine.snapshot.paused, openingTerminal: openingTerminal,
                          setAutomatic: { enabled in perform { try engine.setAutomatic(id, enabled: enabled) } },
                          reveal: { reveal(session) }, connect: { settings = true }, showHistory: { openWindow(id: "history") },
                          dismissQuestion: { questionID in perform { try engine.dismissQuestion(sessionID: id, questionID: questionID) } },
                          replyQuestion: { questionID, answer in try await engine.replyToQuestion(sessionID: id, questionID: questionID, answer: answer) })
        } else {
            ContentUnavailableView { Label("터미널 작업을 한곳에서", systemImage: "terminal") } description: {
                Text("세션을 선택해 상태를 확인하고 자동 승인을 켜세요.\n처음 사용하는 경우 연결 설정부터 시작하세요.")
            } actions: { Button("연결 설정 열기") { settings = true }.help(AppHelp.connections) }
        }
    }
    private func perform(_ operation: () throws -> Void) { do { try operation() } catch { self.error = error.localizedDescription } }
    private func reveal(_ session: AgentSession) {
        guard !openingTerminal else { return }
        openingTerminal = true
        Task {
            defer { openingTerminal = false }
            do {
                try await TerminalNavigator.open(session, engine: engine)
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct SessionRow: View {
    let session: AgentSession
    let paused: Bool
    let setAutomatic: (Bool) -> Void
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(session.project).font(.body.weight(.medium)).lineLimit(1)
                    .help(session.cwd.isEmpty ? "프로젝트 경로를 확인하고 있습니다." : session.cwd)
                Text(session.terminalTitle ?? "터미널 제목 미확인")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    .help(session.terminalTitle ?? "터미널을 연결하면 창 또는 탭의 제목을 표시합니다.")
                HStack(spacing: 6) {
                    Text(session.agent.title)
                    Text("·")
                    Text(session.terminal.title)
                }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text("\(session.tty.replacingOccurrences(of: "/dev/", with: "")) · PID \(String(session.pid))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    .help("\(session.tty) · PID \(String(session.pid))\n같은 프로젝트의 여러 터미널을 구분하는 식별자입니다.")
                PhaseLabel(session: session).font(.caption)
                if !session.unansweredQuestions.isEmpty {
                    Label("질문 대기 \(session.unansweredQuestions.count)건", systemImage: "bubble.left.and.bubble.right")
                        .font(.caption.weight(.medium))
                        .help("작업 중에도 답변을 기다리는 Codex 질문입니다. 세션 상세에서 모두 확인할 수 있습니다.")
                } else if session.questions.contains(where: { $0.reply?.phase == .sending }) {
                    Label("답변 전송 중", systemImage: "arrow.up.circle").font(.caption)
                }
            }
            Spacer(minLength: 4)
            if session.agent != .shell {
                Toggle("\(session.project) 자동 승인", isOn: Binding(get: { session.automatic }, set: setAutomatic))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!session.canApprove && !session.automatic).help(AppHelp.automatic(session, paused: paused))
            }
        }.accessibilityElement(children: .contain)
    }
}

struct PhaseLabel: View {
    let session: AgentSession
    var body: some View {
        Label(session.automaticWaitingForConnection ? "연결 필요 · 자동 승인 대기" : session.phase.title, systemImage: symbol).foregroundStyle(color)
            .help(AppHelp.phase(session))
    }
    private var symbol: String {
        if session.automaticWaitingForConnection { return "exclamationmark.triangle" }
        switch session.phase { case .approval, .input: return "hand.raised"; case .working: return "bolt"; case .idle: return "checkmark.circle"; case .ended: return "stop.circle"; case .unknown: return "circle.dashed" }
    }
    private var color: Color {
        if session.automaticWaitingForConnection { return .orange }
        switch session.phase { case .approval, .input: return .orange; case .working: return .primary; case .idle: return .green; case .ended, .unknown: return .secondary }
    }
}

private struct SessionDetail: View {
    let session: AgentSession
    let events: [AuditEvent]
    let paused: Bool
    let openingTerminal: Bool
    let setAutomatic: (Bool) -> Void
    let reveal: () -> Void
    let connect: () -> Void
    let showHistory: () -> Void
    let dismissQuestion: (String) -> Void
    let replyQuestion: (String, String) async throws -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(session.agent.title).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                        Spacer()
                        Button(action: reveal) { Label(openingTerminal ? "여는 중…" : "터미널 열기", systemImage: "arrow.up.forward.app") }.controlSize(.small)
                            .disabled(!session.canReveal || openingTerminal)
                            .help(AppHelp.reveal(session, opening: openingTerminal))
                    }
                    Text(session.project).font(.title.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                        .help(session.cwd.isEmpty ? "프로젝트 경로 미확인" : session.cwd)
                    Text(session.terminalTitle ?? "터미널 제목 미확인")
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(session.cwd.isEmpty ? "프로젝트 경로를 확인하지 못했습니다." : session.cwd)
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 16) { PhaseLabel(session: session); Text("PID \(session.pid)").monospacedDigit().foregroundStyle(.secondary).help(AppHelp.pid); Text(session.terminal.title).foregroundStyle(.secondary) }.font(.callout)
                    if !session.tty.isEmpty {
                        Text(session.tty).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            .help(AppHelp.tty)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    if let since = session.idleSince, session.phase == .idle {
                        HStack(spacing: 5) {
                            Text("대기 감지 후")
                            Text(since, style: .relative).monospacedDigit()
                        }.font(.callout.weight(.medium))
                            .help("앱이 이번 입력 대기를 감지한 뒤의 시간입니다. 앱 재실행 전의 대기 시간은 포함하지 않습니다.")
                    }
                    Text(session.activityDetail ?? "연결 후 작업 상태를 확인할 수 있습니다.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                if session.agent == .codex {
                    CodexQuestionList(session: session, openingTerminal: openingTerminal, dismiss: dismissQuestion,
                        reply: replyQuestion, reveal: reveal)
                    Divider()
                }
                if session.agent == .shell {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("일반 터미널").font(.headline)
                        Text("이 터미널에서 Claude Code나 Codex를 실행하면 도구의 상태와 자동 승인 설정이 표시됩니다.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if session.terminal == .vscode && !session.canReveal {
                            Button("VS Code 연결 설정") { connect() }
                                .help(AppHelp.connections)
                        }
                    }
                } else {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("자동 승인", isOn: Binding(get: { session.automatic }, set: setAutomatic))
                        .font(.headline).toggleStyle(.switch).disabled(!session.canApprove && !session.automatic)
                        .help(AppHelp.automatic(session, paused: paused))
                    Text(session.canApprove ? (paused ? "전체 일시정지 중입니다. 재개하면 자동 승인이 적용됩니다." : "실행·파일 변경 권한과 Claude 훅의 예·아니오 질문을 자동 승인합니다. 그 밖의 선택 질문은 알림을 눌러 답해주세요.") : "승인 요청을 처리하려면 연결이 필요합니다.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Label(session.channel.title, systemImage: session.canApprove ? "link" : "link.badge.plus")
                        .font(.callout.weight(.medium))
                        .help(AppHelp.channel(session.channel))
                    Text(session.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !session.canApprove { Button("연결 설정") { connect() }.help(AppHelp.connections) }
                }
                if let pending = session.pendingSummary {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("현재 요청").font(.headline)
                        Text(pending).font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        if session.pendingInTerminal {
                            Text(session.phase == .input ? "터미널에서 질문에 답해주세요." : "현재 요청은 터미널에서 확인해주세요.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if !session.automatic || paused { Text("원래 터미널에서 응답할 수 있습니다.").font(.caption).foregroundStyle(.secondary) }
                        Button(action: reveal) { Label(openingTerminal ? "여는 중…" : "터미널에서 답하기", systemImage: "arrow.up.forward.app") }
                            .disabled(!session.canReveal || openingTerminal).help(AppHelp.reveal(session, opening: openingTerminal))
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("최근 승인 내역").font(.headline)
                        Spacer()
                        Button("전체 내역 보기", action: showHistory).controlSize(.small)
                            .help(AppHelp.history)
                    }
                    if events.isEmpty {
                        Text("아직 처리한 요청이 없습니다.\n이 세션에서 발생한 승인 내역이 여기에 표시됩니다.").font(.callout).foregroundStyle(.secondary).lineSpacing(4)
                    }
                    ForEach(events.prefix(40)) { event in
                        ApprovalEventDisclosure(event: event)
                        if event.id != events.prefix(40).last?.id { Divider() }
                    }
                }
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Color(nsColor: .textBackgroundColor))
    }
}

struct ApprovalEventDisclosure: View {
    let event: AuditEvent
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(event.source + (event.tool.map { " · " + $0 } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                    if let answer = event.answer {
                        Text("전달한 답변: \(answer)").font(.callout.weight(.medium)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("전체 요청").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(event.requestText).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(AppHelp.result(event.result)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 8).padding(.bottom, 4).frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(event.outcome).font(.callout.weight(.medium))
                    Spacer(minLength: 4)
                    Text(event.date, style: .time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .help(event.date.formatted(date: .complete, time: .standard))
                }.contentShape(Rectangle()).onTapGesture { expanded.toggle() }
            }.help(expanded ? "눌러서 요청 상세를 접습니다." : "눌러서 전체 요청과 전달한 답변을 펼칩니다.")
            if !expanded {
                Text(event.summary).font(.system(.caption, design: .monospaced)).lineLimit(2)
                    .foregroundStyle(.secondary).padding(.leading, 16)
            }
        }
    }
}

struct CodexQuestionList: View {
    let session: AgentSession
    let openingTerminal: Bool
    let dismiss: (String) -> Void
    let reply: (String, String) async throws -> Void
    let reveal: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("질문 대기열").font(.headline)
                Text("응답 대기 \(session.unansweredQuestions.count)건").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                if session.questions.contains(where: { $0.reply?.phase == .queued }) {
                    Text("전달 대기 \(session.questions.filter { $0.reply?.phase == .queued }.count)건")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let error = session.codexQuestionsError {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if !session.questions.isEmpty {
                    Text("마지막으로 수집한 질문입니다. 연결이 복구되면 갱신합니다.").font(.caption).foregroundStyle(.secondary)
                }
            } else if session.codexQuestionsObservedAt == nil {
                HStack { ProgressView().controlSize(.small); Text("Codex 질문 기록을 확인하고 있습니다…").font(.callout).foregroundStyle(.secondary) }
            } else if session.questions.isEmpty {
                Text("답변을 기다리는 질문이 없습니다.").font(.callout).foregroundStyle(.secondary)
            }
            if !session.questions.isEmpty {
                if !session.unansweredQuestions.isEmpty {
                Text("선택지를 고르거나 직접 답변을 입력하세요. 답변은 Codex가 받을 차례가 되면 전달됩니다.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .help("Codex 기록에서 비동기 질문과 그 질문을 인용한 답변을 수집합니다. 일반 메시지나 작업 재개만으로 질문을 지우지 않습니다.")
                }
                ForEach(session.questions) { question in
                    QuestionReplyEditor(question: question, connectionError: session.codexQuestionsError,
                        canReveal: session.canReveal, openingTerminal: openingTerminal,
                        send: { answer in try await reply(question.id, answer) }, dismiss: { dismiss(question.id) }, reveal: reveal)
                    if question.id != session.questions.last?.id { Divider() }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct QuestionReplyEditor: View {
    let question: QueuedQuestion
    let connectionError: String?
    let canReveal: Bool
    let openingTerminal: Bool
    let send: (String) async throws -> Void
    let dismiss: () -> Void
    let reveal: () -> Void
    @State private var selected = Set<Int>()
    @State private var customAnswer = ""
    @State private var submitting = false
    @State private var error: String?
    private var answer: String {
        (question.options.enumerated().filter { selected.contains($0.offset) }.map(\.element)
            + [customAnswer.trimmingCharacters(in: .whitespacesAndNewlines)]).filter { !$0.isEmpty }.joined(separator: "\n")
    }
    private var editing: Bool { question.reply == nil || question.reply?.canRetry == true }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.title).font(.callout.weight(.medium)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if editing && connectionError == nil {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    Toggle(isOn: Binding(get: { selected.contains(index) }, set: { if $0 { selected.insert(index) } else { selected.remove(index) } })) {
                        Text(option).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }.toggleStyle(.checkbox).disabled(submitting)
                }
                if question.options.count > 1 {
                    Text("여러 항목을 함께 선택할 수 있습니다.").font(.caption).foregroundStyle(.secondary)
                }
                TextField(question.options.isEmpty ? "답변을 입력하세요" : "직접 답변하거나 설명을 덧붙이세요", text: $customAnswer, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...5).disabled(submitting)
                    .accessibilityLabel("\(question.title) 직접 답변")
            } else if connectionError != nil && editing {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    Text("\(index + 1). \(option)").font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let reply = question.reply {
                if reply.phase == .sending {
                    HStack { ProgressView().controlSize(.small); Text("답변을 보내고 있습니다…").font(.callout) }
                } else {
                    Label(reply.message, systemImage: reply.phase == .queued ? "clock.badge.checkmark" : "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(reply.phase == .queued ? Color.primary : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !editing { Text("답변: \(reply.answer)").font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { actions }
                VStack(alignment: .leading, spacing: 8) { actions }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private var actions: some View {
        if editing && connectionError == nil {
            Button("답변 보내기") {
                guard !submitting else { return }
                submitting = true; error = nil
                let text = answer
                Task {
                    defer { submitting = false }
                    do { try await send(text) } catch { self.error = error.localizedDescription }
                }
            }.buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(answer.isEmpty || submitting)
                .help("선택한 항목과 입력한 답변을 이 Codex 대화에 보냅니다. 전송 내용을 승인 내역에 저장합니다.")
        }
        Button(action: reveal) { Label(openingTerminal ? "여는 중…" : "터미널에서 답하기", systemImage: "arrow.up.forward.app") }
            .controlSize(.small).disabled(!canReveal || openingTerminal || submitting)
            .help(canReveal ? "해당 터미널을 열고 강조 표시합니다." : "터미널 연결이 필요합니다. 연결 설정을 확인해주세요.")
        Button("목록에서 정리", action: dismiss).controlSize(.small)
            .disabled(submitting || question.reply?.phase == .sending)
            .help("이미 처리한 질문을 AutoApprove 목록에서 정리합니다. Codex에 답변을 보내지는 않습니다.")
    }
}
