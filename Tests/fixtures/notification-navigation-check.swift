import Foundation
import AppKit
import AutoApproveCore

private final class Reads:@unchecked Sendable {
    private let lock=NSLock();private var count=0
    func increment() {lock.withLock {count+=1}}
    var value:Int {lock.withLock {count}}
}
@main struct NotificationNavigationCheck {
    @MainActor static func main() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-notification-navigation-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        var checks=0,failures:[String]=[]
        func check(_ success:Bool,_ label:String) {checks+=1;if !success {failures.append(label)}}
        var session=AgentSession(id:"notification-exact",agent:.codex,pid:1200,started:"fixture-start",tty:"/dev/fixture-notification",cwd:"/tmp/notification-fixture",terminal:.terminal)
        session.phase = .idle;session.channel = .terminalScreen
        var events:[String]=[]
        try await TerminalNavigator.open(session,reveal:{events.append("reveal");return nil},activate:{events.append("activate-"+$0.rawValue)})
        check(events==["reveal","activate-terminal"],"Terminal must receive app-side activation after exact tab reveal")
        let reads=Reads();var opened:[String]=[]
        let engine=try ApprovalEngine(paths:.init(directory:root),processReader:{reads.increment();return []})
        engine.updateDiscovery([session],records:[])
        do {try await NotificationSessionOpener.open(session.id,engine:engine) {opened.append($0.id)}}catch {failures.append("Known notification target failed: "+error.localizedDescription)}
        check(reads.value==0,"An already-known notification target must not refresh all processes, screens and conversation histories")
        check(opened==[session.id],"The exact known session opens once")
        for kind in [TerminalKind.iterm,.orca,.vscode] {
            var target=session;target.terminal=kind;events=[]
            try await TerminalNavigator.open(target,reveal:{events.append("reveal");return nil},activate:{events.append("activate-"+$0.rawValue)})
            check(events==(kind == .vscode ? ["reveal"]:["reveal","activate-"+(kind == .iterm ? "iterm":"orca")]),"Host activation remains scoped: "+kind.rawValue)
        }
        events=[]
        do {try await TerminalNavigator.open(session,reveal:{throw AppError.message("closed exact target")},activate:{events.append($0.rawValue)});failures.append("Reveal failure must throw")}catch {}
        check(events.isEmpty,"A stale/denied reveal cannot activate an arbitrary host")
        var cold:[AgentSession]=[],waits=0,coldOpened:[String]=[]
        try await NotificationSessionOpener.open(session.id,sessions:{cold},discovered:{waits>=2},wait:{waits+=1;if waits==2 {cold=[session]}},reveal:{coldOpened.append($0.id)})
        check(waits==2 && coldOpened==[session.id],"Cold launch waits only for first discovery then opens the exact original")
        var absentWaits=0
        do {try await NotificationSessionOpener.open("missing",sessions:{[session]},discovered:{true},wait:{absentWaits+=1},reveal:{_ in failures.append("Unknown session was opened")});failures.append("Missing target must throw")}catch {}
        check(absentWaits==0,"A completed discovery cannot fall back to a similar live session")
        do {try await NotificationSessionOpener.open("missing",sessions:{[]},discovered:{false},wait:{absentWaits+=1},reveal:{_ in failures.append("Timed-out session was opened")});failures.append("Cold timeout must throw")}catch {}
        check(absentWaits==50,"Cold discovery wait is bounded")
        var revealAttempts=0
        do {try await NotificationSessionOpener.open(session.id,sessions:{[session]},discovered:{false},wait:{failures.append("A failed reveal must not wait and retry")},reveal:{_ in revealAttempts+=1;throw AppError.message("denied")});failures.append("Denied reveal must throw")}catch {}
        check(revealAttempts==1,"A failed exact reveal is never replayed")
        var blockedActivation=0
        do {try await TerminalNavigator.open(session,reveal:{nil},activate:{_ in blockedActivation+=1;throw AppError.message("activation denied")});failures.append("Activation denial must throw")}catch {}
        check(blockedActivation==1,"Rejected focus transfer is reported and never repeated")
        if !failures.isEmpty {for label in failures {print("FAIL "+label)};exit(1)}
        print("PASS \(checks) notification navigation checks; production app path, synthetic identities, no user Terminal operations")
    }
}
