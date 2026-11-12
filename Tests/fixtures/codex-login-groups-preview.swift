// Actual account window and actual registry in a private fixture directory.
// CLI/auth/server operations are replaced; no user sessions or browser are used.
import AppKit
import SwiftUI
import Foundation
import CryptoKit
import AutoApproveCore

private final class GroupProbe:@unchecked Sendable {
    let root:URL
    private let lock=NSLock()
    private var events:[[String:String]]=[]
    init(_ root:URL){self.root=root}
    func record(_ action:String,_ home:String="") {
        lock.lock();defer{lock.unlock()}
        events.append(["action":action,"home":home]);events=Array(events.suffix(200))
        if let data=try? JSONSerialization.data(withJSONObject:events){try? data.write(to:root.appendingPathComponent("group-ui-events.json"),options:.atomic)}
    }
    func prepared(_ home:String)->URL {
        let key=SHA256.hash(data:Data(home.utf8)).map{String(format:"%02x",$0)}.joined()
        return root.appendingPathComponent("server-"+String(key.prefix(16)))
    }
    func wait() async throws {
        while FileManager.default.fileExists(atPath:root.appendingPathComponent("hold-inspection").path){try await Task.sleep(for:.milliseconds(50))}
    }
}
@MainActor private final class GroupFixture:ObservableObject {
    let root:URL,engine:ApprovalEngine
    @Published var dark=false
    var source:CodexSessionAccount {
        .init(sessionID:"synthetic-move-session",target:.init(home:root.appendingPathComponent("source-home").path,executable:"/fixture/codex"),
            identity:.init(provider:"ChatGPT",email:"source-account@example.test"),sharedSessions:1,loginGroupName:"개별 로그인",serverPID:12345)
    }
    init()throws {
        root=Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("fixture",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let probe=GroupProbe(root),fake=try AgentAccountFixture.services(root,codexBrowser:true)
        let accounts=AgentAccounts(services:fake,codexServices:{target in probe.record("login",target.home);return fake})
        engine=try ApprovalEngine(paths:AppPaths(directory:root.appendingPathComponent("app-home")),processReader:{[]},
            codexAccountTransitions:.init(observe:{_ in throw AppError.message("Synthetic fixture has no clients")},
                interrupt:{_,_,_,_ in throw AppError.message("Synthetic interrupt forbidden")},restart:{_,_ in throw AppError.message("Synthetic restart forbidden")},verify:{_,_,_ in 0}),
            codexAccountTargets:{_ in []},codexManagedServers:.init(inspect:{home,_ in
                probe.record("inspect-server",home);try await probe.wait()
                return .init(phase:FileManager.default.fileExists(atPath:probe.prepared(home).path) ? .running:.stopped,
                    version:"0.166.0",detail:"합성 서버 상태 · 실제 Codex는 실행하지 않습니다.",autoStartEnabled:true)
            },prepare:{home,_ in
                probe.record("prepare-server",home);try Data().write(to:probe.prepared(home))
                return .init(phase:.running,version:"0.166.0",detail:"합성 서버 준비 완료",autoStartEnabled:true)
            }),codexAccountInspections:.init(read:{target in
                probe.record("inspect-account",target.home);try await probe.wait()
                let signed=FileManager.default.fileExists(atPath:probe.root.appendingPathComponent("signed-codex").path)
                return .init(home:target.home,identity:.init(provider:signed ? "ChatGPT":"로그인되지 않음",
                    email:signed ? "long-account-for-selected-group@example.test":nil,plan:signed ? "pro":nil,authenticated:signed),
                    comparison:signed ? .same:.signedOut,connectedSessions:0)
            }))
        engine.agentAccounts=accounts
    }
    func damage() {
        let file=engine.codexLoginGroupStore.directory.appendingPathComponent("groups.json")
        if let bytes=try? Data(contentsOf:file) {
            try? bytes.write(to:root.appendingPathComponent("groups-backup.json"))
            try? Data("{synthetic-corrupt".utf8).write(to:file)
        }
    }
    func repair() {
        if let data=try? Data(contentsOf:root.appendingPathComponent("groups-backup.json")) {
            try? data.write(to:engine.codexLoginGroupStore.directory.appendingPathComponent("groups.json"))
        }
    }
}
@MainActor private struct GroupFixtureControls:View {
    @ObservedObject var fixture:GroupFixture
    @Environment(\.openWindow) private var openWindow
    var body:some View {
        Form {
            Text("실제 계정 화면과 저장소 · 모든 로그인/서버 동작은 합성 대역입니다.")
            Button("계정 창 열기"){openWindow(id:"accounts")}
            Button("그룹 이동 창 열기"){openWindow(id:"move")}
            Toggle("어두운 화면",isOn:$fixture.dark)
            Button("합성 로그인 완료"){try? Data().write(to:fixture.root.appendingPathComponent("signed-codex"))}
            Button("조회 지연 시작"){try? Data().write(to:fixture.root.appendingPathComponent("hold-inspection"))}
            Button("조회 지연 해제"){try? FileManager.default.removeItem(at:fixture.root.appendingPathComponent("hold-inspection"))}
            Button("그룹 메타데이터 손상",action:fixture.damage)
            Button("그룹 메타데이터 복원",action:fixture.repair)
        }.padding(24).frame(width:500)
    }
}
@main private struct LoginGroupsPreview:App {
    @StateObject private var fixture=try! GroupFixture()
    var body:some Scene {
        Window("로그인 그룹 합성 검사",id:"controls"){GroupFixtureControls(fixture:fixture).preferredColorScheme(fixture.dark ? .dark:.light)}
            .windowResizability(.contentSize)
        Window("계정·로그인 · 합성 검사",id:"accounts"){CodexAccountsWindow(engine:fixture.engine).preferredColorScheme(fixture.dark ? .dark:.light)}
            .windowResizability(.contentSize)
        Window("그룹 이동 · 합성 검사",id:"move"){
            CodexSessionMoveView(engine:fixture.engine,source:fixture.source,close:{})
                .preferredColorScheme(fixture.dark ? .dark:.light)
        }.windowResizability(.contentSize)
    }
}
