import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AutoApproveCore

struct SessionProfileDraft: Identifiable {
    let id=UUID()
    var profileID: UUID
    var name: String
    var candidates: [TerminalProfileCandidate]
}

struct SessionProfileEntryFilter:Equatable {
    enum Agent:String,CaseIterable {case all="전체",codex="Codex",claude="Claude"}
    enum Order:String,CaseIterable {case saved="저장 순서",window="창·탭",repository="레포",agent="도구",title="이름"}
    struct WindowChoice:Identifiable,Equatable {let id:String;let title:String}
    var agent:Agent = .all
    var window=""
    var repository=""
    var query=""
    var order:Order = .saved
    var ascending=true
    var active:Bool {agent != .all || !window.isEmpty || !repository.isEmpty || !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}
    static func windowKey(_ entry:TerminalProfileEntry) -> String {
        guard entry.host == .terminal else {return "iterm:unknown"}
        return "terminal:"+(entry.terminalTab?.window.uuidString ?? "unknown")
    }
    static func windowName(_ entry:TerminalProfileEntry) -> String {
        guard entry.host == .terminal else {return "iTerm2 · 창 정보 없음"}
        return entry.terminalTab.map {"Terminal 창 \($0.windowOrder+1)"} ?? "Terminal · 창 정보 없음"
    }
    static func windowPosition(_ entry:TerminalProfileEntry) -> String {
        entry.host == .terminal ? entry.terminalTab.map {"창 \($0.windowOrder+1) · 탭 \($0.tabOrder+1)"} ?? "창 정보 없음":"창 정보 없음"
    }
    private static func windowOrder(_ entry:TerminalProfileEntry,_ offset:Int) -> (Int,Int,Int) {
        (entry.host == .terminal ? 0:1,entry.host == .terminal ? entry.terminalTab?.windowOrder ?? 512:512,entry.host == .terminal ? entry.terminalTab?.tabOrder ?? offset:offset)
    }
    static func windows(for entries:[TerminalProfileEntry]) -> [WindowChoice] {
        let groups=Dictionary(grouping:entries,by:windowKey)
        return groups.sorted {left,right in windowOrder(left.value[0],0)<windowOrder(right.value[0],0)}
            .map {WindowChoice(id:$0.key,title:windowName($0.value[0])+" · \($0.value.count)개")}
    }
    func entries(_ entries:[TerminalProfileEntry],repositories:[String:String]) -> [TerminalProfileEntry] {
        let query=query.trimmingCharacters(in:.whitespacesAndNewlines)
        return entries.enumerated().filter {_,entry in
            (agent == .all || entry.agent == (agent == .codex ? "codex":"claude")) &&
            (window.isEmpty || Self.windowKey(entry) == window) &&
            (repository.isEmpty || (repositories[entry.cwd] ?? entry.cwd) == repository) &&
            (query.isEmpty || [entry.title,entry.cwd,entry.conversationID,repositories[entry.cwd] ?? entry.cwd]
                .contains { $0.localizedStandardContains(query) })
        }.sorted {left,right in
            let comparison:ComparisonResult
            switch order {
            case .saved:return ascending ? left.offset<right.offset:left.offset>right.offset
            case .window:
                let a=Self.windowOrder(left.element,left.offset),b=Self.windowOrder(right.element,right.offset)
                return a == b ? left.offset<right.offset:(ascending ? a<b:a>b)
            case .repository:comparison=(repositories[left.element.cwd] ?? left.element.cwd).localizedStandardCompare(repositories[right.element.cwd] ?? right.element.cwd)
            case .agent:comparison=left.element.agent.localizedStandardCompare(right.element.agent)
            case .title:comparison=left.element.title.localizedStandardCompare(right.element.title)
            }
            if comparison == .orderedSame {return left.offset<right.offset}
            return comparison == (ascending ? .orderedAscending:.orderedDescending)
        }.map(\.element)
    }
    // Read markers only, off the main actor. No Git subprocess, config, or CLI
    // conversation lookup. Missing repositories remain exact working folders.
    static func repositories(for paths:[String]) -> [String:String] {
        let manager=FileManager.default;var roots:[String:String]=[:],missing=Set<String>(),result:[String:String]=[:]
        for path in Set(paths) {
            var directory=URL(fileURLWithPath:path).standardizedFileURL,visited:[String]=[],root:String?
            for _ in 0..<128 {
                let current=directory.path
                if let cached=roots[current] {root=cached;break}
                if missing.contains(current) {break}
                visited.append(current)
                if manager.fileExists(atPath:directory.appendingPathComponent(".git").path) {root=current;break}
                if current == "/" {break};directory.deleteLastPathComponent()
            }
            if let root {for item in visited {roots[item]=root}}
            else {missing.formUnion(visited)}
            result[path]=root ?? path
        }
        return result
    }
}

