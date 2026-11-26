import Foundation
import Darwin
import CoreGraphics

public struct TerminalProfileTabLayout: Codable, Equatable, Sendable {
    public var window:UUID
    public var windowOrder:Int
    public var tabOrder:Int
    public var selected:Bool
    public var settingsName:String?
    public var customTitle:String?
    public var bounds:TerminalWindowBounds?
    public init(window:UUID,windowOrder:Int,tabOrder:Int,selected:Bool=false,settingsName:String?=nil,customTitle:String?=nil,bounds:TerminalWindowBounds?=nil) {
        self.window=window;self.windowOrder=windowOrder;self.tabOrder=tabOrder;self.selected=selected;self.settingsName=settingsName;self.customTitle=customTitle;self.bounds=bounds
    }
    public func validated() throws -> Self {
        guard bounds.map({ $0.profileRect != nil }) ?? true, (0..<512).contains(windowOrder),(0..<4096).contains(tabOrder),
              [settingsName,customTitle].allSatisfy({value in value.map {$0.count<=256 && !$0.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains)} ?? true}),
              settingsName.map({!$0.isEmpty}) ?? true else {throw AppError.message("Terminal의 창·탭 순서와 설정 프로필을 확인해주세요.")}
        return self
    }
    public var label:String {"창 \(windowOrder+1) · 탭 \(tabOrder+1)"+(selected ? " · 선택 탭":"")}
}

public struct TerminalProfileEntry: Codable, Equatable, Identifiable, Sendable {
    public enum Host: String, Codable, Sendable, CaseIterable { case terminal, iterm }
    public var id: UUID
    public var title: String
    public var agent: String
    public var cwd: String
    public var conversationID: String
    public var providerHome: String?
    public var host: Host
    public var terminalTab:TerminalProfileTabLayout?
    public var usesProfileReasoningEffort: Bool?
    public var executionSettings: TerminalProfileExecutionSettings?
    public init(id: UUID = UUID(), title: String, agent: String, cwd: String, conversationID: String,
                providerHome: String? = nil, host: Host = .terminal,terminalTab:TerminalProfileTabLayout?=nil, executionSettings: TerminalProfileExecutionSettings? = nil) {
        self.id=id; self.title=title; self.agent=agent; self.cwd=cwd; self.conversationID=conversationID
        self.providerHome=providerHome; self.host=host;self.terminalTab=terminalTab
        self.executionSettings = executionSettings
        self.usesProfileReasoningEffort = executionSettings?.reasoningEffort == nil ? nil : true
    }
    public var resumesConversation:Bool {!conversationID.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}
    public var key: String {
        let conversation=conversationID.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        return agent+"\n"+(providerHome ?? "")+"\n"+(conversation.isEmpty ? "new\n"+cwd+"\n"+id.uuidString.lowercased():conversation)
    }
    public var terminalTabSummary:String {
        guard host == .terminal else {return ""}
        return (terminalTab?.label ?? "한 창의 탭으로 복원")+(terminalTab?.settingsName.map {" · 설정: "+$0} ?? "")
    }
    public func validated() throws -> Self {
        let conversation=conversationID.trimmingCharacters(in:.whitespacesAndNewlines)
        guard ["codex","claude","agy"].contains(agent) else {throw AppError.message("CLI 종류는 Codex, Claude Code 또는 Antigravity를 선택해주세요.")}
        guard Self.path(cwd) else {throw AppError.message("작업 폴더의 전체 경로를 입력해주세요.")}
        guard providerHome.map(Self.path) ?? true else {throw AppError.message("CLI 설정 폴더의 전체 경로를 확인해주세요.")}
        guard conversation.isEmpty || UUID(uuidString:conversation) != nil else {throw AppError.message("대화 ID를 입력할 때는 UUID 형식을 사용해주세요. 비워 두면 새 CLI를 엽니다.")}
        guard title.count<=256,!title.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else {throw AppError.message("프로필 항목 이름은 줄바꿈 없이 256자까지 입력해주세요.")}
        var copy=self;copy.conversationID=UUID(uuidString:conversation)?.uuidString.lowercased() ?? "";copy.terminalTab=try terminalTab?.validated()
        copy.executionSettings = try executionSettings?.validated(agent: agent)
        if copy.executionSettings?.isEmpty == true { copy.executionSettings = nil }
        return copy
    }
    private static func path(_ value: String) -> Bool {
        value.hasPrefix("/") && value.utf8.count <= 4096 && !value.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains)
    }
    public func resumeCommand(nativeRuntimeRoot:String?=nil) throws -> String {
        try TerminalProfileExecutionSettingsReader.refreshed([self])[0].resumeCommand(nativeRuntimeRoot:nativeRuntimeRoot,bundledRuntime:nil)
    }
    func resumeCommand(nativeRuntimeRoot:String?,bundledRuntime:CodexBundledRuntime.Installation?,compatibleCLI:CodexCLIContext?=nil,standalone:Bool=false) throws -> String {
        let entry=try validated()
        guard !standalone || (entry.agent == "codex" && !entry.resumesConversation && (bundledRuntime != nil || compatibleCLI != nil)) else {
            throw AppError.message("독립 실행은 검증된 공식 Codex의 새 대화에만 사용할 수 있습니다.")
        }
        if let bundledRuntime {
            guard entry.agent == "codex" else {throw AppError.message("Codex 실행 환경을 확인해주세요.")}
            try bundledRuntime.verifyUnchanged()
        }
        if let compatibleCLI {
            guard entry.agent == "codex",bundledRuntime==nil else {throw AppError.message("Codex 복원 실행 환경을 확인해주세요.")}
            try compatibleCLI.verifyUnchanged()
        }
        var arguments=["env"]
        guard nativeRuntimeRoot==nil else {throw AppError.message("공식 Codex는 전용 제어 등록 경로를 사용하지 않습니다.")}
        if entry.agent == "codex" {arguments += ["-u","AUTOAPPROVE_NATIVE_RUNTIME_ROOT","-u","AUTOAPPROVE_SELECTED_TRANSITION_SOCKET"]}
        if entry.agent == "claude", entry.providerHome == nil { arguments += ["-u", "CLAUDE_CONFIG_DIR"] }
        if entry.agent != "agy", let home=entry.providerHome {arguments.append((agent == "codex" ? "CODEX_HOME":"CLAUDE_CONFIG_DIR")+"="+home)}
        if let searchPath=compatibleCLI?.environment["PATH"] {arguments.append("PATH="+searchPath)}
        if entry.agent == "claude" { arguments += [ClaudePromptBridge.key + "=" + ClaudePromptBridge.channel(AppPaths()).path, ClaudePromptBridge.disableFeedbackSurvey] }
        arguments.append(compatibleCLI?.executable ?? bundledRuntime?.executable ?? agent)
        if bundledRuntime != nil || compatibleCLI != nil {
            arguments += standalone ? ["-c","features.daemon_auto_start=false"]:["--remote","unix://"]
        }
        if entry.resumesConversation {arguments += [agent == "codex" ? "resume":agent == "agy" ? "--conversation":"--resume",entry.conversationID]}
        if entry.agent == "claude" { arguments += ["--plugin-dir", ClaudePromptBridge.plugin.path] }
        arguments += try entry.executionSettings?.arguments(agent: entry.agent) ?? []
        return "cd -- "+HookInstaller.quote(entry.cwd)+" && "+arguments.map(HookInstaller.quote).joined(separator:" ")
    }
}

