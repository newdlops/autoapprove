#if DEBUG
import Foundation
import CryptoKit
import Darwin
@testable import AutoApproveCore

enum BundledRuntimeProbe {
    static func runIfRequested()->Bool {
        let args=Array(CommandLine.arguments.dropFirst())
        guard args.first=="--bundled-runtime-inspect" else{return false}
        do {
            guard args.count==2 else{throw AppError.message("Expected one runtime directory")}
            let runtime=try CodexBundledRuntime.inspect(root:args[1]);try runtime.verifyUnchanged()
            let version=try CommandRunner.run(runtime.executable,["--version"],timeout:10,
                environment:["PATH":"/usr/bin:/bin"],inheritEnvironment:false)
            guard version.status==0,version.output.trimmingCharacters(in:.whitespacesAndNewlines)=="codex-cli 0.167.1" else{throw AppError.message("Unexpected bundled CLI version")}
            try runtime.verifyUnchanged()
            let output:[String:Any]=["verified":true,"version":runtime.version,"executable":runtime.executable,"migrationVerified":false]
            print(String(decoding:try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]),as:UTF8.self))
        }catch{fputs(error.localizedDescription+"\n",stderr);exit(1)}
        return true
    }
}

private final class BundledRuntimeFixture {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-bundle-"+UUID().uuidString)
    var binary:URL{root.appendingPathComponent("bin/codex")}
    var manifest:[String:Any]=[:]
    var bytes=Data([0xcf,0xfa,0xed,0xfe])
    init()throws {
        try FileManager.default.createDirectory(at:root.appendingPathComponent("bin"),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        // Put a required marker across the scanner's chunk boundary.
        bytes.append(Data(repeating:0,count:1_048_570-4))
        bytes.append(Data("autoapprove-managed-1671-2\0autoapprove-native-runtime-registration\0autoapprove-native-tui-input-hold".utf8))
        #if arch(arm64)
        let architecture="arm64",target="aarch64-apple-darwin"
        #else
        let architecture="x86_64",target="x86_64-apple-darwin"
        #endif
        manifest=["format":1,"upstreamVersion":"0.167.1","upstreamCommit":"0a94398fa60c4fac0e7659e4213a0a36e613dd46",
                  "buildLabel":"autoapprove-managed-1671-2","architecture":architecture,"nativeRuntimeSchemaVersion":1,
                  "features":["codex-app-server/autoapprove-goal-control","codex-app-server/autoapprove-native-inventory",
                              "codex-app-server/autoapprove-selected-transition","codex-tui/autoapprove-native-inventory"]]
        try JSONSerialization.data(withJSONObject:["version":"0.167.1","target":target,"entrypoint":"bin/codex"])
            .write(to:root.appendingPathComponent("codex-package.json"))
        try saveBinary();try saveManifest()
    }
    deinit{try? FileManager.default.removeItem(at:root)}
    func saveBinary()throws {
        try bytes.write(to:binary)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:binary.path)
        manifest["binarySHA256"]=SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
    }
    func saveManifest()throws{try JSONSerialization.data(withJSONObject:manifest).write(to:root.appendingPathComponent("manifest.json"))}
}
@MainActor private final class BundledLaunchCalls {
    var homes:[String]=[]
    func record(_ home:String){homes.append(home)}
}
extension ApprovalTests {
    func testBundledCodexProfileLaunchRequiresMatchingServerAndLiteralCommand() async throws {
        let f=try BundledRuntimeFixture(),runtime=try CodexBundledRuntime.inspect(root:f.root.path)
        let calls=BundledLaunchCalls(),home=f.root.appendingPathComponent("login group '$value")
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:false)
        let entry=TerminalProfileEntry(title:"Synthetic",agent:"codex",cwd:f.root.path,
                                       conversationID:UUID().uuidString,providerHome:home.path)
        let services=CodexManagedServerServices(inspect:{_,_ in throw AppError.message("Unexpected inspect")},prepare:{home,records in
            guard records.isEmpty else {throw AppError.message("Unexpected records")}
            await calls.record(home)
            return .init(phase:.running,version:"0.167.1",detail:"Synthetic")
        })
        try await CodexBundledProfileLaunch.prepare(entry:entry,runtime:runtime,server:services)
        try expectEqual(calls.homes,[try CodexAccountTransitionTarget.canonicalHome(home.path)])
        let command=try entry.resumeCommand(nativeRuntimeRoot:"/private/tmp/aa-codex-501",bundledRuntime:runtime)
        try expect(command.contains(HookInstaller.quote("CODEX_HOME="+home.path)))
        try expect(command.contains([runtime.executable,"--remote","unix://","resume",entry.conversationID.lowercased()].map(HookInstaller.quote).joined(separator:" ")))
        try expectFalse(try entry.resumeCommand().contains(runtime.executable))
        for status in [CodexManagedServerStatus(phase:.running,version:"0.168.0",detail:"Synthetic mismatch"),.init(phase:.unavailable,version:"0.167.1",detail:"Synthetic unknown")] {
            let wrong=CodexManagedServerServices(inspect:{_,_ in status},prepare:{_,_ in status})
            do {try await CodexBundledProfileLaunch.prepare(entry:entry,runtime:runtime,server:wrong);throw AppError.message("Unexpected preparation success")}
            catch {try expect(error.localizedDescription.contains("서버를 준비하지 못했습니다"))}
        }
        f.bytes.append(1);try f.saveBinary()
        do {try await CodexBundledProfileLaunch.prepare(entry:entry,runtime:runtime,server:services);throw AppError.message("Unexpected changed runtime success")}
        catch {try expect(error.localizedDescription.contains("지문"))}
        try expectEqual(calls.homes.count,1)
        try expectThrows(entry.resumeCommand(nativeRuntimeRoot:"/private/tmp/aa-codex-501",bundledRuntime:runtime))
    }
    func testBundledCodexRuntimeChecksDigestMarkersAndLaunchIdentity()throws {
        let f=try BundledRuntimeFixture()
        let runtime=try CodexBundledRuntime.inspect(root:f.root.path)
        try expectEqual(runtime.executable,f.binary.path);try runtime.verifyUnchanged()
        try expectEqual(runtime.version,"0.167.1")
        f.bytes.append(1);try f.saveBinary()
        try expectThrows(runtime.verifyUnchanged())
        try expectThrows(CodexBundledRuntime.inspect(root:f.root.path))
        try f.saveManifest()
        try CodexBundledRuntime.inspect(root:f.root.path).verifyUnchanged()
    }
    func testBundledCodexRuntimeRejectsWrongCapabilitiesLinksAndMissingCode()throws {
        let f=try BundledRuntimeFixture(),original=f.manifest
        for (field,value) in [("format",2),("buildLabel","autoapprove-managed-1671-1"),
                             ("nativeRuntimeSchemaVersion",2),("upstreamVersion","0.168.0"),
                             ("features",[]),("binarySHA256",String(repeating:"0",count:64))] as [(String,Any)] {
            f.manifest=original;f.manifest[field]=value;try f.saveManifest()
            try expectThrows(CodexBundledRuntime.inspect(root:f.root.path))
        }
        f.manifest=original;try f.saveManifest()
        let saved=f.root.appendingPathComponent("saved")
        try FileManager.default.moveItem(at:f.binary,to:saved)
        try FileManager.default.createSymbolicLink(at:f.binary,withDestinationURL:saved)
        try expectThrows(CodexBundledRuntime.inspect(root:f.root.path))
        try FileManager.default.removeItem(at:f.binary)
        f.bytes=Data([0xcf,0xfa,0xed,0xfe])+Data("autoapprove-managed-1671-2\0autoapprove-native-tui-input-hold".utf8)
        try f.saveBinary();try f.saveManifest()
        try expectThrows(CodexBundledRuntime.inspect(root:f.root.path))
        try expect(FileManager.default.fileExists(atPath:saved.path))
    }
}
#endif
