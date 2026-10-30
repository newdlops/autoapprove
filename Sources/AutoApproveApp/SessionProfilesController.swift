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

@MainActor final class SessionProfilesController: ObservableObject {
    let store: TerminalProfileStore
    @Published private(set) var profiles:[TerminalSessionProfile]=[]
    @Published var selectedID:UUID?
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
    func reload() async {
        guard !loading else {return};loading=true;defer {loading=false}
        let store=store
        do {
            let listing=try await Task.detached(priority:.utility) {try store.list()}.value
            profiles=listing.profiles
            if !profiles.contains(where:{$0.id == selectedID}) {selectedID=profiles.first?.id}
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
