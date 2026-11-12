#if DEBUG
import Foundation
import Darwin
@testable import AutoApproveCore

private final class LoginGroupFixture {
    let root=URL(fileURLWithPath:"/private/tmp/aa-login-groups-"+UUID().uuidString)
    var store:CodexLoginGroupStore {.init(directory:root.appendingPathComponent("groups"))}
    init()throws{try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}
    deinit{try? FileManager.default.removeItem(at:root)}
    func rejects(_ operation:()throws->Void)throws {
        var rejected=false;do{try operation()}catch{rejected=true};try expect(rejected)
    }
}
private final class LoginGroupServerProbe:@unchecked Sendable {
    private let lock=NSLock()
    private var homes:[String]=[],preparations=0
    func inspect(_ home:String){lock.lock();defer{lock.unlock()};homes.append(home)}
    func prepare(){lock.lock();defer{lock.unlock()};preparations+=1}
    var state:([String],Int){lock.lock();defer{lock.unlock()};return(homes,preparations)}
}
extension ApprovalTests {
    func testLoginGroupsCreatePrivateHomesAndRestoreWithoutCredentials()throws {
        let f=try LoginGroupFixture()
        try expect(try f.store.list().isEmpty)
        try expect(!FileManager.default.fileExists(atPath:f.store.directory.path))
        let a=try f.store.create(name:"  개인 계정  "),b=try f.store.create(name:"회사 계정")
        try expectEqual(a.name,"개인 계정");try expect(a.id != b.id && a.home != b.home)
        try expectEqual(try CodexLoginGroupStore(directory:f.store.directory).list(),[a,b])
        for group in [a,b] {
            var home=stat(),config=stat();try expectEqual(lstat(group.home,&home),0)
            try expectEqual(home.st_mode&0o777,0o700)
            try expectEqual(lstat(group.home+"/config.toml",&config),0);try expectEqual(config.st_mode&0o777,0o600)
            try expectEqual(try String(contentsOfFile:group.home+"/config.toml",encoding:.utf8),"cli_auth_credentials_store = \"file\"\n")
            try expect(!FileManager.default.fileExists(atPath:group.home+"/auth.json"))
            try f.store.validate(home:group.home)
        }
    }
    func testLegacyLoginGroupsMigrateToStableVolumeIdentity()throws {
        let f=try LoginGroupFixture(),group=try f.store.create(name:"Legacy")
        let index=f.store.directory.appendingPathComponent("groups.json")
        var document=try JSONSerialization.jsonObject(with:Data(contentsOf:index)) as! [String:Any]
        var rootInfo=stat(),homeInfo=stat()
        try expectEqual(lstat(f.store.directory.path,&rootInfo),0);try expectEqual(lstat(group.home,&homeInfo),0)
        document["identity"]="\(rootInfo.st_dev):\(rootInfo.st_ino)"
        var groups=document["groups"] as! [[String:Any]]
        groups[0]["homeIdentity"]="\(homeInfo.st_dev):\(homeInfo.st_ino)";document["groups"]=groups
        try JSONSerialization.data(withJSONObject:document).write(to:index)
        let migrated=try f.store.list()
        try expectEqual(migrated.first?.id,group.id)
        let volume=try URL(fileURLWithPath:group.home).resourceValues(forKeys:[.volumeUUIDStringKey]).volumeUUIDString!.lowercased()
        try expectEqual(migrated[0].homeIdentity,"volume:\(volume):\(homeInfo.st_ino)")
        try expectEqual(try f.store.list(),migrated)
    }
    func testLoginGroupsRejectDifferentVolumeIdentity()throws {
        let f=try LoginGroupFixture(),group=try f.store.create(name:"Owned")
        let index=f.store.directory.appendingPathComponent("groups.json")
        var document=try JSONSerialization.jsonObject(with:Data(contentsOf:index)) as! [String:Any]
        let original=document["identity"] as! String
        let parts=original.split(separator:":")
        document["identity"]="volume:00000000-0000-0000-0000-000000000000:\(parts.last!)"
        let bytes=try JSONSerialization.data(withJSONObject:document);try bytes.write(to:index)
        try f.rejects{_ = try f.store.list()}
        try expectEqual(try Data(contentsOf:index),bytes)
        try expect(FileManager.default.fileExists(atPath:group.home))
    }
    func testLoginGroupRenamePreservesHomeIdentityAndAuthentication()throws {
        let f=try LoginGroupFixture(),a=try f.store.create(name:"Personal"),b=try f.store.create(name:"Work")
        let auth=Data("synthetic-private-fixture".utf8)
        try auth.write(to:URL(fileURLWithPath:a.home+"/auth.json"))
        let updated=try f.store.rename(id:a.id,name:"  개인 계정  ")
        try expectEqual(updated.name,"개인 계정");try expectEqual(updated.id,a.id)
        try expectEqual(updated.home,a.home);try expectEqual(updated.homeIdentity,a.homeIdentity);try expectEqual(updated.createdAt,a.createdAt)
        try expectEqual(try Data(contentsOf:URL(fileURLWithPath:a.home+"/auth.json")),auth)
        try expectEqual(try f.store.list(),[updated,b])
        for name in ["work","",String(repeating:"가",count:81),"a\nb"] {try f.rejects{_ = try f.store.rename(id:a.id,name:name)}}
        try f.rejects{_ = try f.store.rename(id:UUID(),name:"Missing")}
        try expectEqual(try f.store.list(),[updated,b])
        try FileManager.default.moveItem(atPath:a.home,toPath:a.home+"-old")
        try FileManager.default.createDirectory(atPath:a.home,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        try f.rejects{_ = try f.store.rename(id:a.id,name:"Changed")}
    }
    func testLoginGroupsRejectNamesDuplicatesAndCorruptionWithoutReset()throws {
        let f=try LoginGroupFixture(),a=try f.store.create(name:"Personal")
        for name in ["", "  ",String(repeating:"가",count:81),"a\nb","personal"] {
            try f.rejects{_ = try f.store.create(name:name)}
        }
        try expectEqual(try f.store.list(),[a])
        let index=f.store.directory.appendingPathComponent("groups.json"),bytes=Data("{broken".utf8)
        try bytes.write(to:index)
        try f.rejects{_ = try f.store.list()};try f.rejects{_ = try f.store.create(name:"Next")}
        try expectEqual(try Data(contentsOf:index),bytes)
        try expect(FileManager.default.fileExists(atPath:a.home))
    }
    func testLoginGroupsRejectChangedLinkedAndMissingHomes()throws {
        for kind in ["replacement","symlink","missing","metadata-missing"] {
            let f=try LoginGroupFixture(),a=try f.store.create(name:"Owned")
            if kind=="metadata-missing" {try FileManager.default.removeItem(at:f.store.directory.appendingPathComponent("groups.json"))}
            else {
                try FileManager.default.moveItem(atPath:a.home,toPath:a.home+"-old")
                if kind=="replacement" {try FileManager.default.createDirectory(atPath:a.home,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])}
                if kind=="symlink" {try FileManager.default.createSymbolicLink(atPath:a.home,withDestinationPath:f.root.path)}
            }
            try f.rejects{_ = try f.store.list()};try f.rejects{try f.store.validate(home:a.home)}
            try f.rejects{_ = try f.store.create(name:"Another")}
        }
    }
    func testLoginGroupsRejectLinkedPublicAndSpecialIndexFiles()throws {
        for kind in ["symlink","hardlink","public","fifo"] {
            let f=try LoginGroupFixture(),a=try f.store.create(name:"Owned")
            let index=f.store.directory.appendingPathComponent("groups.json").path,backup=index+"-old"
            if kind=="public" {try expectEqual(chmod(index,0o644),0)}
            else {
                try FileManager.default.moveItem(atPath:index,toPath:backup)
                switch kind {
                case "symlink":try FileManager.default.createSymbolicLink(atPath:index,withDestinationPath:backup)
                case "hardlink":try expectEqual(link(backup,index),0)
                default:try expectEqual(mkfifo(index,0o600),0)
                }
            }
            let started=Date();try f.rejects{_ = try f.store.list()}
            try expect(Date().timeIntervalSince(started)<1)
            try f.rejects{_ = try f.store.create(name:"Another")}
            try expect(FileManager.default.fileExists(atPath:a.home))
        }
    }
    func testLoginGroupsConcurrentCreationCannotDuplicateName() async throws {
        let f=try LoginGroupFixture(),store=f.store
        let successes=await withTaskGroup(of:Bool.self,returning:Int.self){group in
            for _ in 0..<8{group.addTask{(try? store.create(name:"Same")) != nil}}
            var count=0;for await success in group{if success{count+=1}};return count
        }
        try expectEqual(successes,1);try expectEqual(try store.list().count,1)
    }
    @MainActor func testLoginGroupEngineCreatesWithoutDiscoveryOrServerEffects() async throws {
        let f=try LoginGroupFixture()
        let engine=try ApprovalEngine(paths:AppPaths(directory:f.root),processReader:{throw AppError.message("Creation must not discover or control processes")})
        let before=engine.snapshot
        let group=try await engine.createCodexLoginGroup(name:"Owned")
        try expectEqual(try await engine.codexLoginGroups(),[group])
        try expectEqual(engine.snapshot.sessions,before.sessions)
        try expect(engine.codexAccountTransitionStates.isEmpty)
        try expect(engine.agentAccounts.nativeCodexLogin==nil)
    }
    func testLoginGroupsBoundCountWithoutChangingExistingEntries()throws {
        let f=try LoginGroupFixture()
        for index in 0..<32{_ = try f.store.create(name:"Group \(index)")}
        let before=try f.store.list()
        try f.rejects{_ = try f.store.create(name:"Over limit")}
        try expectEqual(try f.store.list(),before)
    }
    @MainActor func testEmptyLoginGroupsDoNotAutomaticallyStartServers() async throws {
        let f=try LoginGroupFixture(),probe=LoginGroupServerProbe()
        let engine=try ApprovalEngine(paths:AppPaths(directory:f.root),processReader:{[]},
            codexManagedServers:.init(inspect:{home,_ in
                probe.inspect(home);return .init(phase:.unavailable,detail:"Owned synthetic unavailable server")
            },prepare:{_,_ in probe.prepare();throw AppError.message("No automatic group preparation expected")}))
        let group=try await engine.createCodexLoginGroup(name:"Empty")
        let candidates=try await engine.codexServerSetupHomes()
        try expect(candidates.contains(try CodexAccountTransitionTarget.canonicalHome(group.home)))
        await engine.ensureCodexManagedServers()
        let (inspected,preparations)=probe.state
        try expect(!inspected.contains(group.home))
        try expect(!inspected.contains(try CodexAccountTransitionTarget.canonicalHome(group.home)))
        try expectEqual(preparations,0)
    }
    @MainActor func testLoginGroupInspectionRejectsRetargetingBeforeCanonicalization() async throws {
        let f=try LoginGroupFixture(),probe=LoginGroupServerProbe(),outside=f.root.appendingPathComponent("outside").path
        try FileManager.default.createDirectory(atPath:outside,withIntermediateDirectories:true)
        let canonical=try CodexAccountTransitionTarget.canonicalHome(outside)
        let engine=try ApprovalEngine(paths:AppPaths(directory:f.root),processReader:{[]},
            codexAccountTargets:{_ in [.init(home:canonical,executable:"/owned/codex")]},
            codexAccountInspections:.init(read:{target in
                probe.inspect(target.home);return .init(home:target.home,comparison:.same,connectedSessions:0)
            }))
        let group=try await engine.createCodexLoginGroup(name:"Owned")
        try FileManager.default.moveItem(atPath:group.home,toPath:group.home+"-old")
        try FileManager.default.createSymbolicLink(atPath:group.home,withDestinationPath:outside)
        var rejected=false
        do{_ = try await engine.inspectCodexAccount(home:group.home)}catch{rejected=true}
        try expect(rejected);try expect(probe.state.0.isEmpty,"Retargeted group must not query a different valid server")
    }
}
#endif
