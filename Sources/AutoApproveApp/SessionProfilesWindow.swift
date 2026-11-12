// THESIS: Save each CLI conversation once, then reopen the chosen workspace after a restart.
// FORM: The existing native split list, system controls and restrained semantic feedback.
import SwiftUI
import AutoApproveCore

struct SessionProfilesWindow: View {
    @ObservedObject var controller:SessionProfilesController
    var body:some View {
        VStack(spacing:0) {
            if let error=controller.error {
                HStack(alignment:.top,spacing:10) {
                    Label(error,systemImage:"exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
                    Spacer(minLength:4)
                    Button("닫기") {controller.error=nil}.help("오류 안내를 닫습니다.")
                }.font(.callout).padding(12)
                Divider()
            }
            HSplitView {
                VStack(alignment:.leading,spacing:12) {
                    HStack {
                        Text("세션 프로필").font(.title2.weight(.semibold))
                        Spacer(minLength:4)
                        if controller.loading {ProgressView().controlSize(.small).accessibilityLabel("프로필 불러오는 중")}
                    }.padding(.horizontal,16).padding(.top,20)
                    Text("작업 폴더와 CLI, 이어갈 대화를 파일로 저장합니다.").font(.callout).foregroundStyle(.secondary).padding(.horizontal,16)
                    if controller.profiles.isEmpty {
                        VStack(alignment:.leading,spacing:8) {
                            Text(controller.loading ? "프로필을 불러오고 있습니다…":"저장한 프로필이 없습니다").font(.headline)
                            Text("현재 Codex·Claude Code 창을 불러와 첫 프로필을 만드세요.").font(.callout).foregroundStyle(.secondary)
                        }.padding(16)
                        Spacer()
                    } else {
                        List(selection:$controller.selectedID) {
                            ForEach(controller.profiles) {profile in
                                VStack(alignment:.leading,spacing:5) {
                                    Text(profile.name).font(.body.weight(.medium)).lineLimit(2).help(profile.name)
                                    Text("세션 \(profile.entries.count)개").font(.caption).foregroundStyle(.secondary)
                                    Text(profile.savedAt.formatted(date:.abbreviated,time:.shortened)).font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical,6).tag(profile.id)
                            }
                        }.listStyle(.inset).disabled(controller.busy || controller.loading)
                    }
                }.frame(minWidth:210,idealWidth:245,maxWidth:300)
                Group {
                    if let profile=controller.selected {detail(profile)}
                    else {
                        ContentUnavailableView {
                            Label("창별 대화를 다시 여세요",systemImage:"terminal")
                        } description: {
                            Text("현재 세션을 프로필로 저장하면 재부팅 뒤 같은 폴더에서 CLI를 열 수 있습니다. 대화 ID를 저장하면 해당 대화를 이어갑니다.")
                        } actions: {
                            Button("현재 세션으로 새 프로필") {Task {await controller.captureCurrent()}}.disabled(controller.busy)
                        }
                    }
                }.frame(minWidth:400,maxWidth:.infinity,maxHeight:.infinity)
            }
            if controller.busy || controller.message != nil {
                Divider()
                HStack(spacing:10) {
                    if controller.busy {ProgressView().controlSize(.small)}
                    Text(controller.message ?? "현재 창의 대화 정보를 확인하고 있습니다…").font(.callout).textSelection(.enabled)
                    Spacer(minLength:0)
                }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
            }
        }.frame(minWidth:700,minHeight:480)
        .toolbar {
            ToolbarItemGroup(placement:.primaryAction) {
                Button {Task {await controller.captureCurrent()}} label: {Label("새 프로필",systemImage:"plus")}
                    .keyboardShortcut("n").disabled(controller.busy).help("현재 Mac의 Codex·Claude Code 창을 새 프로필 파일로 저장합니다.")
                Button("가져오기",systemImage:"square.and.arrow.down") {controller.importProfile()}.disabled(controller.busy)
                    .help("저장한 세션 프로필 JSON 파일을 가져옵니다. 실행 전에 내용을 확인합니다.")
                Button("프로필 폴더",systemImage:"folder") {Task {await controller.openFolder()}}
                    .help("프로필별로 저장된 JSON 파일을 Finder에서 엽니다.")
                Button("새로고침",systemImage:"arrow.clockwise") {Task {await controller.reload()}}.disabled(controller.busy || controller.loading)
                    .help("프로필 파일 목록을 다시 읽습니다.")
            }
        }
        .task {await controller.reload()}
        .sheet(item:$controller.draft) {draft in
            SessionProfileEditor(draft:draft,save:controller.save,cancel:{controller.draft=nil})
        }
    }
    private func detail(_ profile:TerminalSessionProfile) -> some View {
        VStack(alignment:.leading,spacing:12) {
            HStack(alignment:.top) {
                VStack(alignment:.leading,spacing:6) {
                    Text(profile.name).font(.title2.weight(.semibold)).lineLimit(3).textSelection(.enabled)
                    Text("세션 \(profile.entries.count)개 · \(profile.savedAt.formatted(date:.abbreviated,time:.shortened)) 저장")
                        .font(.callout).foregroundStyle(.secondary)
                    if !profile.terminalLayoutSummary.isEmpty {Text(profile.terminalLayoutSummary).font(.callout).foregroundStyle(.secondary)}
                }
                Spacer(minLength:8)
                Menu {
                    Button("프로필 편집") {controller.edit(profile)}
                    Button("현재 창으로 갱신…") {Task {await controller.captureCurrent(replacing:profile)}}
                    Button("파일 내보내기…") {controller.export(profile)}
                    Button("Finder에서 파일 보기") {controller.reveal(profile)}
                    Divider()
                    Button("휴지통으로 이동",role:.destructive) {Task {await controller.trash(profile)}}
                } label: {Image(systemName:"ellipsis.circle")}.menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("프로필 관리").help("이름·대화 편집, 현재 창으로 갱신, 파일 내보내기 또는 휴지통 이동")
                    .disabled(controller.busy)
            }
            entryControls(profile)
            if controller.visibleEntries.isEmpty {
                ContentUnavailableView {
                    Label("조건에 맞는 세션이 없습니다",systemImage:"line.3.horizontal.decrease.circle")
                } description: {Text("창·도구·레포 또는 검색어를 바꿔보세요.")}
                actions: {Button("필터 초기화") {controller.entryFilter = .init()}.disabled(controller.busy)}
            } else {List(controller.visibleEntries) {entry in
                VStack(alignment:.leading,spacing:6) {
                    Toggle(isOn:Binding(get:{controller.selectedEntries.contains(entry.id)},set:{if $0 {controller.selectedEntries.insert(entry.id)} else {controller.selectedEntries.remove(entry.id)}})) {
                        Text(entry.title.isEmpty ? entry.agent:entry.title).font(.body.weight(.medium)).lineLimit(2)
                    }.toggleStyle(.checkbox).disabled(controller.busy || controller.loading)
                        .accessibilityLabel("\(entry.agent == "codex" ? "Codex":"Claude") · \(entry.title) · \(SessionProfileEntryFilter.windowPosition(entry)) · \(entry.cwd)")
                    Text((entry.agent == "codex" ? "Codex":"Claude Code")+" · "+(entry.host == .iterm ? "iTerm2":"Terminal")+" · "+SessionProfileEntryFilter.windowPosition(entry))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(entry.cwd).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled).help(entry.cwd)
                    Label {
                        Text(entry.resumesConversation ? "저장한 대화 이어가기":"새 CLI 실행 · 이전 대화는 복원하지 않음")
                            .foregroundStyle(entry.resumesConversation ? Color.secondary:Color.primary)
                    } icon: {
                        Image(systemName:entry.resumesConversation ? "bubble.left":"terminal")
                            .foregroundStyle(entry.resumesConversation ? Color.secondary:Color.orange)
                    }.font(.caption)
                    DisclosureGroup("대화·창 정보") {
                        VStack(alignment:.leading,spacing:4) {
                            if !entry.terminalTabSummary.isEmpty {Text(entry.terminalTabSummary).help(entry.terminalTabSummary)}
                            if let home=entry.providerHome {Text("CLI 설정 폴더: "+home).textSelection(.enabled)}
                            if entry.resumesConversation {Text(entry.conversationID).font(.system(.caption,design:.monospaced)).textSelection(.enabled)}
                            else {Text("새 CLI 실행")}
                        }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }.font(.caption).foregroundStyle(.secondary)
                    if let result=controller.results[entry.id] {
                        Label(result.detail,systemImage:result.phase == .opened ? "checkmark.circle":result.phase == .alreadyOpen ? "arrow.uturn.forward.circle":"exclamationmark.triangle")
                            .font(.callout).foregroundStyle(result.phase == .failed ? Color.red:Color.primary)
                    }
                }.padding(.vertical,8)
            }.listStyle(.inset).padding(.horizontal,-8)}
            Divider()
            HStack(spacing:10) {
                Button(controller.selectedVisibleIDs.count == controller.visibleEntries.count ? "표시 항목 해제":"표시 항목 선택") {
                    controller.selectVisible(controller.selectedVisibleIDs.count != controller.visibleEntries.count)
                }.disabled(controller.busy || controller.loading || controller.resolvingRepositories || controller.visibleEntries.isEmpty)
                Spacer(minLength:4)
                Button("선택한 \(controller.selectedVisibleIDs.count)개 복원") {Task {await controller.restoreSelection()}}
                    .keyboardShortcut("r",modifiers:[.command,.shift]).disabled(!controller.canRestoreSelection)
                    .help("현재 필터에 표시된 선택 항목만 복원합니다. 이미 실행 중인 대화는 건너뜁니다. ⌘⇧R")
            }
        }.padding(20)
    }
    private func entryControls(_ profile:TerminalSessionProfile) -> some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(spacing:10) {
                Picker("복원할 도구",selection:$controller.entryFilter.agent) {
                    ForEach(SessionProfileEntryFilter.Agent.allCases,id:\.self) {Text($0.rawValue).tag($0)}
                }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("복원할 도구").frame(width:192)
                Picker("저장된 창",selection:$controller.entryFilter.window) {
                    Text("모든 창").tag("")
                    ForEach(controller.windowChoices) {Text($0.title).tag($0.id)}
                    if !controller.entryFilter.window.isEmpty && !controller.windowChoices.contains(where:{$0.id == controller.entryFilter.window}) {
                        Text("선택한 창 · 현재 없음").tag(controller.entryFilter.window)
                    }
                }.labelsHidden().frame(minWidth:0,maxWidth:.infinity).accessibilityLabel("복원할 저장된 창")
                    .help("저장 시점의 창 번호입니다. 항목 수는 전체 저장 프로필 기준이며 도구·레포·검색과 함께 적용됩니다. 창 정보가 없는 기록은 별도로 표시합니다.")
            }
            HStack(spacing:8) {
                Image(systemName:"magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("이름·레포·폴더·대화 ID 검색",text:$controller.entryFilter.query)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("복원할 세션 검색")
                if !controller.entryFilter.query.isEmpty {Button {controller.entryFilter.query=""} label:{Image(systemName:"xmark.circle.fill")}
                    .buttonStyle(.plain).accessibilityLabel("검색어 지우기")}
            }
            HStack(spacing:10) {
                Picker("레포/작업 폴더",selection:$controller.entryFilter.repository) {
                    Text("모든 레포/작업 폴더").tag("")
                    ForEach(controller.repositoryChoices,id:\.self) {path in
                        Text((path as NSString).lastPathComponent+" · "+((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath).tag(path)
                    }
                    if !controller.entryFilter.repository.isEmpty && !controller.repositoryChoices.contains(controller.entryFilter.repository) {
                        Text(controller.entryFilter.repository+" · 현재 없음").tag(controller.entryFilter.repository)
                    }
                }.labelsHidden().frame(minWidth:0,maxWidth:.infinity).help(controller.entryFilter.repository.isEmpty ? "같은 레포의 하위 폴더를 함께 고릅니다. Git 표식이 없으면 저장된 작업 폴더로 구분합니다.":controller.entryFilter.repository)
                    .accessibilityLabel("레포 또는 작업 폴더")
                Picker("정렬",selection:$controller.entryFilter.order) {
                    ForEach(SessionProfileEntryFilter.Order.allCases,id:\.self) {Text($0.rawValue).tag($0)}
                }.frame(width:125).help("목록의 정렬 기준입니다. 복원할 때는 저장된 창·탭 순서를 유지합니다.")
                Button {controller.entryFilter.ascending.toggle()} label: {Image(systemName:controller.entryFilter.ascending ? "arrow.up":"arrow.down")}
                    .accessibilityLabel(controller.entryFilter.ascending ? "오름차순 · 내림차순으로 변경":"내림차순 · 오름차순으로 변경")
                    .help("정렬 방향 전환")
            }
            HStack {
                Text(controller.resolvingRepositories ? "레포 확인 중…":"표시 \(controller.visibleEntries.count)/\(profile.entries.count)개 · 선택 \(controller.selectedVisibleIDs.count)개")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer(minLength:4)
                if controller.entryFilter.active {Button("필터 초기화") {controller.entryFilter = .init()}.font(.caption)}
            }
            Text("복원은 현재 표시된 선택 항목에만 적용됩니다.").font(.caption).foregroundStyle(.secondary)
        }.disabled(controller.busy || controller.loading || controller.resolvingRepositories)
    }
}

private struct ProfileDraftRow:Identifiable {
    var id:String
    var included=true
    var entry:TerminalProfileEntry
    var choices:[CodexProfileConversation]
    var detail:String?
    var startsNewCLI=false
}

struct SessionProfileEditor:View {
    let draft:SessionProfileDraft
    let save:(TerminalSessionProfile) async throws -> Void
    let cancel:()->Void
    @State private var name:String
    @State private var rows:[ProfileDraftRow]
    @State private var saving=false
    @State private var error:String?
    @FocusState private var nameFocused:Bool
    init(draft:SessionProfileDraft,save:@escaping (TerminalSessionProfile) async throws -> Void,cancel:@escaping ()->Void) {
        self.draft=draft;self.save=save;self.cancel=cancel
        _name=State(initialValue:draft.name)
        _rows=State(initialValue:draft.candidates.map {.init(id:$0.id,entry:$0.entry,choices:$0.conversations,detail:$0.detail)})
    }
    private var profile:TerminalSessionProfile {get throws {
        let included=rows.filter(\.included)
        return try TerminalSessionProfile(id:draft.profileID,name:name,entries:included.map(\.entry))
            .validatedForSaving(newCLIIDs:Set(included.filter(\.startsNewCLI).map { $0.entry.id }))
    }}
    private var validationError:String? {
        do {_ = try profile;return nil} catch {return error.localizedDescription}
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("세션 프로필 저장").font(.title2.weight(.semibold))
            Text("기존 작업을 복원하려면 이어갈 대화를 저장하세요. 새 대화를 시작하려는 항목만 ‘새 CLI 실행’을 선택하세요.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            HStack {
                Text("프로필 이름")
                TextField("예: 업무 개발, 개인 프로젝트",text:$name).textFieldStyle(.roundedBorder).focused($nameFocused)
                    .accessibilityLabel("프로필 이름").help("이름이 다른 프로필을 여러 개 저장할 수 있습니다. 최대 80자")
            }
            Divider()
            ScrollView {
                LazyVStack(alignment:.leading,spacing:16) {
                    ForEach($rows) {$row in
                        VStack(alignment:.leading,spacing:8) {
                            Toggle(row.entry.title.isEmpty ? row.entry.agent:row.entry.title,isOn:$row.included)
                                .toggleStyle(.checkbox).font(.headline)
                            VStack(alignment:.leading,spacing:8) {
                                HStack {
                                    Text(row.entry.agent == "codex" ? "Codex":"Claude Code").font(.callout)
                                    Spacer(minLength:8)
                                    Picker("복원 앱",selection:$row.entry.host) {
                                        Text("Terminal").tag(TerminalProfileEntry.Host.terminal)
                                        Text("iTerm2").tag(TerminalProfileEntry.Host.iterm)
                                    }.frame(width:180)
                                }
                                if !row.entry.terminalTabSummary.isEmpty {
                                    Text(row.entry.terminalTabSummary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                                }
                                TextField("작업 폴더",text:$row.entry.cwd).textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("\(row.entry.title) 작업 폴더").help("이 대화를 다시 열 작업 폴더의 전체 경로")
                                if let home=row.entry.providerHome {Text("CLI 설정 폴더: "+home).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)}
                                Picker("복원 방식",selection:$row.startsNewCLI) {
                                    Text("대화 이어가기").tag(false)
                                    Text("새 CLI 실행").tag(true)
                                }.accessibilityLabel("\(row.entry.title) 복원 방식")
                                if row.startsNewCLI {
                                    Text("저장한 폴더에서 새 CLI를 엽니다. 이전 대화는 복원하지 않습니다.")
                                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                                } else {
                                if !row.choices.isEmpty {
                                    Picker("복원할 대화",selection:$row.entry.conversationID) {
                                        Text("이어갈 대화 선택").tag("")
                                        ForEach(row.choices) {choice in Text(choice.title).tag(choice.id)}
                                    }.frame(maxWidth:.infinity,alignment:.leading)
                                }
                                TextField("대화 ID",text:$row.entry.conversationID).textFieldStyle(.roundedBorder)
                                    .font(.system(.callout,design:.monospaced)).accessibilityLabel("\(row.entry.title) 대화 ID")
                                    .help("자동 확인한 대화를 저장하거나 이어갈 대화의 UUID를 입력하세요.")
                                if !row.entry.resumesConversation {
                                    Label {Text("이어갈 대화를 확인해주세요").foregroundStyle(.primary)}
                                        icon: {Image(systemName:"exclamationmark.triangle").foregroundStyle(.orange)}
                                        .font(.caption)
                                }
                                if let detail=row.detail {Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
                                }
                            }.padding(.leading,20).disabled(!row.included)
                            Divider()
                        }
                    }
                }.padding(.trailing,8)
            }
            if let message=error ?? (name.isEmpty ? nil:validationError) {
                Label(message,systemImage:"exclamationmark.circle").font(.callout).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true)
            }
            HStack(spacing:10) {
                Text("대화 \(rows.filter {$0.included && !$0.startsNewCLI}.count)개 · 새 CLI \(rows.filter {$0.included && $0.startsNewCLI}.count)개").font(.caption).foregroundStyle(.secondary)
                if saving {ProgressView().controlSize(.small)}
                Spacer()
                Button("취소",action:cancel).keyboardShortcut(.cancelAction).disabled(saving)
                Button("프로필 저장") {
                    saving=true;error=nil
                    Task {do {try await save(profile)} catch {self.error=error.localizedDescription};saving=false}
                }.keyboardShortcut(.defaultAction).disabled(saving || validationError != nil)
            }
        }.padding(24).frame(width:700,height:620).onAppear {nameFocused=true}
    }
}
