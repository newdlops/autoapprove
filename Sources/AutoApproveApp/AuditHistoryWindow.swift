import SwiftUI
import AppKit
import AutoApproveCore

struct AuditHistoryWindow: View {
    @ObservedObject var engine: ApprovalEngine
    @State private var search = ""
    @State private var filter: AuditResult?
    @State private var events: [AuditEvent] = []
    @State private var selectedID: String?
    @State private var total = 0
    @State private var offset = 0
    @State private var through = Date()
    @State private var loading = true
    @State private var error: String?
    @State private var requestID = UUID()
    @State private var hasNew = false
    @State private var copied = false
    private var selected: AuditEvent? { events.first { $0.id == selectedID } }
    private var queryKey: String { search + "\u{0}" + (filter?.rawValue ?? "all") }

    var body: some View {
        VStack(spacing: 0) {
            if let error = engine.snapshot.health.auditError ?? error {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        .help("승인 내역을 읽거나 저장하지 못했습니다. 다시 불러오기로 확인하세요.\n" + error)
                    Spacer()
                    Button("다시 불러오기") { reload() }
                        .help("승인 내역을 다시 조회합니다. 저장 오류가 계속되면 새 승인 전달을 진행하지 않습니다.")
                }.padding(12)
                Divider()
            }
            HSplitView {
                VStack(spacing: 12) {
                    HStack {
                        Text("승인 내역").font(.title2.weight(.semibold))
                        Spacer()
                        if loading { ProgressView().controlSize(.small).accessibilityLabel("내역 불러오는 중").help("저장된 승인 내역을 불러오고 있습니다.") }
                        Text("\(total)건").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }.padding(.top, 20)
                    TextField("프로젝트, 명령, 도구, TTY 검색", text: $search)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("승인 내역 검색")
                        .help("저장된 전체 내역에서 프로젝트·요청 내용·도구·TTY·PID를 검색합니다. 세션이 종료된 기록도 포함합니다.")
                    Picker("결과", selection: $filter) {
                        Text("전체 결과").tag(AuditResult?.none)
                        ForEach(AuditResult.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }.pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
                        .help("승인·질문 응답 전달, 결과 확인 필요, 터미널에서 직접 응답하도록 넘긴 요청으로 구분합니다.")
                    if hasNew { Button("새 승인 내역 보기") { reload() }.frame(maxWidth: .infinity, alignment: .leading).help("첫 페이지로 돌아가 새로 저장된 승인 내역을 확인합니다.") }
                    if events.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath").font(.system(size: 28)).foregroundStyle(.secondary)
                                .help(loading ? "저장된 승인 내역을 불러오고 있습니다." : "자동 승인과 질문 응답의 요청 내용·선택한 답·전달 결과를 이곳에서 확인합니다.")
                            Text(loading ? "승인 내역을 불러오고 있습니다…" : (search.isEmpty && filter == nil ? "저장된 승인 내역이 없습니다" : "일치하는 내역이 없습니다")).font(.headline)
                            Text(search.isEmpty && filter == nil ? "자동 승인이 발생하면 이곳에 저장됩니다.\n세션이 종료돼도 계속 확인할 수 있습니다." : "검색어나 결과 필터를 변경해보세요.")
                                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(selection: $selectedID) {
                            ForEach(events) { event in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(event.context?.project ?? "이전 기록").font(.body.weight(.medium)).lineLimit(1)
                                            .help(event.context?.cwd ?? "이전 버전에서 프로젝트 정보를 저장하지 않은 기록입니다.")
                                        Spacer(minLength: 4)
                                        Text(event.result.title).font(.caption.weight(.medium))
                                            .help(AppHelp.result(event.result))
                                    }
                                    Text(event.date.formatted(date: .abbreviated, time: .standard))
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    Text([event.context?.agent.title, event.tool, event.source].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    Text(event.summary.replacingOccurrences(of: "\n", with: " "))
                                        .font(.system(.caption, design: .monospaced)).lineLimit(2)
                                }.padding(.vertical, 6).tag(event.id)
                            }
                        }.listStyle(.inset).id(queryKey + ":" + String(offset)).padding(.horizontal, -8)
                    }
                    Divider()
                    HStack {
                        Text(total == 0 ? "0건" : "\(offset + 1)–\(offset + events.count) / \(total)건")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer()
                        Button("이전") { Task { await load(at: max(0, offset - 100)) } }.disabled(loading || offset == 0)
                            .help(loading ? "승인 내역을 불러오고 있습니다." : (offset == 0 ? "가장 최근 내역을 보고 있습니다." : "현재 페이지보다 최근인 내역을 최대 100건 표시합니다."))
                        Button("다음") { Task { await load(at: offset + 100) } }.disabled(loading || offset + events.count >= total)
                            .help(loading ? "승인 내역을 불러오고 있습니다." : (offset + events.count >= total ? "더 오래된 내역이 없습니다." : "더 오래된 내역을 최대 100건 표시합니다."))
                    }.controlSize(.small).padding(.bottom, 12)
                }.padding(.horizontal, 16).frame(minWidth: 300, idealWidth: 380, maxWidth: 480)
                Group {
                    if let selected { detail(selected) }
                    else { ContentUnavailableView("승인 내역을 선택하세요", systemImage: "doc.text.magnifyingglass", description: Text("요청 내용과 처리 시각, 프로젝트, 전달 결과를 확인할 수 있습니다.")).help("왼쪽 목록에서 내역을 선택하면 전체 요청과 전달한 답변을 볼 수 있습니다.") }
                }.frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 780, minHeight: 560)
        .toolbar {
            Button { reload() } label: { Label("새로고침", systemImage: "arrow.clockwise") }.disabled(loading).keyboardShortcut("r")
                .help(loading ? "승인 내역을 불러오고 있습니다." : "최신 내역을 다시 불러오고 첫 페이지로 돌아갑니다. ⌘R")
        }
        .task(id: queryKey) {
            do { try await Task.sleep(nanoseconds: 180_000_000) } catch { return }
            through = Date(); await load(at: 0)
        }
        .onChange(of: engine.snapshot.events) { _, _ in
            if offset == 0 { reload() } else { hasNew = true }
        }
        .onChange(of: selectedID) { _, _ in copied = false }
    }

    private func detail(_ event: AuditEvent) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(event.result.title, systemImage: event.result == .delivered ? "checkmark.circle" : (event.result == .review ? "exclamationmark.triangle" : "hand.raised"))
                        .font(.callout.weight(.semibold))
                        .help(AppHelp.result(event.result))
                    Text(event.context?.project ?? "프로젝트 정보가 없는 이전 기록").font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text(event.date.formatted(date: .complete, time: .standard)).font(.callout.monospacedDigit()).textSelection(.enabled)
                    Text(event.outcome).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if let answer = event.answer {
                        Text("선택한 답: \(answer)").font(.headline).textSelection(.enabled)
                            .help("AutoApprove가 자동 승인하거나 사용자가 선택·입력해 전달한 답변 원문입니다.")
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    if let context = event.context {
                        Text("\(context.agent.title) · PID \(String(context.pid)) · \(context.tty)").font(.callout).textSelection(.enabled)
                        Text(context.cwd.isEmpty ? "프로젝트 경로 미확인" : context.cwd).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    } else {
                        Text("이전 버전에서 프로젝트·TTY 정보가 저장되지 않은 기록입니다.").font(.callout).foregroundStyle(.secondary)
                    }
                    Text(event.source + (event.tool.map { " · \($0)" } ?? "")).font(.callout).foregroundStyle(.secondary)
                }
                Divider()
                HStack {
                    Text("요청 내용").font(.headline)
                    Spacer()
                    Button(copied ? "복사됨" : "요청 복사") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(event.requestText, forType: .string); copied = true
                    }.controlSize(.small)
                        .help(copied ? "요청 내용을 클립보드에 복사했습니다. 다시 누르면 한 번 더 복사합니다." : "저장된 요청 내용 전체를 클립보드에 복사합니다.")
                }
                Text(event.requestText).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                Divider()
                Text("응답 전달은 승인이나 선택한 답을 보낸 기록입니다. 명령의 실행 성공을 뜻하지 않습니다.").font(.caption).foregroundStyle(.secondary)
                Text("세션 ID: \(event.sessionID)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Color(nsColor: .textBackgroundColor))
    }
    private func reload() { through = Date(); hasNew = false; Task { await load(at: 0) } }
    @MainActor private func load(at newOffset: Int) async {
        let token = UUID(); requestID = token; loading = true
        defer { if requestID == token { loading = false } }
        do {
            let page = try await engine.auditHistory(search: search, result: filter, through: through, offset: newOffset)
            guard requestID == token, !Task.isCancelled else { return }
            events = page.events; total = page.total; offset = newOffset; error = nil
            if !events.contains(where: { $0.id == selectedID }) { selectedID = events.first?.id }
        } catch {
            guard requestID == token, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
