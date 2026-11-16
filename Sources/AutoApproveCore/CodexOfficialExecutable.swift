import Foundation
import Security

/// Version output is not provenance: a patched build can print the upstream
/// version too. Verify the original OpenAI signature before executing a CLI.
enum CodexOfficialExecutable {
    private static let requirementText="anchor apple generic and identifier \"codex\" and certificate leaf[subject.OU] = \"2DC432GLL2\""
    /// Preserve the source TUI's actual local login home and PATH when opening
    /// a fork or reopening its exact conversation. This performs no TUI input.
    static func forSession(_ record:ProcessRecord,userHome:String=NSHomeDirectory(),
                           environment:[String:String]=ProcessInfo.processInfo.environment) throws ->CodexCLIContext {
        try CodexSessionLaunch.capture(record,userHome:userHome).officialContext(environment:environment)
    }
    /// Prefer an existing official installation, including its matching npm
    /// native payload. A previously selected fork may still be running; it is
    /// observed but never executed again by a new app-owned CLI operation.
    static func resolve(home:String,userHome:String,executable:String?,records:[ProcessRecord]=[],
                        environment:[String:String]=ProcessInfo.processInfo.environment,
                        verifyExecutable:@escaping @Sendable (String)throws->Void = {try verify($0)}) throws ->CodexCLIContext? {
        let home=try CodexAccountTransitionTarget.canonicalHome(home)
        let preferred=try CodexCLIContext.resolve(home:home,userHome:userHome,executable:executable,
            records:records,environment:environment)
        return try select(preferred:preferred,verifyExecutable:verifyExecutable,fallback:{
            if let bundle=try CodexBundledRuntime.bundled() {
                try bundle.verifyUnchanged()
                return try CodexCLIContext.resolve(home:home,userHome:userHome,executable:bundle.executable,
                    records:records,environment:environment)
            }
            // Ignore old process executable hints when looking for the user's
            // official PATH installation. The wrapper itself is never run.
            guard executable != nil || !records.isEmpty else{return nil}
            return try CodexCLIContext.resolve(home:home,userHome:userHome,executable:nil,environment:environment)
        })
    }
    static func select(preferred:CodexCLIContext?,
                       verifyExecutable:@escaping @Sendable (String)throws->Void = {try verify($0)},
                       fallback:()throws->CodexCLIContext?) throws ->CodexCLIContext? {
        try Task.checkCancellation()
        var rejected:Error?
        if let preferred {
            do {return try context(preferred,verifyExecutable:verifyExecutable)}
            catch is CancellationError {throw CancellationError()}
            catch {rejected=error}
        }
        try Task.checkCancellation()
        if let replacement=try fallback() {
            return try context(replacement,verifyExecutable:verifyExecutable)
        }
        if let rejected {throw rejected}
        return nil
    }
    /// npm's entrypoint is JavaScript. Resolve the official native payload using
    /// its package layout without executing the wrapper, then attest that code.
    /// Native/Homebrew paths retain their original literal invocation environment.
    static func context(_ original:CodexCLIContext,
                        verifyExecutable:@escaping @Sendable (String)throws->Void = {try verify($0)})throws->CodexCLIContext {
        try original.verifyUnchanged()
        let entry=URL(fileURLWithPath:original.executable).resolvingSymlinksInPath()
        let path:String
        if CodexCLIContext.native(entry.path) {path=entry.path}
        else {
            let root=entry.deletingLastPathComponent().deletingLastPathComponent()
            let metadata=root.appendingPathComponent("package.json")
            guard entry.lastPathComponent=="codex.js",entry.deletingLastPathComponent().lastPathComponent=="bin",
                  let size=(try? metadata.resourceValues(forKeys:[.fileSizeKey]))?.fileSize,size<=65536,
                  let package=try JSONSerialization.jsonObject(with:Data(contentsOf:metadata)) as? JSONObject,
                  package["name"] as? String=="@openai/codex",
                  (package["bin"] as? [String:String])?["codex"]=="bin/codex.js" else {
                throw AppError.message("공식 Codex 설치의 네이티브 실행 경로를 찾지 못했습니다. Codex 설치를 확인해주세요.")
            }
            #if arch(arm64)
            let platform="@openai/codex-darwin-arm64",target="aarch64-apple-darwin"
            #else
            let platform="@openai/codex-darwin-x64",target="x86_64-apple-darwin"
            #endif
            var directory=root,found:String?
            // Match Node's ancestor node_modules lookup; canonical package roots
            // also cover pnpm links. No PATH guesses or arbitrary wrapper parsing.
            for _ in 0..<64 {
                if directory.lastPathComponent != "node_modules" {
                    let candidate=directory.appendingPathComponent("node_modules/"+platform+"/vendor/"+target+"/bin/codex").path
                    if FileManager.default.fileExists(atPath:candidate) {found=candidate;break}
                }
                let parent=directory.deletingLastPathComponent()
                if parent==directory {break};directory=parent
            }
            path=URL(fileURLWithPath:found ?? root.appendingPathComponent("vendor/"+target+"/bin/codex").path).resolvingSymlinksInPath().path
        }
        let selected=try original.selectingNativeExecutable(path)
        try verifyExecutable(selected.executable)
        try original.verifyUnchanged();try selected.verifyUnchanged()
        return selected.verifyingManagedExecutables(verifyExecutable)
    }
    static func verify(_ path:String) throws {
        var requirement:SecRequirement?,code:SecStaticCode?
        let flags=SecCSFlags(rawValue:kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecRequirementCreateWithString(requirementText as CFString,[],&requirement)==errSecSuccess,
              let requirement,
              SecStaticCodeCreateWithPath(URL(fileURLWithPath:path) as CFURL,[],&code)==errSecSuccess,
              let code,SecStaticCodeCheckValidity(code,flags,requirement)==errSecSuccess else {
            throw AppError.message("OpenAI가 배포한 공식 Codex 실행 파일의 서명을 확인하지 못했습니다. Codex 설치를 확인해주세요.")
        }
    }
    /// Validate the code actually owning this Unix connection. A signed package
    /// at managedCodexPath is not proof that the running daemon is that package.
    /// The kernel audit token prevents a reused PID from satisfying this check.
    static func verifyServer(_ connection:CodexQueueConnection) throws ->CodexNativePeerIdentity {
        let peer=try connection.nativePeerIdentity()
        var requirement:SecRequirement?,code:SecCode?
        let attributes=[kSecGuestAttributeAudit as String:peer.auditToken] as CFDictionary
        guard peer.identity.effectiveUid==getuid(),peer.auditToken.count==32,
              SecRequirementCreateWithString(requirementText as CFString,[],&requirement)==errSecSuccess,
              let requirement,SecCodeCopyGuestWithAttributes(nil,attributes,[],&code)==errSecSuccess,
              let code,SecCodeCheckValidity(code,[],requirement)==errSecSuccess,
              try connection.nativePeerIdentity()==peer else {
            throw AppError.message("연결된 서버가 OpenAI 공식 Codex인지 확인하지 못했습니다. 기존 서버와 세션은 유지했습니다.")
        }
        return peer.identity
    }
}