public struct TerminalSessionProfile: Codable, Equatable, Identifiable, Sendable {
    public var schema: Int = 4
    public var id: UUID
    public var name: String
    public var savedAt: Date
    public var entries: [TerminalProfileEntry]
    public var groups: [TerminalProfileGroup]?
    public init(id: UUID = UUID(), name: String, savedAt: Date = Date(), entries: [TerminalProfileEntry], groups:[TerminalProfileGroup]?=nil) {
        self.id=id;self.name=name;self.savedAt=savedAt;self.entries=entries;self.groups=groups
    }
    public func validatedForSaving(newCLIIDs:Set<UUID>) throws -> Self {
        guard newCLIIDs.isSubset(of:Set(entries.map(\.id))) else {throw AppError.message("새 CLI로 저장할 항목을 다시 확인해주세요.")}
        var profile=self
        for index in profile.entries.indices {
            if newCLIIDs.contains(profile.entries[index].id) {profile.entries[index].conversationID=""}
            else if !profile.entries[index].resumesConversation {
                throw AppError.message("이어갈 대화를 확인하지 못한 항목이 있습니다. 대화를 선택하거나 ‘새 CLI 실행’을 선택해주세요.")
            }
        }
        return try profile.validated()
    }
    public func validated() throws -> Self {
        var result=self; result.name=name.trimmingCharacters(in:.whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard (1...4).contains(schema),schema >= 2 || entries.allSatisfy({$0.terminalTab==nil}),schema >= 3 || groups == nil,
              schema >= 4 || entries.allSatisfy({ $0.executionSettings == nil }) else {throw AppError.message("이 프로필 파일 형식은 지원하지 않습니다. AutoApprove 버전을 확인해주세요.")}
        guard !result.name.isEmpty, result.name.count <= 80, !result.name.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains),
              savedAt.timeIntervalSince1970.isFinite, (1...128).contains(entries.count) else {
            throw AppError.message("프로필 이름은 1~80자, 세션은 1~128개로 저장해주세요.")
        }
        result.entries=try entries.map {try $0.validated()}
        if let groups {
            guard groups.count<=200,Set(groups.map { $0.group.id }).count==groups.count else {throw AppError.message("프로필의 그룹 목록이 중복되거나 너무 많습니다.")}
            result.groups=try groups.map {try $0.validated(entries:result.entries)}
        }
        guard Set(result.entries.map(\.id)).count == entries.count,Set(result.entries.map(\.key)).count == entries.count else {
            throw AppError.message("같은 대화가 프로필에 두 번 포함되어 있습니다.")
        }
        let groups=Dictionary(grouping:result.entries.filter {$0.host == .terminal && $0.terminalTab != nil},by:{$0.terminalTab!.window})
        var orders=Set<Int>()
        for group in groups.values {
            let tabs=group.map {$0.terminalTab!}
            guard Set(tabs.map(\.windowOrder)).count==1,orders.insert(tabs[0].windowOrder).inserted,
                  Set(tabs.map(\.tabOrder)).count==tabs.count,tabs.filter(\.selected).count<=1 else {
                throw AppError.message("같은 Terminal 창의 탭 순서·선택 정보가 겹칩니다. 현재 창을 다시 불러와주세요.")
            }
        }
        return result
    }
    public var terminalLayoutSummary:String {
        let tabs=entries.filter {$0.host == .terminal}
        guard !tabs.isEmpty else {return ""}
        let groups=Set(tabs.map {$0.terminalTab?.window.uuidString ?? "legacy"})
        return "Terminal 창 \(groups.count)개 · 탭 \(tabs.count)개"
    }
}

