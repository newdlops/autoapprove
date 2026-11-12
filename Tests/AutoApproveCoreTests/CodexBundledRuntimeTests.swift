#if DEBUG
import Foundation
import CryptoKit
import Darwin
@testable import AutoApproveCore

enum BundledRuntimeProbe {
    static func runIfRequested()async->Bool {
        let args=Array(CommandLine.arguments.dropFirst())
        let prepare=args.first=="--bundled-runtime-prepare"
        guard prepare || args.first=="--bundled-runtime-inspect" else{return false}
        do {
            guard args.count==(prepare ? 3:2) else{throw AppError.message("Expected runtime directory and optional owned home")}
            let runtime=try CodexBundledRuntime.inspect(root:args[1]);try runtime.verifyUnchanged()
            let version=try CommandRunner.run(runtime.executable,["--version"],timeout:10,
                environment:["PATH":"/usr/bin:/bin"],inheritEnvironment:false)
            guard version.status==0,version.output.trimmingCharacters(in:.whitespacesAndNewlines)=="codex-cli 0.167.1" else{throw AppError.message("Unexpected bundled CLI version")}
            if prepare {
                let home=args[2]
                guard home.hasPrefix("/private/tmp/aa-managed2-daemon-"),home.hasSuffix("/home") else{throw AppError.message("Owned daemon fixture home required")}
                let entry=TerminalProfileEntry(title:"Owned daemon fixture",agent:"codex",cwd:home,conversationID:"",providerHome:home)
                try await CodexBundledProfileLaunch.prepare(entry:entry,runtime:runtime,
                    server:.local(userHome:URL(fileURLWithPath:home).deletingLastPathComponent().path,executable:runtime.executable))
            }
            try runtime.verifyUnchanged()
            let output:[String:Any]=["verified":true,"version":runtime.version,"executable":runtime.executable,"serverPrepared":prepare,"migrationVerified":false]
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
    func testProfileLaunchKeepsBundledClientWithCompatibleNewerServer() async throws {
        let f=try BundledRuntimeFixture(),runtime=try CodexBundledRuntime.inspect(root:f.root.path)
        let home=f.root.appendingPathComponent("home"),cliPath=f.root.appendingPathComponent("installed codex '$literal")
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:false)
        try Data("#!/bin/sh\nprintf 'codex-cli 0.167.2\\n'\n".utf8).write(to:cliPath)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:cliPath.path)
        guard let cli=try CodexCLIContext.resolve(home:home.path,userHome:f.root.path,executable:cliPath.path) else {throw AppError.message("Missing owned fixture CLI")}
        let entry=TerminalProfileEntry(title:"Synthetic",agent:"codex",cwd:home.path,conversationID:UUID().uuidString,providerHome:home.path)
        let services=CodexManagedServerServices(inspect:{_,_ in .init(phase:.unavailable,version:"0.167.1",detail:"Existing server 0.167.2")},prepare:{_,_ in throw AppError.message("Never prepare or replace a live mismatching server")})
        let choice=try await CodexProfileLaunchRuntime.resolve(entry:entry,runtime:runtime,server:services,installed:{selected in
            try expectEqual(selected,home.path)
            return (cli,.init(phase:.running,version:"0.167.2",detail:"Matching installed CLI and existing socket"))
        })
        try expectEqual(choice.bundled?.executable,runtime.executable);try expectNil(choice.installed)
        try choice.verifyUnchanged()
        let command=try entry.resumeCommand(nativeRuntimeRoot:"/private/tmp/aa-codex-501",bundledRuntime:choice.bundled,compatibleCLI:choice.installed)
        try expect(command.contains([runtime.executable,"--remote","unix://","resume",entry.conversationID.lowercased()].map(HookInstaller.quote).joined(separator:" ")))
        try expect(command.contains(HookInstaller.quote("CODEX_HOME="+home.path)))
        try expect(!command.contains(cliPath.path))
        var rejected=false
        do {_ = try await CodexProfileLaunchRuntime.resolve(entry:entry,runtime:runtime,server:services,installed:{_ in nil})}
        catch {rejected=error.localizedDescription.contains("기존 서버는 유지했습니다")}
        try expect(rejected,"An incompatible live server cannot trigger a new daemon")
        rejected=false
        do {_ = try await CodexProfileLaunchRuntime.resolve(entry:entry,runtime:runtime,server:services,installed:{_ in (cli,.init(phase:.running,version:"0.168.0",detail:"Changed CLI"))})}
        catch {rejected=true}
        try expect(rejected,"Reported server and CLI versions must match")
        try Data("#!/bin/sh\nprintf 'codex-cli 0.168.0\\n'\n".utf8).write(to:cliPath)
        let future=try CodexCLIContext.resolve(home:home.path,userHome:f.root.path,executable:cliPath.path)!
        rejected=false
        do {_ = try await CodexProfileLaunchRuntime.resolve(entry:entry,runtime:runtime,server:services,installed:{_ in (future,.init(phase:.running,version:"0.168.0",detail:"Future server"))})}
        catch {rejected=error.localizedDescription.contains("AutoApprove 업데이트")}
        try expect(rejected,"Unverified future servers must not silently replace the app client")
        try choice.verifyUnchanged()
    }

    func testProfileLaunchUsesMatchingBundledServerWithoutChangingAutoStart() async throws {
        let f=try BundledRuntimeFixture(),runtime=try CodexBundledRuntime.inspect(root:f.root.path)
        let entry=TerminalProfileEntry(title:"Synthetic",agent:"codex",cwd:f.root.path,conversationID:"",providerHome:f.root.path)
        let services=CodexManagedServerServices(inspect:{_,_ in .init(phase:.running,version:"0.167.1",detail:"Existing server",autoStartEnabled:false)},prepare:{_,_ in throw AppError.message("Do not change existing server settings")})
        let choice=try await CodexProfileLaunchRuntime.resolve(entry:entry,runtime:runtime,server:services,installed:{_ in throw AppError.message("No fallback needed")})
        try expectEqual(choice.bundled?.executable,runtime.executable);try expectNil(choice.installed)
    }

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
