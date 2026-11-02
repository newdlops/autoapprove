import Foundation
import AutoApproveCore

private actor LaunchLog {
    var opened:[TerminalProfileEntry]=[]
    var reads=0
    func launch(_ entry:TerminalProfileEntry) -> String {opened.append(entry);return "/dev/ttys\(900+opened.count)"}
    func active() -> [TerminalProfileCandidate] {reads+=1;return opened.enumerated().map {.init(id:$0.element.id.uuidString,entry:$0.element,tty:"/dev/ttys\(901+$0.offset)")}}
}
@main struct ProfileSelectionCheck {
    @MainActor static func main() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-profile-selection-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        func directory(_ path:String) throws -> String {let url=root.appendingPathComponent(path);try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);return url.path}
        let api=try directory("one/api"),web=try directory("two/api"),nested=try directory("one/api/nested")
        _ = try directory("one/api/.git");_ = try directory("two/api/.git")
        try Data("gitdir: /fixture/git-worktree".utf8).write(to:URL(fileURLWithPath:nested).appendingPathComponent(".git"))
        let sub=try directory("one/api/services/auth"),plain=try directory("plain")
        func entry(_ number:Int,_ agent:String,_ cwd:String,_ title:String) -> TerminalProfileEntry {
            .init(title:title,agent:agent,cwd:cwd,conversationID:String(format:"00000000-0000-4000-8000-%012d",number))
        }
        let entries=[entry(1,"codex",api,"결제 API"),entry(2,"claude",sub,"인증"),entry(3,"codex",web,"웹"),entry(4,"claude",web,"화면"),entry(5,"codex",nested,"Nested"),entry(6,"claude",plain,"문서")]
        let repositories=SessionProfileEntryFilter.repositories(for:entries.map(\.cwd)+[root.appendingPathComponent("missing").path])
        var checks=0
        func check(_ value:Bool,_ message:String) throws {guard value else {throw AppError.message(message)};checks+=1}
        try check(repositories[sub]==api,"Subdirectory must use the nearest repo")
        try check(repositories[nested]==nested,"Worktree/nested marker must retain its own root")
        try check(repositories[plain]==plain,"Non-repo fallback must use the exact folder")
        try check(Set(repositories.values).contains(web),"Same-name repositories retain exact paths")
        var filter=SessionProfileEntryFilter();filter.agent = .codex
        try check(filter.entries(entries,repositories:repositories).map(\.id)==[entries[0],entries[2],entries[4]].map(\.id),"Codex filter")
        filter.agent = .claude;filter.repository=api
        try check(filter.entries(entries,repositories:repositories).map(\.id)==[entries[1].id],"Agent and repository intersection")
        filter.agent = .all;filter.query="인증"
        try check(filter.entries(entries,repositories:repositories).map(\.id)==[entries[1].id],"Unicode title search")
        filter.query="000000000001"
        try check(filter.entries(entries,repositories:repositories).map(\.id)==[entries[0].id],"Conversation ID search")
        filter = .init();filter.ascending=false
        try check(filter.entries(entries,repositories:repositories).map(\.id)==entries.reversed().map(\.id),"Reverse saved display order")
        filter.order = .title
        let descending=filter.entries(entries,repositories:repositories);filter.ascending=true
        try check(descending.map(\.id)==filter.entries(entries,repositories:repositories).reversed().map(\.id),"Title sort direction")
        let store=TerminalProfileStore(directory:root.appendingPathComponent("profiles"))
        let profile=try store.save(.init(name:"Selection fixture",entries:entries))
        let other=try store.save(.init(name:"Other",entries:[entry(7,"codex",plain,"Other")]))
        let before=try TerminalProfileStore.read(store.file(profile.id)),log=LaunchLog()
        let controller=SessionProfilesController(store:store,capture:{throw AppError.message("Unexpected capture")},activeSessions:{try await Task.sleep(for:.milliseconds(50));return await log.active()},launch:{entry,_ in await log.launch(entry)})
        await controller.reload();controller.selectedID=profile.id;await controller.waitForRepositories()
        controller.entryFilter.agent = .codex
        let task=Task {await controller.restoreSelection()}
        while !controller.busy {await Task.yield()}
        controller.entryFilter.agent = .claude
        await task.value
        try check(await log.opened.map(\.id)==[entries[0],entries[2],entries[4]].map(\.id),"Visible selection is captured before awaits; hidden Claude never launches")
        await controller.restoreSelection()
        try check(await log.opened.count==6,"Switching to Claude restores only its three rows")
        await controller.restoreSelection()
        try check(await log.opened.count==6,"Restore receipts and exact active identities prevent duplicate launches")
        controller.entryFilter = .init();controller.entryFilter.repository=api
        controller.selectVisible(false)
        try check(controller.selectedVisibleIDs.isEmpty,"Bulk deselect applies to displayed repo rows")
        try check(controller.selectedEntries.count==4,"Bulk deselect preserves other repository checks")
        controller.selectVisible(true)
        try check(controller.selectedVisibleIDs==Set([entries[0].id,entries[1].id]),"Bulk select uses repo root plus subdirectory")
        controller.entryFilter.query="no matching session"
        let reads=await log.reads
        await controller.restoreSelection()
        try check(await log.reads==reads,"Empty filter cannot even start active-session lookup")
        controller.entryFilter = .init();controller.entryFilter.order = .title;controller.entryFilter.ascending=false
        try check(controller.selectedVisibleIDs==Set(entries.map(\.id)),"Sorting keeps selections by ID")
        controller.selectedID=other.id
        try check(!controller.canRestoreSelection,"Repository loading disables restore synchronously")
        await controller.waitForRepositories()
        try check(controller.selectedEntries==Set(other.entries.map(\.id)) && controller.entryFilter == .init(),"Profile switch resets only to the new profile")
        controller.selectedID=profile.id;controller.selectedID=other.id;await controller.waitForRepositories()
        try check(controller.repositoryChoices==[plain],"Late repo results cannot replace a newer profile")
        try check(try TerminalProfileStore.read(store.file(profile.id))==before,"Filter/sort/restore do not rewrite saved profile content")
        print("PASS \(checks) profile selection checks; production controller/restorer, exact repo roots, hidden-row exclusion, draft-free filter state, no real Terminal launch")
    }
}