public struct TerminalProfileListing {
    public var profiles: [TerminalSessionProfile]
    public var warnings: [String]
}

public struct TerminalProfileStore: Sendable {
    public let directory: URL
    public static let maximumBytes=512*1024
    public init(directory: URL) {self.directory=directory}
    public func file(_ id: UUID) -> URL {directory.appendingPathComponent(id.uuidString.lowercased()+".autoapprove-profile.json",isDirectory:false)}
    public func prepare() throws {
        var info=stat()
        if lstat(directory.path,&info)==0 {
            guard info.st_mode&S_IFMT == S_IFDIR,info.st_uid == getuid() else {throw AppError.message("프로필 폴더의 소유자와 경로를 확인해주세요.")}
        } else {
            guard errno == ENOENT else {throw POSIXError(.EACCES)}
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        }
    }
    public func list() throws -> TerminalProfileListing {
        try prepare()
        let files=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)
            .filter {$0.lastPathComponent.hasSuffix(".autoapprove-profile.json")}
        guard files.count <= 200 else {throw AppError.message("프로필은 최대 200개까지 관리합니다. 파일을 정리해주세요.")}
        var profiles:[TerminalSessionProfile]=[],warnings:[String]=[]
        for url in files {
            do {
                let value=try Self.decode(Self.read(url))
                guard file(value.id).lastPathComponent == url.lastPathComponent else {throw AppError.message("파일 이름과 프로필 ID가 다릅니다.")}
                profiles.append(value)
            } catch {warnings.append(url.lastPathComponent+": "+error.localizedDescription)}
        }
        return TerminalProfileListing(profiles:profiles.sorted {$0.savedAt == $1.savedAt ? $0.name < $1.name : $0.savedAt > $1.savedAt},warnings:warnings)
    }
    @discardableResult public func save(_ profile: TerminalSessionProfile) throws -> TerminalSessionProfile {
        try prepare(); let value=try profile.validated(),target=file(value.id)
        var info=stat()
        if lstat(target.path,&info)==0 {
            guard info.st_mode&S_IFMT == S_IFREG,info.st_uid == getuid() else {throw AppError.message("이 프로필 파일에 저장할 수 없습니다.")}
        } else {
            guard errno == ENOENT else {throw POSIXError(.EACCES)}
            let listing=try list()
            guard listing.profiles.count+listing.warnings.count < 200 else {throw AppError.message("프로필은 최대 200개까지 저장합니다.")}
        }
        try Self.write(try Self.encode(value),to:target);return value
    }
    @discardableResult public func importFile(_ source: URL) throws -> TerminalSessionProfile {
        var value=try Self.decode(Self.read(source));value.id=UUID();value.savedAt=Date();return try save(value)
    }
    public static func encode(_ value: TerminalSessionProfile) throws -> Data {
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601;encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        let data=try encoder.encode(value.validated());guard data.count <= maximumBytes else {throw AppError.message("프로필 파일이 너무 큽니다.")};return data
    }
    public static func decode(_ data: Data) throws -> TerminalSessionProfile {
        guard data.count <= maximumBytes else {throw AppError.message("프로필 파일은 512KB 이하여야 합니다.")}
        let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        do {return try decoder.decode(TerminalSessionProfile.self,from:data).validated()}
        catch let error as AppError {throw error}
        catch {throw AppError.message("프로필 JSON 파일을 읽지 못했습니다. 파일 형식을 확인해주세요.")}
    }
    public static func read(_ url: URL) throws -> Data {
        let fd=open(url.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK)
        guard fd>=0 else {throw AppError.message("프로필 파일을 열지 못했습니다. 일반 JSON 파일을 선택해주세요.")}
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true);defer {try? handle.close()}
        var info=stat();guard fstat(fd,&info)==0,info.st_mode&S_IFMT == S_IFREG,info.st_size>=0,info.st_size<=maximumBytes else {throw AppError.message("프로필 파일은 512KB 이하의 일반 JSON 파일이어야 합니다.")}
        let data=try handle.read(upToCount:maximumBytes+1) ?? Data();guard data.count<=maximumBytes else {throw AppError.message("프로필 파일이 너무 큽니다.")};return data
    }
    public static func write(_ data: Data,to url: URL) throws {
        let temporary=url.deletingLastPathComponent().appendingPathComponent(".profile-"+UUID().uuidString)
        let fd=open(temporary.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
        guard fd>=0 else {throw AppError.message("프로필 파일을 저장할 수 없습니다. 폴더 접근 권한을 확인해주세요.")}
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        defer {try? handle.close();try? FileManager.default.removeItem(at:temporary)}
        try handle.write(contentsOf:data)
        guard fsync(fd)==0,rename(temporary.path,url.path)==0 else {throw AppError.message("프로필 저장을 완료하지 못했습니다. 기존 파일은 유지됩니다.")}
    }
}

public struct TerminalProfileCandidate: Identifiable, Sendable {
    public var id: String
    public var entry: TerminalProfileEntry
    public var conversations: [CodexProfileConversation]
    public var detail: String?
    public var canQueryConversation: Bool
    public var tty:String?
    public init(id: String,entry: TerminalProfileEntry,conversations: [CodexProfileConversation] = [],detail: String? = nil,tty:String?=nil, canQueryConversation: Bool = false) {
        self.canQueryConversation = canQueryConversation
        self.id=id;self.entry=entry;self.conversations=conversations;self.detail=detail;self.tty=tty
    }
}
public struct CodexProfileConversation: Identifiable, Sendable {
    public var id: String
    public var title: String
    public init(id:String,title:String) {self.id=id;self.title=title}
}

