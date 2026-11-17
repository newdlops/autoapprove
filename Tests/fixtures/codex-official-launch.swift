import Foundation
@testable import AutoApproveCore

@main struct OfficialLaunchCheck {
    static func main() async throws {
        let root=CommandLine.arguments[1],executable=CommandLine.arguments[2],home=root+"/home"
        let profileStandalone=CommandLine.arguments.contains("--profile-standalone")
        let status=try await AgentAccountServices.local(userHome:root,codexHome:home,executable:executable).check("codex")
        guard status.phase=="signedOut" else {throw AppError.message("Owned empty login home was not signed out")}
        let environment=["HOME":root,"CODEX_HOME":home,"ZDOTDIR":root,
            "PATH":URL(fileURLWithPath:executable).deletingLastPathComponent().path+":/usr/bin:/bin",
            "HTTP_PROXY":"http://127.0.0.1:9","HTTPS_PROXY":"http://127.0.0.1:9","NO_PROXY":"localhost,127.0.0.1"]
        let terminal:ManagedPTY
        if profileStandalone {
            let runtime=try CodexBundledRuntime.inspect(root:URL(fileURLWithPath:executable).deletingLastPathComponent().deletingLastPathComponent().path)
            let entry=TerminalProfileEntry(title:"Owned official new profile",agent:"codex",cwd:root,conversationID:"",providerHome:home,
                executionSettings:.init(model:"gpt-6.1-sol",reasoningEffort:"xhigh",serviceTier:"ultrafast"))
            let services=CodexManagedServerServices(inspect:{_,_ in throw AppError.message(CodexFeatureSupport.legacyRuntimeUnavailable)},prepare:{_,_ in throw AppError.message("Must not prepare legacy daemon")})
            let choice=try await CodexProfileLaunchRuntime.resolve(entry:entry,runtime:runtime,server:services,installed:{_ in nil})
            guard choice.standalone else {throw AppError.message("New profile did not select standalone")}
            let command=try entry.resumeCommand(nativeRuntimeRoot:nil,bundledRuntime:choice.bundled,standalone:choice.standalone)
            terminal=try ManagedPTY(cwd:root,command:["/bin/zsh","-c",command],columns:120,rows:40,environment:environment)
        } else {terminal=try ManagedPTY(cwd:root,program:"codex",columns:120,rows:40,environment:environment)}
        defer {terminal.close()}
        for _ in 0..<150 {
            if let record=try ProcessDiscovery.read(pid:terminal.descriptor.pid).first(where:{$0.agent == .codex}) {
                let binary=CodexServerLocation.executable(record)
                let expected=URL(fileURLWithPath:executable).resolvingSymlinksInPath().path
                let actual=binary.map{URL(fileURLWithPath:$0).resolvingSymlinksInPath().path}
                let env=ProcessEnvironment.read(record,names:["HOME","CODEX_HOME","AUTOAPPROVE_NATIVE_RUNTIME_ROOT","AUTOAPPROVE_SELECTED_TRANSITION_SOCKET"])
                // macOS exposes /private/tmp through /tmp; compare the actual
                // selected directory, not two spellings of the same home.
                let selectedHome=env?["CODEX_HOME"].map{URL(fileURLWithPath:$0).resolvingSymlinksInPath().path}
                let expectedHome=URL(fileURLWithPath:home).resolvingSymlinksInPath().path
                guard actual==expected,env?["HOME"]==root,selectedHome==expectedHome,
                      env?["AUTOAPPROVE_NATIVE_RUNTIME_ROOT"]==nil,env?["AUTOAPPROVE_SELECTED_TRANSITION_SOCKET"]==nil else {
                    let checks=[actual==expected,env != nil,env?["HOME"]==root,selectedHome==expectedHome,
                        env?["AUTOAPPROVE_NATIVE_RUNTIME_ROOT"]==nil,env?["AUTOAPPROVE_SELECTED_TRANSITION_SOCKET"]==nil]
                    throw AppError.message("Owned native/envRead/HOME/CODEX_HOME/cleanRoot/cleanSocket: "+checks.map{String($0)}.joined(separator:","))
                }
                if profileStandalone {
                    // Allow real startup to encounter the selected cache if the
                    // generated command accidentally permits daemon autostart.
                    try await Task.sleep(for:.seconds(2))
                    guard terminal.descriptor.exitCode==nil else {throw AppError.message("New official profile exited during startup")}
                }
                let report:[String:Bool]=["verified":true,"officialSignatureChecked":true,"signedOutReadOnlyStatus":true,"actualPTYNativeExecutable":true,"selectedHomePreserved":true,"forkEnvironmentRemoved":true,"newProfileStandalone":profileStandalone,"profileExecutionOverridesAccepted":profileStandalone]
                print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),as:UTF8.self))
                return
            }
            if terminal.descriptor.exitCode != nil {throw AppError.message("Owned Codex exited before process identity verification")}
            try await Task.sleep(for:.milliseconds(40))
        }
        throw AppError.message("Owned Codex native process was not observed")
    }
}
