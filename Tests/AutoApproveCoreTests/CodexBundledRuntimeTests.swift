#if DEBUG
import Foundation
import CryptoKit
import Darwin
@testable import AutoApproveCore

enum BundledRuntimeProbe {
    static func runIfRequested()async->Bool {
        let args=Array(CommandLine.arguments.dropFirst())
        if args.first=="--official-server-inspect" {
            do {
                guard args.count==3,args[1].hasPrefix("/private/tmp/aa-managed2-daemon-") else {
                    throw AppError.message("Owned daemon fixture home and official CLI required")
                }
                // A valid on-disk binary must not attest a different process
                // answering at the selected home's socket.
                try CodexOfficialExecutable.verify(args[2])
                let peer=try CodexOfficialExecutable.verifyServer(CodexQueueConnection(home:args[1]))
                let userHome=URL(fileURLWithPath:args[1]).deletingLastPathComponent().path
                let providerHome=try CodexAccountTransitionTarget.canonicalHome(args[1])
                let launch=CodexSessionLaunch(executable:args[2],userHome:userHome,providerHome:args[1],path:"/usr/bin:/bin")
                let cli=try await launch.reconnectionContext(home:args[1],mode:.server)
                guard cli.environment["HOME"]==userHome,cli.environment["CODEX_HOME"]==providerHome,
                      cli.environment["AUTOAPPROVE_NATIVE_RUNTIME_ROOT"]==nil,
                      cli.environment["AUTOAPPROVE_SELECTED_TRANSITION_SOCKET"]==nil else {
                    throw AppError.message("Reconnect environment mismatch: HOME=\(cli.environment["HOME"] ?? "nil") expected=\(userHome) CODEX_HOME=\(cli.environment["CODEX_HOME"] ?? "nil") expected=\(providerHome) native=\(cli.environment["AUTOAPPROVE_NATIVE_RUNTIME_ROOT"] != nil) selected=\(cli.environment["AUTOAPPROVE_SELECTED_TRANSITION_SOCKET"] != nil)")
                }
                print(String(decoding:try JSONSerialization.data(withJSONObject:["verified":true,"pid":peer.pid,"reconnectExecutable":cli.executable]),as:UTF8.self))
            } catch {fputs(error.localizedDescription+"\n",stderr);exit(1)}
            return true
        }
        if args.first=="--official-cli-inspect" {
            do {
                guard args.count==2,let original=try CodexCLIContext.resolve(home:"/private/tmp",userHome:"/private/tmp",executable:args[1],environment:["PATH":"/usr/bin:/bin"]) else{throw AppError.message("Expected installed CLI path")}
                let cli=try CodexOfficialExecutable.context(original)
                let result=try cli.run(["--version"])
                guard result.status==0 else{throw AppError.message("Official CLI version failed")}
                print(String(decoding:try JSONSerialization.data(withJSONObject:["verified":true,"executable":cli.executable,"version":result.output.trimmingCharacters(in:.whitespacesAndNewlines)]),as:UTF8.self))
            } catch {fputs(error.localizedDescription+"\n",stderr);exit(1)}
            return true
        }
        let prepare=args.first=="--bundled-runtime-prepare"
        guard prepare || args.first=="--bundled-runtime-inspect" else{return false}
        do {
            guard args.count==(prepare ? 3:2) else{throw AppError.message("Expected runtime directory and optional owned home")}
            let runtime=try CodexBundledRuntime.inspect(root:args[1]);try runtime.verifyUnchanged()
            try CodexOfficialExecutable.verify(runtime.executable)
            let version=try CommandRunner.run(runtime.executable,["--version"],timeout:10,
                environment:["PATH":"/usr/bin:/bin"],inheritEnvironment:false)
            guard version.status==0,version.output.trimmingCharacters(in:.whitespacesAndNewlines)=="codex-cli "+runtime.version else{throw AppError.message("Unexpected bundled CLI version")}
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
        // The fixture has no AutoApprove-specific code or capability markers.
        bytes.append(Data(repeating:0,count:1_048_600))
        #if arch(arm64)
        let architecture="arm64",target="aarch64-apple-darwin"
        #else
        let architecture="x86_64",target="x86_64-apple-darwin"
        #endif
        let package=try JSONSerialization.data(withJSONObject:["version":"0.167.1","target":target,"entrypoint":"bin/codex"])
        try package.write(to:root.appendingPathComponent("codex-package.json"))
        manifest=["format":1,"version":"0.167.1","upstreamCommit":String(repeating:"a",count:40),
                  "architecture":architecture,"target":target,
                  "files":["codex-package.json":SHA256.hash(data:package).map{String(format:"%02x",$0)}.joined()]]
        try saveBinary();try saveManifest()
    }
    deinit{try? FileManager.default.removeItem(at:root)}
    func saveBinary()throws {
        try bytes.write(to:binary)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:binary.path)
        var files=manifest["files"] as! [String:String]
        files["bin/codex"]=SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
        manifest["files"]=files
    }
    var release:CodexBundledRuntime.Release {
        get throws {try JSONDecoder().decode(CodexBundledRuntime.Release.self,from:JSONSerialization.data(withJSONObject:manifest))}
    }
    func saveManifest()throws{try JSONSerialization.data(withJSONObject:manifest).write(to:root.appendingPathComponent("manifest.json"))}
}
@MainActor private final class BundledLaunchCalls {
    var homes:[String]=[]
    func record(_ home:String){homes.append(home)}
}
extension ApprovalTests {
    // Synthetic shell fixtures exercise selection and races; they cannot pass
    // the production OpenAI signature check, which has separate negative tests.
    nonisolated private static func verifyFixtureCLI(_ cli:CodexCLIContext,_ version:String)throws {
        let reply=try cli.run(["--version"])
        guard reply.status==0,reply.output.trimmingCharacters(in:.whitespacesAndNewlines)=="codex-cli "+version,
              CodexAccountTransitionLocal.supported(version) else {throw AppError.message("Fixture version mismatch")}
    }
    func testProfileLaunchAttestsNewerServerAfterStart() async throws {
        let f=try BundledRuntimeFixture(),runtime=try CodexBundledRuntime.inspect(root:f.root.path,release:f.release),calls=BundledLaunchCalls()
        let cliPath=f.root.appendingPathComponent("managed-codex")
        try Data("#!/bin/sh\nprintf 'codex-cli 0.169.0\\n'\n".utf8).write(to:cliPath)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:cliPath.path)
        let cli=try CodexCLIContext.resolve(home:f.root.path,userHome:f.root.path,executable:cliPath.path)!
        let entry=TerminalProfileEntry(title:"Restore",agent:"codex",cwd:f.root.path,conversationID:UUID().uuidString,providerHome:f.root.path)
        let services=CodexManagedServerServices(inspect:{_,_ in .init(phase:.stopped,version:"0.167.1",detail:"Stopped")},prepare:{home,_ in
            await calls.record(home)
            return .init(phase:.unavailable,version:"0.167.1",detail:"서버 시작 명령은 끝났지만 실행 상태를 확인하지 못했습니다.")
        })
        let result=try await CodexProfileLaunchRuntime.resolve(entry:entry,runtime:runtime,server:services,installed:{home in
            try expectEqual(home,f.root.path)
            return (cli,.init(phase:.running,version:"0.169.0",detail:"Attested managed CLI and socket"))
        },verifyInstalled:{try Self.verifyFixtureCLI($0,$1)})
        try expectNil(result.bundled);try expectEqual(result.installed?.executable,cli.executable)
        try expectEqual(result.version,"0.169.0")
        try expectEqual(calls.homes,[f.root.path])
        var rejected=false
        do {_ = try await CodexProfileLaunchRuntime.resolve(entry:entry,runtime:runtime,server:services,installed:{_ in nil})}
        catch {rejected=error.localizedDescription.contains("서버를 준비하지 못했습니다")}
        try expect(rejected,"A successful start alone is never proof of a usable server")
    }
    func testProfileLaunchSelectsMatchingOfficialClient() async throws {
        let f=try BundledRuntimeFixture(),runtime=try CodexBundledRuntime.inspect(root:f.root.path,release:f.release)
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
        },verifyInstalled:{try Self.verifyFixtureCLI($0,$1)})
        try expectNil(choice.bundled);try expectEqual(choice.installed?.executable,cli.executable)
        try choice.verifyUnchanged()
        let command=try entry.resumeCommand(nativeRuntimeRoot:nil,bundledRuntime:choice.bundled,compatibleCLI:choice.installed)
        try expect(command.contains([cli.executable,"--remote","unix://","resume",entry.conversationID.lowercased()].map(HookInstaller.quote).joined(separator:" ")))
        try expect(command.contains(HookInstaller.quote("CODEX_HOME="+home.path)))
        try expect(!command.contains(runtime.executable))
        try expect(command.contains("'-u' 'AUTOAPPROVE_NATIVE_RUNTIME_ROOT'"))
        try expect(!command.contains("AUTOAPPROVE_NATIVE_RUNTIME_ROOT="))
        var rejected=false
        do {_ = try await CodexProfileLaunchRuntime.resolve(entry:entry,runtime:runtime,server:services,installed:{_ in nil})}
        catch {rejected=error.localizedDescription.contains("기존 서버는 유지했습니다")}
        try expect(rejected,"An incompatible live server cannot trigger a new daemon")
        rejected=false
        do {_ = try await CodexProfileLaunchRuntime.resolve(entry:entry,runtime:runtime,server:services,installed:{_ in (cli,.init(phase:.running,version:"0.168.0",detail:"Changed CLI"))},verifyInstalled:{try Self.verifyFixtureCLI($0,$1)})}
        catch {rejected=true}
        try expect(rejected,"Reported server and CLI versions must match")
        try Data("#!/bin/sh\nprintf 'codex-cli 0.168.0\\n'\n".utf8).write(to:cliPath)
        try expectThrows(choice.verifyUnchanged())
        try Data("#!/bin/sh\nprintf 'codex-cli 0.169.0\\n'\n".utf8).write(to:cliPath)
        let current=try CodexCLIContext.resolve(home:home.path,userHome:f.root.path,executable:cliPath.path)!
        let currentChoice=try await CodexProfileLaunchRuntime.resolve(entry:entry,runtime:runtime,server:services,installed:{_ in (current,.init(phase:.running,version:"0.169.0",detail:"Verified server"))},verifyInstalled:{try Self.verifyFixtureCLI($0,$1)})
        try expectNil(currentChoice.bundled);try expectEqual(currentChoice.installed?.executable,current.executable)
        try currentChoice.verifyUnchanged()
    }

    func testProfileLaunchRejectsUnsignedVersionSpoofBeforeExecution() async throws {
        let f=try BundledRuntimeFixture(),runtime=try CodexBundledRuntime.inspect(root:f.root.path,release:f.release)
        let cliPath=f.root.appendingPathComponent("fake-codex"),marker=f.root.appendingPathComponent("executed")
        try Data(("#!/bin/sh\ntouch "+HookInstaller.quote(marker.path)+"\nprintf 'codex-cli 0.169.0\\n'\n").utf8).write(to:cliPath)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:cliPath.path)
        let cli=try CodexCLIContext.resolve(home:f.root.path,userHome:f.root.path,executable:cliPath.path)!
        let entry=TerminalProfileEntry(title:"Synthetic",agent:"codex",cwd:f.root.path,conversationID:UUID().uuidString,providerHome:f.root.path)
        let services=CodexManagedServerServices(inspect:{_,_ in .init(phase:.unavailable,detail:"Different server")},prepare:{_,_ in throw AppError.message("Must not start")})
        var rejected=false
        do {
            _ = try await CodexProfileLaunchRuntime.resolve(entry:entry,runtime:runtime,server:services,installed:{_ in
                (cli,.init(phase:.running,version:"0.169.0",detail:"Untrusted version claim"))
            })
        } catch {rejected=error.localizedDescription.contains("공식 Codex")}
        try expect(rejected,"Version output cannot attest official code")
        try expectFalse(FileManager.default.fileExists(atPath:marker.path))
        var fresh=entry;fresh.conversationID=""
        let fallback=try await CodexProfileLaunchRuntime.resolve(entry:fresh,runtime:runtime,server:services,installed:{_ in
            (cli,.init(phase:.running,version:"0.169.0",detail:"Untrusted version claim"))
        })
        try expect(fallback.standalone)
        try expectEqual(fallback.bundled?.executable,runtime.executable)
        try expectNil(fallback.installed)
        try expectFalse(FileManager.default.fileExists(atPath:marker.path),"New-session fallback cannot run the rejected CLI")
        rejected=false
        do {_ = try await CodexManagedServerServices.local(userHome:f.root.path,executable:cli.executable).inspect(f.root.path,[])}
        catch {rejected=error.localizedDescription.contains("공식 Codex")}
        try expect(rejected,"Daemon inspection must attest before executing the observer")
        try expectFalse(FileManager.default.fileExists(atPath:marker.path))
    }

    func testProfileLaunchUsesMatchingBundledServerWithoutChangingAutoStart() async throws {
        let f=try BundledRuntimeFixture(),runtime=try CodexBundledRuntime.inspect(root:f.root.path,release:f.release)
        let entry=TerminalProfileEntry(title:"Synthetic",agent:"codex",cwd:f.root.path,conversationID:"",providerHome:f.root.path)
        let services=CodexManagedServerServices(inspect:{_,_ in .init(phase:.running,version:"0.167.1",detail:"Existing server",autoStartEnabled:false)},prepare:{_,_ in throw AppError.message("Do not change existing server settings")})
        let choice=try await CodexProfileLaunchRuntime.resolve(entry:entry,runtime:runtime,server:services,installed:{_ in throw AppError.message("No fallback needed")})
        try expectEqual(choice.bundled?.executable,runtime.executable);try expectNil(choice.installed)
    }

    func testProfileLaunchWithoutBundleUsesVerifiedInstalledCLI() async throws {
        let f=try BundledRuntimeFixture(),cliPath=f.root.appendingPathComponent("installed-codex"),calls=BundledLaunchCalls()
        try Data("#!/bin/sh\nprintf 'codex-cli 0.169.0\\n'\n".utf8).write(to:cliPath)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:cliPath.path)
        let cli=try CodexCLIContext.resolve(home:f.root.path,userHome:f.root.path,executable:cliPath.path)!
        let entry=TerminalProfileEntry(title:"Installed only",agent:"codex",cwd:f.root.path,conversationID:"",providerHome:f.root.path)
        for stopped in [false,true] {
            let services=CodexManagedServerServices(inspect:{_,_ in .init(phase:stopped ? .stopped:.running,version:"0.169.0",detail:"Owned")},prepare:{home,_ in
                await calls.record(home);return .init(phase:.running,version:"0.169.0",detail:"Owned prepared")
            })
            let selected=try await CodexProfileLaunchRuntime.resolveInstalled(entry:entry,cli:cli,server:services,installed:{_ in throw AppError.message("Unneeded fallback")},verifyInstalled:{try Self.verifyFixtureCLI($0,$1)})
            try expectNil(selected.bundled);try expectEqual(selected.installed?.executable,cli.executable)
            let command=try entry.resumeCommand(nativeRuntimeRoot:nil,bundledRuntime:nil,compatibleCLI:selected.installed)
            try expect(command.contains(HookInstaller.quote(cli.executable)))
            try expect(command.contains("'-u' 'AUTOAPPROVE_NATIVE_RUNTIME_ROOT'"))
            try expect(!command.contains("AUTOAPPROVE_NATIVE_RUNTIME_ROOT="))
        }
        try expectEqual(calls.homes,[f.root.path])
    }

    func testNewProfileLaunchCanBypassUnavailableServerWithoutResuming() async throws {
        let f=try BundledRuntimeFixture(),runtime=try CodexBundledRuntime.inspect(root:f.root.path,release:f.release),calls=BundledLaunchCalls()
        let fresh=TerminalProfileEntry(title:"New official conversation",agent:"codex",cwd:f.root.path,conversationID:"",providerHome:f.root.path)
        for inspectionThrows in [false,true] {
            let services=CodexManagedServerServices(inspect:{_,_ in
                if inspectionThrows {throw AppError.message(CodexFeatureSupport.legacyRuntimeUnavailable)}
                return .init(phase:.unavailable,detail:"Legacy server")
            },prepare:{home,_ in await calls.record(home);throw AppError.message("Must not replace legacy server")})
            let selected=try await CodexProfileLaunchRuntime.resolve(entry:fresh,runtime:runtime,server:services,installed:{_ in nil})
            try expect(selected.standalone)
            let command=try fresh.resumeCommand(nativeRuntimeRoot:nil,bundledRuntime:selected.bundled,standalone:selected.standalone)
            try expect(command.contains(HookInstaller.quote(runtime.executable)))
            try expect(command.contains("'-c' 'features.daemon_auto_start=false'"))
            try expectFalse(command.contains("--remote"))
            try expectFalse(command.contains("'resume'"))
            var saved=fresh;saved.conversationID=UUID().uuidString
            var rejected=false
            do {_ = try await CodexProfileLaunchRuntime.resolve(entry:saved,runtime:runtime,server:services,installed:{_ in nil})}
            catch {rejected=true}
            try expect(rejected,"Saved conversations still require an attested server")
            try expectThrows(saved.resumeCommand(nativeRuntimeRoot:nil,bundledRuntime:runtime,standalone:true))
        }
        try expectEqual(calls.homes,[])
        let cancelled=CodexManagedServerServices(inspect:{_,_ in throw CancellationError()},prepare:{_,_ in throw AppError.message("Must not prepare")})
        var cancellationPreserved=false
        do {_ = try await CodexProfileLaunchRuntime.resolve(entry:fresh,runtime:runtime,server:cancelled,installed:{_ in nil})}
        catch is CancellationError {cancellationPreserved=true}
        try expect(cancellationPreserved)
        f.bytes.append(1);try f.saveBinary()
        var tamperRejected=false
        do {_ = try await CodexProfileLaunchRuntime.resolve(entry:fresh,runtime:runtime,server:cancelled,installed:{_ in nil})}
        catch {tamperRejected=error.localizedDescription.contains("지문")}
        try expect(tamperRejected,"Fallback cannot authorize changed bundled bytes")
    }

    func testBundledCodexProfileLaunchRequiresMatchingServerAndLiteralCommand() async throws {
        let f=try BundledRuntimeFixture(),runtime=try CodexBundledRuntime.inspect(root:f.root.path,release:f.release)
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
        let command=try entry.resumeCommand(nativeRuntimeRoot:nil,bundledRuntime:runtime)
        try expect(command.contains(HookInstaller.quote("CODEX_HOME="+home.path)))
        try expect(command.contains("'-u' 'AUTOAPPROVE_NATIVE_RUNTIME_ROOT'"))
        try expect(!command.contains("AUTOAPPROVE_NATIVE_RUNTIME_ROOT="))
        try expect(command.contains([runtime.executable,"--remote","unix://","resume",entry.conversationID.lowercased()].map(HookInstaller.quote).joined(separator:" ")))
        try expectFalse(try entry.resumeCommand().contains(runtime.executable))
        for status in [CodexManagedServerStatus(phase:.running,version:"0.168.0",detail:"Synthetic mismatch"),.init(phase:.unavailable,version:"0.167.1",detail:"Synthetic unknown")] {
            let wrong=CodexManagedServerServices(inspect:{_,_ in status},prepare:{_,_ in status})
            do {try await CodexBundledProfileLaunch.prepare(entry:entry,runtime:runtime,server:wrong,installed:{_ in nil});throw AppError.message("Unexpected preparation success")}
            catch {try expect(error.localizedDescription.contains("서버를 준비하지 못했습니다"))}
        }
        f.bytes.append(1);try f.saveBinary()
        do {try await CodexBundledProfileLaunch.prepare(entry:entry,runtime:runtime,server:services);throw AppError.message("Unexpected changed runtime success")}
        catch {try expect(error.localizedDescription.contains("지문"))}
        try expectEqual(calls.homes.count,1)
        try expectThrows(entry.resumeCommand(nativeRuntimeRoot:"/private/tmp/aa-codex-501",bundledRuntime:runtime))
    }
    func testBundledCodexRuntimeChecksOfficialDigestAndLaunchIdentity()throws {
        let f=try BundledRuntimeFixture(),trusted=try f.release
        let runtime=try CodexBundledRuntime.inspect(root:f.root.path,release:trusted)
        try expectEqual(runtime.executable,f.binary.path);try runtime.verifyUnchanged()
        try expectEqual(runtime.version,"0.167.1")
        f.bytes.append(1);try f.saveBinary();try f.saveManifest()
        try expectThrows(runtime.verifyUnchanged())
        // Updating a runtime's self-published manifest never authorizes new code.
        try expectThrows(CodexBundledRuntime.inspect(root:f.root.path,release:trusted))
        try expectThrows(CodexBundledRuntime.inspect(root:f.root.path))
    }
    func testBundledCodexRuntimeRejectsUnpinnedMetadataLinksAndMissingCode()throws {
        let f=try BundledRuntimeFixture(),original=f.manifest
        for (field,value) in [("format",2),("version","untrusted"),("target","wrong-target"),
                             ("architecture","wrong-architecture"),("files",[:])] as [(String,Any)] {
            f.manifest=original;f.manifest[field]=value
            try expectThrows(CodexBundledRuntime.inspect(root:f.root.path,release:f.release))
        }
        f.manifest=original
        let trusted=try f.release,saved=f.root.appendingPathComponent("saved")
        try FileManager.default.moveItem(at:f.binary,to:saved)
        try FileManager.default.createSymbolicLink(at:f.binary,withDestinationURL:saved)
        try expectThrows(CodexBundledRuntime.inspect(root:f.root.path,release:trusted))
        try FileManager.default.removeItem(at:f.binary)
        try expectThrows(CodexBundledRuntime.inspect(root:f.root.path,release:trusted))
        try Data([1,2,3]).write(to:f.root.appendingPathComponent("codex-package.json"))
        try FileManager.default.moveItem(at:saved,to:f.binary)
        try expectThrows(CodexBundledRuntime.inspect(root:f.root.path,release:trusted))
    }
}
#endif