public enum CodexProfileConversationBinding {
    public static func terminalName(_ title:String?,cwd:String)->String? {
        guard var title=title?.precomposedStringWithCanonicalMapping.trimmingCharacters(in:.whitespacesAndNewlines),
              !title.isEmpty,title.utf8.count<=16_384 else {return nil}
        if let first=title.unicodeScalars.first,(0x2800...0x28ff).contains(first.value),title.dropFirst().first==" " {
            title=String(title.dropFirst(2))
        }
        for attention in ["[ . ] Action Required | ","[ ! ] Action Required | "] where title.hasPrefix(attention) {
            title=String(title.dropFirst(attention.count));break
        }
        let suffix=" | "+URL(fileURLWithPath:cwd).lastPathComponent.precomposedStringWithCanonicalMapping
        guard title.hasSuffix(suffix) else {return nil}
        let name=String(title.dropLast(suffix.count))
        guard !name.isEmpty,!name.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else {return nil}
        return name
    }
    public static func match(title:String?,cwd:String,conversations:[CodexQueueConversation])->CodexQueueConversation? {
        guard let name=terminalName(title,cwd:cwd) else {return nil}
        let matches=conversations.filter {
            UUID(uuidString:$0.id) != nil && $0.name?.precomposedStringWithCanonicalMapping==name
        }
        return matches.count==1 ? matches[0]:nil
    }
}

public struct TerminalProfileRestoreResult: Identifiable, Sendable {
    public enum Phase: String, Sendable {case opened,alreadyOpen,needsReview,failed}
    public var id: UUID
    public var phase: Phase
    public var detail: String
    public var tty: String?
    public init(id:UUID,phase:Phase,detail:String,tty:String?=nil) {self.id=id;self.phase=phase;self.detail=detail;self.tty=tty}
}

@MainActor public final class TerminalProfileRestorer {
    public private(set) var busy=false
    private struct Receipt {
        var tty:String?
        var failure:String?
        var terminal:TerminalProcessIdentity?
    }
    private var dispatched:[String:Receipt]=[:]
    private let terminalProcess: @Sendable () async -> TerminalProcessIdentity?
    public init(terminalProcess: @escaping @Sendable () async -> TerminalProcessIdentity? = {
        await Task.detached(priority:.userInitiated) { try? TerminalProcessLookup.running() }.value
    }) { self.terminalProcess = terminalProcess }

