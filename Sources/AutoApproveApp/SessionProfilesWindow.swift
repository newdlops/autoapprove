// THESIS: Save each CLI conversation once, then reopen the chosen workspace after a restart.
// FORM: The existing native split list, system controls and restrained semantic feedback.
import SwiftUI
import AutoApproveCore

struct SessionProfilesWindow: View {
    @ObservedObject var controller:SessionProfilesController
    @State private var selectedEntries=Set<UUID>()
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
                    Text("창마다 이어갈 대화를 파일로 저장합니다.").font(.callout).foregroundStyle(.secondary).padding(.horizontal,16)
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
                        }.listStyle(.inset).disabled(controller.busy)
                    }
                }.frame(minWidth:210,idealWidth:245,maxWidth:300)
                Group {
                    if let profile=controller.selected {detail(profile)}
                    else {
                        ContentUnavailableView {
                            Label("창별 대화를 다시 여세요",systemImage:"terminal")
                        } description: {
                            Text("현재 세션을 프로필로 저장하면 재부팅 뒤에도 선택한 대화에서 이어갈 수 있습니다. 여러 프로필을 만들 수 있습니다.")
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
        .task {await controller.reload();selectAll()}
        .onChange(of:controller.selectedID) {_,_ in selectAll()}
        .onChange(of:controller.selected?.entries.map(\.id)) {_,_ in selectAll()}
        .sheet(item:$controller.draft) {draft in
            SessionProfileEditor(draft:draft,save:controller.save,cancel:{controller.draft=nil})
        }
    }
    private func selectAll() {selectedEntries=Set(controller.selected?.entries.map(\.id) ?? [])}
    private func detail(_ profile:TerminalSessionProfile) -> some View {
        VStack(alignment:.leading,spacing:12) {
            HStack(alignment:.top) {
                VStack(alignment:.leading,spacing:6) {
                    Text(profile.name).font(.title2.weight(.semibold)).lineLimit(3).textSelection(.enabled)
                    Text("세션 \(profile.entries.count)개 · \(profile.savedAt.formatted(date:.abbreviated,time:.shortened)) 저장")
                        .font(.callout).foregroundStyle(.secondary)
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
            Text("복원할 세션을 선택하세요. 저장한 대화를 새 터미널 창에서 엽니다.")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            List(profile.entries) {entry in
                VStack(alignment:.leading,spacing:6) {
                    Toggle(isOn:Binding(get:{selectedEntries.contains(entry.id)},set:{if $0 {selectedEntries.insert(entry.id)} else {selectedEntries.remove(entry.id)}})) {
                        Text(entry.title.isEmpty ? entry.agent:entry.title).font(.body.weight(.medium)).lineLimit(2)
                    }.toggleStyle(.checkbox).disabled(controller.busy)
                    Text((entry.agent == "codex" ? "Codex":"Claude Code")+" · "+(entry.host == .iterm ? "iTerm2":"Terminal"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(entry.cwd).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled).help(entry.cwd)
                    if let home=entry.providerHome {
                        Text("CLI 설정 폴더: "+home).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled).help(home)
                    }
                    Text(entry.conversationID).font(.system(.caption,design:.monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    if let result=controller.results[entry.id] {
                        Label(result.detail,systemImage:result.phase == .opened ? "checkmark.circle":result.phase == .alreadyOpen ? "arrow.uturn.forward.circle":"exclamationmark.triangle")
                            .font(.callout).foregroundStyle(result.phase == .failed ? Color.red:Color.primary)
                    }
                }.padding(.vertical,8)
            }.listStyle(.inset).padding(.horizontal,-8)
            Divider()
            HStack(spacing:10) {
                Button(selectedEntries.count == profile.entries.count ? "모두 해제":"모두 선택") {
                    if selectedEntries.count == profile.entries.count {selectedEntries=[]} else {selectAll()}
                }.disabled(controller.busy)
                Spacer(minLength:4)
                Text("\(selectedEntries.count)개 선택").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button("선택한 세션 복원") {Task {await controller.restore(profile,selected:selectedEntries)}}
                    .keyboardShortcut("r",modifiers:[.command,.shift]).disabled(controller.busy || selectedEntries.isEmpty)
                    .help("이미 실행 중인 대화는 건너뛰고 선택한 저장 대화를 다시 엽니다. ⌘⇧R")
            }
        }.padding(20)
    }
}

private struct ProfileDraftRow:Identifiable {
    var id:String
    var included=true
    var entry:TerminalProfileEntry
    var choices:[CodexProfileConversation]
    var detail:String?
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
    private var profile:TerminalSessionProfile {.init(id:draft.profileID,name:name,entries:rows.filter(\.included).map(\.entry))}
    private var validationError:String? {
        do {_ = try profile.validated();return nil} catch {return error.localizedDescription}
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("세션 프로필 저장").font(.title2.weight(.semibold))
            Text("각 창에서 이어갈 대화를 확인하세요. 대화 ID를 확인하지 못한 세션은 목록에서 선택하거나 직접 입력하세요.")
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
                                TextField("작업 폴더",text:$row.entry.cwd).textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("\(row.entry.title) 작업 폴더").help("이 대화를 다시 열 작업 폴더의 전체 경로")
                                if let home=row.entry.providerHome {Text("CLI 설정 폴더: "+home).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)}
                                if !row.choices.isEmpty {
                                    Picker("복원할 대화",selection:$row.entry.conversationID) {
                                        Text("대화 선택…").tag("")
                                        ForEach(row.choices) {choice in Text(choice.title).tag(choice.id)}
                                    }.frame(maxWidth:.infinity,alignment:.leading)
                                }
                                TextField("대화 ID (UUID)",text:$row.entry.conversationID).textFieldStyle(.roundedBorder)
                                    .font(.system(.callout,design:.monospaced)).accessibilityLabel("\(row.entry.title) 대화 ID")
                                if let detail=row.detail {Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
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
                Text("\(rows.filter(\.included).count)개 세션 포함").font(.caption).foregroundStyle(.secondary)
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
