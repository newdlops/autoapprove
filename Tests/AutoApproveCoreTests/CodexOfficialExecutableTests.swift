#if DEBUG
import Foundation
@testable import AutoApproveCore

extension ApprovalTests {
    func testExitLaunchPersistenceOmitsSecretsAndPreservesLegacyPlans() throws {
        let process=ProcessDiscovery.parse("42 41 ttys901 42 42 Mon Sep 21 09:00:01 2026 /owned/codex")[0]
        let shell=ProcessDiscovery.parse("41 1 ttys901 41 41 Mon Sep 21 09:00:00 2026 /bin/zsh")[0]
        let session=AgentSession(id:process.key,agent:.codex,pid:42,started:process.started,tty:"/dev/ttys901",cwd:"/owned",terminal:.terminal)
        var plan=SessionExitRecovery(session:session,process:process,shell:shell,conversationID:"00000000-0000-4000-8000-000000000061")
        let legacy=try JSONEncoder().encode(plan)
        try expectNil(JSONDecoder().decode(SessionExitRecovery.self,from:legacy).codexLaunch)
        plan.codexLaunch = .init(executable:"/owned/codex",userHome:"/owned/user",providerHome:"/owned/login",path:"/owned/bin:/usr/bin:/bin")
        let encoded=try JSONEncoder().encode(plan)
        let restored=try JSONDecoder().decode(SessionExitRecovery.self,from:encoded)
        try expectEqual(restored.codexLaunch,plan.codexLaunch)
        try expectEqual(restored.conversationID,plan.conversationID)
        let object=try JSONSerialization.jsonObject(with:encoded) as! JSONObject
        try expectEqual(Set((object["codexLaunch"] as! JSONObject).keys),Set(["executable","userHome","providerHome","path"]))
        for bad in [CodexSessionLaunch(executable:"codex",userHome:"/owned",providerHome:"/owned/login",path:nil),
                    .init(executable:"/owned/codex",userHome:"relative",providerHome:"/owned/login",path:nil),
                    .init(executable:"/owned/codex",userHome:"/owned",providerHome:"/owned/login",path:"/bin\0ignored")] {
            try expectThrows(bad.officialContext(environment:[:]))
        }
    }
    func testAccountRuntimeBindsHomeAndExcludesInheritedAuthentication() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-account-runtime-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let binary=root.appendingPathComponent("codex")
        try Data([0xcf,0xfa,0xed,0xfe,0,0,0,0]).write(to:binary)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:binary.path)
        let target=CodexAccountTransitionTarget(home:root.path,executable:binary.path)
        let runtime=try CodexAccountRuntime(target,verifyExecutable:{_ in},environment:[
            "PATH":"/owned/node/bin:/usr/bin:/bin","HTTPS_PROXY":"http://127.0.0.1:9",
            "CODEX_HOME":"/owned/wrong-home","OPENAI_API_KEY":"owned-decoy",
            "CODEX_ACCESS_TOKEN":"owned-decoy","AUTOAPPROVE_SELECTED_TRANSITION_SOCKET":"/owned/old.sock"])
        try expectEqual(runtime.context.executable,binary.path)
        try expectEqual(runtime.context.environment["CODEX_HOME"],root.resolvingSymlinksInPath().path)
        try expectEqual(runtime.context.environment["PATH"],"/owned/node/bin:/usr/bin:/bin")
        try expectEqual(runtime.context.environment["HTTPS_PROXY"],"http://127.0.0.1:9")
        try expectNil(runtime.context.environment["OPENAI_API_KEY"])
        try expectNil(runtime.context.environment["CODEX_ACCESS_TOKEN"])
        try expectNil(runtime.context.environment["AUTOAPPROVE_SELECTED_TRANSITION_SOCKET"])
        try runtime.validate(target)
        try expectThrows(runtime.validate(.init(home:root.path+"/other",executable:binary.path)))
        try Data([0xcf,0xfa,0xed,0xfe,1]).write(to:binary)
        try expectThrows(runtime.validate(target))
    }
    func testOfficialSelectionRejectsForkAndPreservesChosenHome() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-official-choice-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let fork=root.appendingPathComponent("old-codex"),official=root.appendingPathComponent("official-codex")
        for file in [fork,official] {
            try Data([0xcf,0xfa,0xed,0xfe,0,0,0,0]).write(to:file)
            try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:file.path)
        }
        let environment=["PATH":"/usr/bin:/bin","AUTOAPPROVE_NATIVE_RUNTIME_ROOT":"/private/tmp/legacy",
            "AUTOAPPROVE_SELECTED_TRANSITION_SOCKET":"/private/tmp/legacy.sock"]
        let before=try CodexCLIContext.resolve(home:root.path,userHome:root.path,executable:fork.path,environment:environment)!
        let replacement=try CodexCLIContext.resolve(home:root.path,userHome:root.path,executable:official.path,environment:environment)!
        let expected=official.resolvingSymlinksInPath().path
        let verify:@Sendable (String)throws->Void = {path in guard path==expected else {throw AppError.message("Owned rejected fork")} }
        var fallbacks=0
        let selected=try CodexOfficialExecutable.select(preferred:before,verifyExecutable:verify,fallback:{fallbacks+=1;return replacement})!
        try expectEqual(fallbacks,1)
        try expectEqual(selected.executable,expected)
        try expectEqual(selected.environment["CODEX_HOME"],root.resolvingSymlinksInPath().path)
        try expectEqual(selected.environment["HOME"],root.path)
        try expectEqual(selected.environment["PATH"],environment["PATH"])
        try expectNil(selected.environment["AUTOAPPROVE_NATIVE_RUNTIME_ROOT"])
        try expectNil(selected.environment["AUTOAPPROVE_SELECTED_TRANSITION_SOCKET"])
        _ = try CodexOfficialExecutable.select(preferred:replacement,verifyExecutable:verify,fallback:{fallbacks+=1;return before})
        try expectEqual(fallbacks,1,"Existing attested CLI wins without inspecting another runtime")
        try expectThrows(CodexOfficialExecutable.select(preferred:before,verifyExecutable:verify,fallback:{before}))
        try expectThrows(CodexOfficialExecutable.select(preferred:before,verifyExecutable:verify,fallback:{nil}))
        try expectNil(CodexOfficialExecutable.select(preferred:nil,verifyExecutable:verify,fallback:{nil}))
        try Data([0xcf,0xfa,0xed,0xfe,1]).write(to:official)
        try expectThrows(selected.verifyUnchanged())
        try expectThrows(CodexOfficialExecutable.select(preferred:replacement,verifyExecutable:verify,fallback:{nil}))
    }
    func testOfficialNpmResolutionKeepsEnvironmentAndNeverRunsWrapper() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-official-npm-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        #if arch(arm64)
        let platform="codex-darwin-arm64",target="aarch64-apple-darwin"
        #else
        let platform="codex-darwin-x64",target="x86_64-apple-darwin"
        #endif
        for layout in ["nested","hoisted","legacy"] {
            let home=root.appendingPathComponent(layout),package=home.appendingPathComponent("node_modules/@openai/codex")
            let wrapper=package.appendingPathComponent("bin/codex.js"),marker=home.appendingPathComponent("wrapper-executed")
            let vendor:URL
            if layout=="nested" {vendor=package.appendingPathComponent("node_modules/@openai/"+platform+"/vendor")}
            else if layout=="hoisted" {vendor=home.appendingPathComponent("node_modules/@openai/"+platform+"/vendor")}
            else {vendor=package.appendingPathComponent("vendor")}
            let binary=vendor.appendingPathComponent(target+"/bin/codex")
            try FileManager.default.createDirectory(at:wrapper.deletingLastPathComponent(),withIntermediateDirectories:true)
            try FileManager.default.createDirectory(at:binary.deletingLastPathComponent(),withIntermediateDirectories:true)
            try Data(("#!/bin/sh\ntouch "+HookInstaller.quote(marker.path)+"\nexit 1\n").utf8).write(to:wrapper)
            try Data([0xcf,0xfa,0xed,0xfe,0,0,0,0]).write(to:binary)
            for path in [wrapper,binary] {try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:path.path)}
            try JSONSerialization.data(withJSONObject:["name":"@openai/codex","version":"0.169.0","bin":["codex":"bin/codex.js"]]).write(to:package.appendingPathComponent("package.json"))
            let original=try CodexCLIContext.resolve(home:home.path,userHome:home.path,executable:wrapper.path,
                environment:["PATH":"/usr/bin:/bin","AUTOAPPROVE_NATIVE_RUNTIME_ROOT":"/private/tmp/aa-codex-fixture"])!
            let expected=binary.resolvingSymlinksInPath().path
            let selected=try CodexOfficialExecutable.context(original,verifyExecutable:{path in try expectEqual(path,expected)})
            try expectEqual(selected.executable,expected)
            try expectEqual(selected.environment["CODEX_HOME"],home.resolvingSymlinksInPath().path)
            try expectEqual(selected.environment["PATH"],original.environment["PATH"])
            try expectNil(selected.environment["AUTOAPPROVE_NATIVE_RUNTIME_ROOT"])
            try expectFalse(FileManager.default.fileExists(atPath:marker.path))
            try expectThrows(CodexOfficialExecutable.context(original))
            try Data([0xcf,0xfa,0xed,0xfe,1]).write(to:binary)
            try expectThrows(selected.verifyUnchanged())
        }
    }
}
#endif