    public func restore(_ profile: TerminalSessionProfile,selected: Set<UUID>,active: [TerminalProfileEntry],
                        activeTerminalTTYs:[String:String]=[:],
                        directoryExists: @Sendable (String)->Bool = {var directory:ObjCBool=false;return FileManager.default.fileExists(atPath:$0,isDirectory:&directory)&&directory.boolValue},
                        terminalIsOpen: (@Sendable (String) async throws -> Bool)? = nil,
                        openTerminalTTYs: @Sendable () async throws -> Set<String> = {
                            try await Task.detached(priority:.userInitiated) { Set(try ProcessDiscovery.read().map { "/dev/" + $0.tty }) }.value
                        },
                        launch: @Sendable (TerminalProfileEntry,String?) async throws -> String,
                        placeWindow: @Sendable (String, TerminalWindowBounds) async throws -> Void = { try await TerminalProfileLauncher.placeWindow(tty:$0,bounds:$1) },
                        selectTab:@Sendable (String,String) async throws -> Void = {_,_ in},
                        progress: @MainActor (TerminalProfileRestoreResult)->Void = {_ in}) async throws -> [TerminalProfileRestoreResult] {
        guard !busy else {throw AppError.message("이미 프로필을 복원하고 있습니다.")}
        let profile=try profile.validated();guard !selected.isEmpty,selected.isSubset(of:Set(profile.entries.map(\.id))) else {throw AppError.message("복원할 세션을 선택해주세요.")}
        busy=true;defer {busy=false};var results:[TerminalProfileRestoreResult]=[]
        func group(_ entry:TerminalProfileEntry)->String? {entry.host == .terminal ? entry.terminalTab?.window.uuidString ?? "legacy":nil}
        let entries=profile.entries.enumerated().sorted {a,b in
            let left=(a.element.host == .terminal ? 0:1,a.element.terminalTab?.windowOrder ?? 512,a.element.terminalTab?.tabOrder ?? a.offset)
            let right=(b.element.host == .terminal ? 0:1,b.element.terminalTab?.windowOrder ?? 512,b.element.terminalTab?.tabOrder ?? b.offset)
            return left==right ? a.offset<b.offset:left<right
        }.map(\.element)
        var terminal = entries.contains(where: { $0.host == .terminal }) ? await terminalProcess() : nil
        let activeKeys=Set(active.map(\.key))
        let activeByTTY = Dictionary(grouping:active.filter { $0.host == .terminal && $0.resumesConversation && activeTerminalTTYs[$0.key] != nil },
                                     by:{ activeTerminalTTYs[$0.key]! })
        var anchors:[String:String]=[:],knownTTYs:[String:String]=[:],openedGroups=Set<String>()
        var unresolvedGroups=Set<String>(),unconfirmedTabs=Set<String>()
        var checkedTTYs: Set<String>?
        var readTTYs = false
        for entry in entries {
            if let tty=activeTerminalTTYs[entry.key],activeKeys.contains(entry.key),TerminalProfileLauncher.validTTY(tty) {
                knownTTYs[entry.key]=tty
                if let key=group(entry),anchors[key]==nil {anchors[key]=tty}
                continue
            }
            if activeKeys.contains(entry.key),let key=group(entry) {unresolvedGroups.insert(key)}
            if let receipt=dispatched[entry.key] {
                if let tty=receipt.tty {
                    if entry.host == .terminal {
                        let restarted = receipt.terminal.map { old in terminal.map { $0 != old } ?? false } ?? false
                        let reused = entry.resumesConversation && activeByTTY[tty]?.contains(where: { $0.key != entry.key }) == true
                        if restarted || reused {dispatched.removeValue(forKey:entry.key);continue}
                    }
                    let open: Bool?
                    if let terminalIsOpen { open = try? await terminalIsOpen(tty) }
                    else {
                        if !readTTYs { checkedTTYs = try? await openTerminalTTYs(); readTTYs = true }
                        open = checkedTTYs?.contains(tty)
                    }
                    if open==false {dispatched.removeValue(forKey:entry.key)}
                    else if open==true {
                        knownTTYs[entry.key]=tty
                        if let key=group(entry),anchors[key]==nil {anchors[key]=tty}
                    } else if open==nil,let key=group(entry) {unresolvedGroups.insert(key)}
                } else if let key=group(entry) {unresolvedGroups.insert(key)}
            }
        }
        let existingGroups = Set(anchors.keys).union(unresolvedGroups)
        func finishGroup(_ key:String) async {
            guard openedGroups.contains(key),!existingGroups.contains(key),!Task.isCancelled,let lastOpened=anchors[key] else {return}
            let candidates=entries.filter {selected.contains($0.id) && group($0)==key && knownTTYs[$0.key] != nil}
            guard let target=candidates.first(where:{$0.terminalTab?.selected == true}) ?? candidates.first,
                  let tty=knownTTYs[target.key],tty != lastOpened else {return}
            do {try await selectTab(tty,lastOpened)}
            catch {
                if let index=results.firstIndex(where: {result in result.phase == .opened && entries.contains(where:{$0.id==result.id && group($0)==key})}) {
                    results[index].detail += " 선택 탭 복원은 확인하지 못했습니다: "+error.localizedDescription;progress(results[index])
                }
            }
        }
        let batch = CodexProfileLaunchBatch()
        let selectedEntries=entries.filter {selected.contains($0.id)}
        for (position,entry) in selectedEntries.enumerated() {
            let key=group(entry)
            let result:TerminalProfileRestoreResult
            if !activeKeys.contains(entry.key),let receipt=dispatched[entry.key],receipt.tty == nil {
                result = .init(id:entry.id,phase:.needsReview,detail:"이전 복원 결과를 확인하지 못했습니다. 같은 항목을 다시 열기 전에 터미널을 확인해주세요."+(receipt.failure.map {" 원인: "+$0} ?? ""))
            } else if activeKeys.contains(entry.key) || dispatched[entry.key] != nil {
                result = .init(id:entry.id,phase:.alreadyOpen,detail:"이미 열려 있거나 복원 명령을 전달한 세션입니다.",tty:knownTTYs[entry.key])
            } else if entry.resumesConversation && active.contains(where:{$0.agent == entry.agent && $0.cwd == entry.cwd && $0.providerHome == entry.providerHome && UUID(uuidString:$0.conversationID)==nil}) {
                result = .init(id:entry.id,phase:.needsReview,detail:"같은 폴더의 CLI가 실행 중입니다. 원래 대화를 확인한 뒤 복원해주세요.")
            } else if !directoryExists(entry.cwd) {
                result = .init(id:entry.id,phase:.failed,detail:"작업 폴더가 없습니다. 프로필의 폴더 경로를 확인해주세요.")
            } else if Task.isCancelled {
                result = .init(id:entry.id,phase:.needsReview,detail:"복원이 중단되었습니다. 이 항목은 실행하지 않았습니다.")
            } else if let key,unconfirmedTabs.contains(key) || (anchors[key]==nil && unresolvedGroups.contains(key)) {
                result = .init(id:entry.id,phase:.needsReview,detail:"같은 창의 이전 복원 위치를 확인하지 못해 이 탭은 열지 않았습니다. 원래 Terminal 창을 확인해주세요.")
            } else {
                dispatched[entry.key]=Receipt(tty:nil)
                do {
                    let anchor = key.flatMap {anchors[$0]}
                    let tty=try await CodexProfileLaunchBatch.$current.withValue(batch) { try await launch(entry,anchor) }
                    if entry.host == .terminal, terminal == nil {terminal = await terminalProcess()}
                    dispatched[entry.key]=Receipt(tty:tty,terminal:entry.host == .terminal ? terminal:nil)
                    knownTTYs[entry.key]=tty
                    if let key {anchors[key]=tty;openedGroups.insert(key)}
                    let detail=entry.resumesConversation ? (entry.host == .terminal ? "Terminal에 대화 이어하기 명령을 전달했습니다.":"새 터미널에 저장한 대화의 이어하기 명령을 전달했습니다."):"저장한 폴더에서 새 CLI 실행 명령을 전달했습니다."
                    var placementDetail = ""
                    if anchor == nil, entry.host == .terminal, let bounds = entry.terminalTab?.bounds {
                        do { try await placeWindow(tty,bounds) }
                        catch { placementDetail = " 창 위치 복원 실패 · " + error.localizedDescription }
                    }
                    result = .init(id:entry.id,phase:.opened,detail:detail+placementDetail,tty:tty)
                }
                catch {
                    let diagnostics=(error as? RemoteHTTPError)?.diagnostics
                    let notStarted=diagnostics?["delivery"] == "not_started" || diagnostics?["command_delivery"] == "not_started"
                    if notStarted {dispatched.removeValue(forKey:entry.key)}
                    else {dispatched[entry.key]?.failure=error.localizedDescription}
                    if let key {
                        if !notStarted {unresolvedGroups.insert(key)}
                        if diagnostics?["tab_creation"] == "unknown" {unconfirmedTabs.insert(key)}
                    }
                    let detail=notStarted ? error.localizedDescription+(diagnostics?["tab_creation"] == "unknown" ? " 대화 명령은 보내지 않았습니다. 빈 탭이 생겼을 수 있으니 확인한 뒤 다시 시도해주세요.":"") : "복원 결과를 확인하지 못했습니다. 중복 실행 전에 터미널을 확인해주세요. "+error.localizedDescription
                    result = .init(id:entry.id,phase:notStarted ? .failed:.needsReview,detail:detail)
                }
            }
            results.append(result);progress(result)
            if let key,position+1==selectedEntries.count || group(selectedEntries[position+1]) != key {
                await finishGroup(key)
            }
        }
        return results
    }
}

