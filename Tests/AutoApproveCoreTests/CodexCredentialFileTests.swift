#if DEBUG
import Foundation
import Darwin
@testable import AutoApproveCore

private final class CredentialFileFixture {
    let root=URL(fileURLWithPath:"/private/tmp/aa-credential-file-"+UUID().uuidString)
    init()throws {try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}
    deinit{try? FileManager.default.removeItem(at:root)}
    func home(_ name:String)throws->String {
        let path=root.appendingPathComponent(name).path
        try FileManager.default.createDirectory(atPath:path,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);return path
    }
    func auth(_ home:String,_ value:String="owned-invalid-secret")throws {
        let path=home+"/auth.json";try Data(value.utf8).write(to:URL(fileURLWithPath:path));try expectEqual(chmod(path,0o600),0)
    }
    func rejects(_ operation:()throws->Void)throws {
        var rejected=false;do{try operation()}catch{rejected=true};try expect(rejected)
    }
}
extension ApprovalTests {
    func testCredentialFileIndependentPresentAndAbsentSlots()throws {
        let f=try CredentialFileFixture(),a=try f.home("a"),b=try f.home("b")
        try f.auth(a)
        let source=try CodexCredentialFile.capture(home:a),absent=try CodexCredentialFile.capture(home:b)
        try expect(source.entry != nil);try expect(absent.entry==nil)
        try CodexCredentialFile.requireIndependent(source,absent)
        try f.auth(b)
        try f.rejects{try absent.verifyCurrent()}
        try CodexCredentialFile.requireIndependent(source,CodexCredentialFile.capture(home:b))
    }
    func testCredentialFileRejectsHomeAliasesAndReplacedHome()throws {
        let f=try CredentialFileFixture(),a=try f.home("a"),alias=f.root.appendingPathComponent("alias").path
        try f.auth(a);try FileManager.default.createSymbolicLink(atPath:alias,withDestinationPath:a)
        let source=try CodexCredentialFile.capture(home:a),other=try CodexCredentialFile.capture(home:alias)
        try f.rejects{try CodexCredentialFile.requireIndependent(source,other)}
        let b=try f.home("b");try f.auth(b)
        try FileManager.default.removeItem(atPath:alias)
        try FileManager.default.createSymbolicLink(atPath:alias,withDestinationPath:b)
        try f.rejects{try other.verifyCurrent()}
        try FileManager.default.removeItem(atPath:alias)
        try FileManager.default.createSymbolicLink(atPath:alias,withDestinationPath:a)
        try FileManager.default.moveItem(atPath:a,toPath:a+"-old");_ = try f.home("a");try f.auth(a)
        try f.rejects{try source.verifyCurrent()};try f.rejects{try other.verifyCurrent()}
    }
    func testCredentialFileRejectsLinkedOrPublicCredentialFiles()throws {
        for kind in ["symlink","hardlink","public","directory","fifo"] {
            let f=try CredentialFileFixture(),a=try f.home("a"),b=try f.home("b")
            try f.auth(a)
            switch kind {
            case "symlink":try FileManager.default.createSymbolicLink(atPath:b+"/auth.json",withDestinationPath:a+"/auth.json")
            case "hardlink":try expectEqual(link(a+"/auth.json",b+"/auth.json"),0)
            case "public":try f.auth(b);try expectEqual(chmod(b+"/auth.json",0o644),0)
            case "directory":try FileManager.default.createDirectory(atPath:b+"/auth.json",withIntermediateDirectories:false)
            default:try expectEqual(mkfifo(b+"/auth.json",0o600),0)
            }
            let started=Date()
            try f.rejects{_ = try CodexCredentialFile.capture(home:b)}
            try expect(Date().timeIntervalSince(started)<1,"Special credential entries must not block inspection")
            if kind=="hardlink" {try f.rejects{_ = try CodexCredentialFile.capture(home:a)}}
        }
    }
    func testCredentialFileRejectsChangedOrRemovedEntries()throws {
        for kind in ["changed","removed","replacement","permissions"] {
            let f=try CredentialFileFixture(),a=try f.home("a");try f.auth(a)
            let before=try CodexCredentialFile.capture(home:a)
            switch kind {
            case "changed":try f.auth(a,"owned-changed-invalid-secret-longer")
            case "removed":try FileManager.default.removeItem(atPath:a+"/auth.json")
            case "replacement":try FileManager.default.moveItem(atPath:a+"/auth.json",toPath:a+"/old");try f.auth(a)
            default:try expectEqual(chmod(a+"/auth.json",0o644),0)
            }
            try f.rejects{try before.verifyCurrent()}
        }
    }
    func testCredentialFileSnapshotContainsNoCredentialContents()throws {
        let f=try CredentialFileFixture(),a=try f.home("a"),secret="UNUSABLE-SYNTHETIC-SECRET-731"
        try f.auth(a,secret)
        let before=try CodexCredentialFile.capture(home:a)
        try before.verifyCurrent()
        let encoded=String(decoding:try JSONEncoder().encode(before),as:UTF8.self)
        try expect(!encoded.contains(secret))
        try expectEqual(try String(contentsOfFile:a+"/auth.json",encoding:.utf8),secret)
        try expectEqual(try CodexCredentialFile.capture(home:a),before)
    }
}
#endif