@MainActor final class SessionProfilesController: ObservableObject {
    let store: TerminalProfileStore
    @Published private(set) var profiles:[TerminalSessionProfile]=[]
    @Published var selectedID:UUID? {didSet {if oldValue != selectedID {message=nil;results=[:];prepareEntries(reset:true)}}}
    @Published var entryFilter=SessionProfileEntryFilter()
    @Published var selectedEntries=Set<UUID>()
    @Published private(set) var repositories:[String:String]=[:]
    @Published private(set) var resolvingRepositories=false
    @Published var draft:SessionProfileDraft?
    @Published private(set) var busy=false
    @Published private(set) var loading=false
    @Published var error:String?
    @Published private(set) var message:String?
    @Published private(set) var results:[UUID:TerminalProfileRestoreResult]=[:]
    private let capture:@MainActor () async throws -> [TerminalProfileCandidate]
    private let activeSessions:@MainActor () async throws -> [TerminalProfileCandidate]
    private let launch:@Sendable (TerminalProfileEntry,String?) async throws -> String
    private let selectTab:@Sendable (String) async throws -> Void
    private let restorer=TerminalProfileRestorer()
    private var repositoryTask:Task<Void,Never>?
    private var repositoryGeneration=UUID()
    init(store:TerminalProfileStore,capture:@escaping @MainActor () async throws -> [TerminalProfileCandidate],
         activeSessions:(@MainActor () async throws -> [TerminalProfileCandidate])? = nil,
         launch:(@Sendable (TerminalProfileEntry,String?) async throws -> String)? = nil,
         selectTab:(@Sendable (String) async throws -> Void)? = nil) {
        self.store=store;self.capture=capture;self.activeSessions=activeSessions ?? capture
        self.launch=launch ?? {try await TerminalProfileLauncher.launch($0,anchorTTY:$1)}
        // A synthetic launcher cannot acquire an implicit path to real native UI.
        if let selectTab {self.selectTab=selectTab}
        else if launch == nil {self.selectTab={try await TerminalProfileLauncher.selectTab($0)}}
        else {self.selectTab={_ in}}
    }
    convenience init(engine:ApprovalEngine) {
        self.init(store:TerminalProfileStore(directory:engine.paths.directory.appendingPathComponent("session-profiles",isDirectory:true)),
                  capture:{try await engine.terminalProfileCandidates()},
                  activeSessions:{try await engine.terminalProfileCandidates(includeLayout:false)})
    }
    var selected:TerminalSessionProfile? {profiles.first {$0.id == selectedID}}
    var visibleEntries:[TerminalProfileEntry] {entryFilter.entries(selected?.entries ?? [],repositories:repositories)}
    var selectedVisibleIDs:Set<UUID> {selectedEntries.intersection(visibleEntries.map(\.id))}
    var windowChoices:[SessionProfileEntryFilter.WindowChoice] {SessionProfileEntryFilter.windows(for:selected?.entries ?? [])}
    var repositoryChoices:[String] {Array(Set((selected?.entries ?? []).map {repositories[$0.cwd] ?? $0.cwd})).sorted {$0.localizedStandardCompare($1) == .orderedAscending}}
    var canRestoreSelection:Bool {!busy && !loading && !resolvingRepositories && !selectedVisibleIDs.isEmpty}
    func selectVisible(_ included:Bool) {
        let ids=Set(visibleEntries.map(\.id))
        if included {selectedEntries.formUnion(ids)} else {selectedEntries.subtract(ids)}
    }
    func restoreSelection() async {
        guard canRestoreSelection,let profile=selected else {return}
        // Capture the visible intersection before the first await. Hidden checked
        // rows and display sorting never widen or reorder the restore plan.
        let ids=selectedVisibleIDs
        await restore(profile,selected:ids)
    }
    func waitForRepositories() async {await repositoryTask?.value}
    private func prepareEntries(reset:Bool) {
        repositoryTask?.cancel();let generation=UUID();repositoryGeneration=generation
        guard let profile=selected else {selectedEntries=[];repositories=[:];resolvingRepositories=false;return}
        if reset {entryFilter = .init();selectedEntries=Set(profile.entries.map(\.id))}
        else {selectedEntries.formIntersection(profile.entries.map(\.id))}
        resolvingRepositories=true
        let paths=profile.entries.map(\.cwd)
        repositoryTask=Task { [weak self] in
            let value=await Task.detached(priority:.utility) {SessionProfileEntryFilter.repositories(for:paths)}.value
            guard let self,self.repositoryGeneration==generation,self.selectedID==profile.id else {return}
            self.repositories=value;self.resolvingRepositories=false
        }
    }
    func reload() async {
        guard !loading else {return};loading=true;defer {loading=false}
        let store=store
        do {
            let listing=try await Task.detached(priority:.utility) {try store.list()}.value
            let previousID=selectedID,previousEntries=selected?.entries.map(\.id)
            profiles=listing.profiles
            if !profiles.contains(where:{$0.id == selectedID}) {selectedID=profiles.first?.id}
            if previousID==selectedID {prepareEntries(reset:previousEntries != selected?.entries.map(\.id))}
            await waitForRepositories()
            if !listing.warnings.isEmpty {error="읽지 못한 프로필 \(listing.warnings.count)개가 있습니다. 파일을 확인한 뒤 다시 불러와주세요.\n"+listing.warnings.prefix(3).joined(separator:"\n")}
        } catch {self.error=error.localizedDescription}
    }
    func captureCurrent(replacing:TerminalSessionProfile? = nil) async {
        guard !busy else {return};busy=true;error=nil;message=nil;defer {busy=false}
        do {
            let candidates=try await capture()
            guard !candidates.isEmpty else {throw AppError.message("실행 중인 Codex·Claude Code 세션이 없습니다. 터미널에서 CLI를 연 뒤 다시 저장해주세요.")}
            draft = .init(profileID:replacing?.id ?? UUID(),name:replacing?.name ?? "",candidates:candidates)
        } catch {self.error=error.localizedDescription}
    }
    func edit(_ profile:TerminalSessionProfile) {
        draft = .init(profileID:profile.id,name:profile.name,candidates:profile.entries.map {.init(id:$0.id.uuidString,entry:$0)})
    }
    func save(_ profile:TerminalSessionProfile) async throws {
        guard !busy else {throw AppError.message("다른 프로필 작업을 마친 뒤 저장해주세요.")}
        busy=true;defer {busy=false};let store=store
        _ = try await Task.detached(priority:.utility) {try store.save(profile)}.value
        selectedID=profile.id;draft=nil;message="‘\(profile.name)’의 세션 \(profile.entries.count)개를 파일로 저장했습니다.";error=nil
        await reload()
    }
    func restore(_ profile:TerminalSessionProfile,selected:Set<UUID>) async {
        guard !busy else {return};busy=true;error=nil;message="실행 중인 세션을 확인하고 있습니다…";results=[:]
        defer {busy=false}
        do {
            let candidates=try await activeSessions(),active=candidates.map(\.entry)
            let anchors=Dictionary(candidates.compactMap {candidate in candidate.entry.host == .terminal ? candidate.tty.map {(candidate.entry.key,$0)}:nil},uniquingKeysWith:{first,_ in first})
            let values=try await restorer.restore(profile,selected:selected,active:active,activeTerminalTTYs:anchors,launch:launch,selectTab:selectTab) { [weak self] result in
                self?.results[result.id]=result
                self?.message="\(self?.results.count ?? 0)/\(selected.count)개 처리"
            }
            let opened=values.filter {$0.phase == .opened}.count,skipped=values.filter {$0.phase == .alreadyOpen}.count,review=values.count-opened-skipped
            message="복원 명령 \(opened)개 전달 · 이미 열린 항목 \(skipped)개 · 확인 필요 \(review)개"
        } catch {self.error=error.localizedDescription;message=nil}
    }
    func importProfile() {
        guard !busy else {return}
        let panel=NSOpenPanel();panel.allowedContentTypes=[.json];panel.allowsMultipleSelection=false;panel.canChooseDirectories=false;panel.message="저장한 AutoApprove 세션 프로필을 선택하세요."
        panel.begin { [weak self] response in
            guard response == .OK,let source=panel.url else {return}
            Task { @MainActor [weak self] in
                guard let self,!self.busy else {return};self.busy=true;defer {self.busy=false};let store=self.store
                do {let value=try await Task.detached(priority:.utility) {try store.importFile(source)}.value;self.selectedID=value.id;self.error=nil;self.message="프로필을 가져왔습니다. 저장된 세션을 확인한 뒤 복원하세요.";await self.reload()}
                catch {self.error=error.localizedDescription}
            }
        }
    }
    func export(_ profile:TerminalSessionProfile) {
        let panel=NSSavePanel();panel.allowedContentTypes=[.json]
        let name=profile.name.replacingOccurrences(of:"/",with:"-").replacingOccurrences(of:":",with:"-")
        var filename=""
        for character in name {guard filename.utf8.count+String(character).utf8.count<=160 else {break};filename.append(character)}
        panel.nameFieldStringValue=(filename.isEmpty ? "세션 프로필":filename)+".autoapprove-profile.json";panel.message="프로필 파일에는 작업 폴더와 대화 ID가 포함됩니다."
        panel.begin { [weak self] response in
            guard response == .OK,let target=panel.url else {return}
            Task { @MainActor [weak self] in
                guard let self,!self.busy else {return};self.busy=true;defer {self.busy=false}
                do {try await Task.detached(priority:.utility) {try TerminalProfileStore.write(TerminalProfileStore.encode(profile),to:target)}.value;self.error=nil;self.message="프로필 파일을 내보냈습니다."}
                catch {self.error=error.localizedDescription}
            }
        }
    }
    func trash(_ profile:TerminalSessionProfile) async {
        guard !busy else {return};busy=true;defer {busy=false};let file=store.file(profile.id)
        do {try await Task.detached(priority:.utility) {_ = try FileManager.default.trashItem(at:file,resultingItemURL:nil)}.value;error=nil;message="프로필을 휴지통으로 옮겼습니다.";await reload()}
        catch {self.error=error.localizedDescription}
    }
    func reveal(_ profile:TerminalSessionProfile) {NSWorkspace.shared.activateFileViewerSelecting([store.file(profile.id)])}
    func openFolder() async {
        let store=store
        do {try await Task.detached(priority:.utility) {try store.prepare()}.value;NSWorkspace.shared.open(store.directory)}
        catch {self.error=error.localizedDescription}
    }
}