public enum TerminalProfileLauncher {
    public static func validTTY(_ tty:String)->Bool {tty.range(of:#"^/dev/ttys[0-9]+$"#,options:.regularExpression) != nil}
    public static func script(_ entry: TerminalProfileEntry,targetTTY:String?=nil,nativeRuntimeRoot:String?=nil) throws -> String {
        try script(entry,targetTTY:targetTTY,command:entry.resumeCommand(nativeRuntimeRoot:nativeRuntimeRoot))
    }
    static func script(_ entry:TerminalProfileEntry,targetTTY:String?,command rawCommand:String,commandFile:TerminalProfileCommandFile? = nil) throws ->String {
        let command=try AutomationScript.literal(rawCommand)
        if entry.host == .iterm {
            return """
            (()=>{
              const app=Application('com.googlecode.iterm2');
              if(app.running() && app.frontmost() && app.windows().length)
                return JSON.stringify({error:'iTerm2에서 작업 중입니다. 다른 앱으로 이동한 뒤 새 창 복원을 다시 시도해주세요.',commandAttempted:false});
              const window=app.createWindowWithDefaultProfile({command:\(command)});
              return JSON.stringify({tty:window.currentSession().tty()});
            })();
            """

        }
        let target=try AutomationScript.literal(targetTTY as Any? ?? NSNull()),settings=try AutomationScript.literal(entry.terminalTab?.settingsName as Any? ?? NSNull()),title=try AutomationScript.literal(entry.terminalTab?.customTitle as Any? ?? NSNull())
        if let commandFile {
            let path=try AutomationScript.literal(HookInstaller.quote(commandFile.url.path))
            return """
            (()=>{
              ObjC.import('Foundation');
              const app=Application('com.apple.Terminal'),target=\(target),settings=\(settings),title=\(title);
              \(AutomationScript.terminalSelectionGuard)
              let commandAttempted=false,created=false;
              try {
                const profile=settings===null ? null:app.settingsSets.byName(settings);
                if(profile!==null&&!profile.exists())throw Error('저장한 Terminal 설정 프로필이 없습니다.');
                \(TerminalProfileScriptQueries.inventory)
                let tty=target;
                if(tty===null){
                  const before=new Set(inventory().map(row=>row.tty));
                  if(before.size && app.frontmost())throw Error('Terminal에서 작업 중입니다. 다른 앱으로 이동한 뒤 새 창 복원을 다시 시도해주세요.');
                  created=true;
                  tty=app.doScript('').tty();
                  if(!tty||before.has(tty))throw Error('새 Terminal 창의 탭을 확인하지 못했습니다.');
                }
                const row=inventory().find(row=>row.tty===tty);
                if(!row)throw Error('복원할 Terminal 탭이 닫혔습니다.');
                const {tab}=exactTab(row),deadline=Date.now()+8000;
                let shell;
                do {
                  const jobs=tab.processes().map(p=>String(p).trim().split(/\\s+/)[0].split('/').pop().replace(/^-/,'')).filter(p=>p!=='login');
                  if(jobs.length===1 && /^(zsh|bash|sh|fish|tcsh|csh|dash|ksh)$/.test(jobs[0]) && !tab.busy()){
                    shell=jobs[0];break;
                  }
                  $.NSThread.sleepForTimeInterval(0.05);
                }while(Date.now()<deadline);
                if(!shell)throw Error('복원할 탭의 빈 셸을 확인하지 못했습니다.');
                if(profile!==null && tab.currentSettings().name()!==settings)tab.currentSettings=profile;
                if(title!==null && tab.customTitle()!==title)tab.customTitle=title;
                if(tab.tty()!==tty||tab.busy())throw Error('복원할 탭이 바뀌었습니다.');
                if(!preservesSelection(tty))throw Error('다른 Terminal 탭을 사용 중입니다. 대상 탭의 명령 전송을 보류했습니다.');
                commandAttempted=true;
                app.doScript((['fish','tcsh','csh'].includes(shell)?'/bin/sh ':'. ')+\(path),{in:tab});
                return JSON.stringify({tty});
              }catch(error){return JSON.stringify({error:String(error.message||error),commandAttempted,created});}
            })();
            """
        }
        return """
        (()=>{
          const app=Application('com.apple.Terminal'),target=\(target),settings=\(settings),title=\(title);
          \(AutomationScript.terminalSelectionGuard)
          let stage='Terminal 연결 준비',commandAttempted=false;
          try {
          const profile=settings===null ? null:app.settingsSets.byName(settings);
          if(profile!==null && !profile.exists())throw Error('저장한 Terminal 설정 프로필이 없습니다: '+settings);
          \(TerminalProfileScriptQueries.matchingTab)
          let tab;
          if(target!==null){
            stage='복원 대상 탭 연결 확인';tab=matchingTab(target);
            const processes=tab.processes();
            if(tab.busy() || !processes.length || !processes.every(p=>/^(?:-?(?:zsh|bash|sh|fish|tcsh|csh|dash|ksh)|login)$/.test(String(p).trim().split(/\\s+/)[0].split('/').pop())))throw Error('새 탭에서 다른 작업이 실행 중이어서 대화 명령을 보내지 않았습니다.');
            if(profile!==null)tab.currentSettings=profile;
            if(title!==null)tab.customTitle=title;
            if(!preservesSelection(target))throw Error('다른 Terminal 탭을 사용 중입니다. 대상 탭의 명령 전송을 보류했습니다.');
            stage='대화 명령 전달';commandAttempted=true;
            app.doScript(\(command),{in:tab});
          }else{
            if(app.running() && app.frontmost() && app.windows().length)throw Error('Terminal에서 작업 중입니다. 다른 앱으로 이동한 뒤 새 창 복원을 다시 시도해주세요.');
            stage='새 창에 대화 명령 전달';commandAttempted=true;
            tab=app.doScript(\(command));
            if(profile!==null)tab.currentSettings=profile;
            if(title!==null)tab.customTitle=title;
          }
          stage='복원된 터미널 확인';return JSON.stringify({tty:tab.tty()});
          }catch(error){return JSON.stringify({error:stage+': '+String(error.message||error),commandAttempted});}
        })();
        """
    }
    public static func launch(_ entry: TerminalProfileEntry,anchorTTY:String?=nil,
                              openTab:@escaping @Sendable (String,String?) throws -> String = {try TerminalProfileTabOpener.openForProfile(anchorTTY:$0,settingsName:$1)},
                              execute:(@Sendable (String,TerminalProfileEntry.Host) throws -> String)? = nil) async throws -> String {
        let entry=try entry.validated()
        let batch = CodexProfileLaunchBatch.current
        return try await Task.detached(priority:.userInitiated) {
            @Sendable func prepare() async throws -> CodexProfileLaunchRuntime {
                if let runtime = try CodexBundledRuntime.bundled() {
                    return try await CodexProfileLaunchRuntime.resolve(entry: entry, runtime: runtime, server: .local(executable: runtime.executable))
                }
                guard let candidate = try CodexCLIContext.resolve(home: entry.providerHome ?? NSHomeDirectory()+"/.codex", userHome: NSHomeDirectory(), executable: nil) else {
                    throw AppError.message("공식 Codex CLI를 찾지 못했습니다. Codex를 설치한 뒤 다시 복원해주세요.")
                }
                let cli = try CodexOfficialExecutable.context(candidate)
                return try await CodexProfileLaunchRuntime.resolveInstalled(entry: entry, cli: cli, server: .local(executable: cli.executable))
            }
            let launchRuntime:CodexProfileLaunchRuntime?
            do {
                if entry.agent != "codex" { launchRuntime = nil }
                else if let batch { launchRuntime = try await batch.runtime(for: entry, prepare: prepare) }
                else { launchRuntime = try await prepare() }
            } catch {
                throw RemoteHTTPError(409,error.localizedDescription,diagnostics:["delivery":"not_started"])
            }
            let command:String, file:TerminalProfileCommandFile?
            do {
                let refreshed = TerminalProfileExecutionSettingsReader.refreshed([entry])[0]
                command=try refreshed.resumeCommand(nativeRuntimeRoot:nil,bundledRuntime:launchRuntime?.bundled,compatibleCLI:launchRuntime?.installed,standalone:launchRuntime?.standalone ?? false)
                file=entry.host == .terminal ? try TerminalProfileCommandFile(command:command):nil
            } catch { throw RemoteHTTPError(409,error.localizedDescription,diagnostics:["command_delivery":"not_started"]) }
            defer { file?.withdraw() }
            @Sendable func deliver() throws -> String {
                var targetTTY:String?
                if entry.host == .terminal,let anchorTTY {
                    targetTTY=try openTab(anchorTTY,entry.terminalTab?.settingsName)
                }
                let body=try script(entry,targetTTY:targetTTY,command:file == nil ? command:"",commandFile:file)
                do {
                    try launchRuntime?.verifyUnchanged()
                    let text:String
                    do {
                        if let execute {text=try execute(body,entry.host)}
                        else {text=try AutomationScript.run(body,app:entry.host == .iterm ? "iTerm2":"Terminal",denied:entry.host == .iterm ? .automationDenied("iTerm2"):.permissionDenied,timeout:entry.host == .terminal ? 12:8)}
                    }
                    catch let error as TerminalAdapterError {
                        throw RemoteHTTPError(403,error.localizedDescription,diagnostics:entry.host == .iterm ? ["delivery":"not_started"]:nil)
                    }
                    guard let object=try JSONSerialization.jsonObject(with:Data(text.utf8)) as? JSONObject else {throw AppError.message("복원한 터미널을 확인하지 못했습니다.")}
                    if let failure=object["error"] as? String {
                        var diagnostics:[String:String]=[:]
                        if object["commandAttempted"] as? Bool == false {diagnostics["command_delivery"]="not_started"}
                        if object["created"] as? Bool == true {diagnostics["tab_creation"]="unknown"}
                        throw RemoteHTTPError(409,failure,diagnostics:diagnostics)
                    }
                    guard let tty=object["tty"] as? String,validTTY(tty) else {throw AppError.message("복원한 터미널을 확인하지 못했습니다.")}
                    return tty
                } catch {
                    if let file, file.withdraw() {
                        var diagnostics=(error as? RemoteHTTPError)?.diagnostics ?? [:]
                        diagnostics["command_delivery"]="not_started"
                        if targetTTY != nil {diagnostics["tab_creation"]="unknown"}
                        throw RemoteHTTPError(409,error.localizedDescription,diagnostics:diagnostics)
                    }
                    throw error
                }
            }
            let host = entry.host == .iterm ? "iTerm2" : "Terminal"
            let tty: String
            do {
                tty = try AutomationIPC.shared.runInput(host: host, budget: 24, admissionWait: 5, body: deliver)
            } catch let error as AutomationIPC.InputNotStarted {
                throw RemoteHTTPError(409,error.localizedDescription,diagnostics:["delivery":"not_started"])
            }
            do {
                try file?.waitForShell()
            } catch {
                var diagnostics = ["tab_creation": "unknown"]
                if file?.withdraw() == true { diagnostics["command_delivery"] = "not_started" }
                throw RemoteHTTPError(409,error.localizedDescription,diagnostics:diagnostics)
            }
            return tty
        }.value
    }
    public static func placeWindow(tty:String,bounds:TerminalWindowBounds) async throws {
        guard validTTY(tty) else {throw AppError.message("창 위치를 적용할 탭을 확인하지 못했습니다.")}
        try await Task.detached(priority:.userInitiated) {
            guard let frame=TerminalProfileWindowPlacement.fit(bounds,displays:TerminalProfileWindowPlacement.displays()) else {
                throw AppError.message("창을 배치할 화면을 확인하지 못했습니다.")
            }
            let target=try AutomationScript.literal(tty)
            let placement=try AutomationScript.literal(["x":frame.minX,"y":frame.minY,"width":frame.width,"height":frame.height])
            let script="""
            (()=>{
              const app=Application('com.apple.Terminal');
              if(!app.running())throw Error('Terminal 창이 닫혔습니다.');
              \(TerminalProfileScriptQueries.inventory)
              const row=inventory().find(item=>item.tty===\(target));
              if(!row)throw Error('복원한 Terminal 탭이 닫혔습니다.');
              const {window}=exactTab(row);
              if(window.selectedTab().tty()!==row.tty)throw Error('복원한 Terminal 창의 선택이 바뀌었습니다.');
              window.bounds=\(placement);
              return 'placed';
            })();
            """
            _ = try AutomationIPC.shared.run(host:"Terminal",readOnly:false,budget:5,admissionWait:3) {
                try AutomationScript.run(script,app:"Terminal",denied:.permissionDenied,timeout:5)
            }
        }.value
    }

    public static func selectTab(_ tty:String, afterOpening lastTTY:String) async throws {
        guard validTTY(tty),validTTY(lastTTY),tty != lastTTY else {return}
        try await Task.detached(priority:.utility) {
            try AutomationIPC.shared.run(host:"Terminal",readOnly:false,budget:6,admissionWait:3) {
                guard let owner = try? TerminalProcessLookup.running(),
                      let last = try TerminalAppleEvents.profileWindowMetadata(tty:lastTTY,owner:owner),
                      !last.minimized,last.selected else {return}
                let reader = try TerminalNativeTabReader.terminal(owner:owner)
                let rows = try TerminalProfileTopology.readRows([tty,lastTTY],timeout:3)
                guard let target = rows.first(where:{$0.tty == tty}),let previous = rows.first(where:{$0.tty == lastTTY}),
                      previous.windowID == last.windowID,previous.selected else {return}
                if previous.windowID == target.windowID {
                    let script = try selectionScript(tty,afterOpening:lastTTY)
                    _ = try AutomationScript.run(script,app:"Terminal",denied:.permissionDenied,timeout:3)
                } else {
                    try reader.selectRestoredTab(row:target,afterOpening:last.windowID)
                }
            }
        }.value
    }
    public static func selectionScript(_ tty:String,afterOpening lastTTY:String? = nil) throws -> String {
        guard validTTY(tty) else {throw AppError.message("선택할 Terminal 탭을 확인하지 못했습니다.")}
        let target=try AutomationScript.literal(tty)
        let selection:String
        if let lastTTY {
            guard validTTY(lastTTY) else {throw AppError.message("복원한 탭을 확인하지 못했습니다.")}
            let previous=try AutomationScript.literal(lastTTY)
            selection="""
              if(window.miniaturized() || window.selectedTab().tty()!==\(previous) || app.frontmost())return 'user selection preserved';
              window.selectedTab=tab;
            """
        } else {selection="window.miniaturized=false;window.selectedTab=tab;window.index=1;app.activate();"}
        return """
        (()=>{
          const app=Application('com.apple.Terminal');
          \(TerminalProfileScriptQueries.inventory)
          const row=inventory().find(row=>row.tty===\(target));
          if(!row)throw Error('선택할 탭이 닫혔거나 바뀌었습니다.');
          const {window,tab}=exactTab(row);
          \(selection)
          return 'selected';
        })();
        """
    }
}
