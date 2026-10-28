import Foundation
import Darwin

public struct TerminalProfileTabLayout: Codable, Equatable, Sendable {
    public var window:UUID
    public var windowOrder:Int
    public var tabOrder:Int
    public var selected:Bool
    public var settingsName:String?
    public var customTitle:String?
    public init(window:UUID,windowOrder:Int,tabOrder:Int,selected:Bool=false,settingsName:String?=nil,customTitle:String?=nil) {
        self.window=window;self.windowOrder=windowOrder;self.tabOrder=tabOrder;self.selected=selected;self.settingsName=settingsName;self.customTitle=customTitle
    }
    public func validated() throws -> Self {
        guard (0..<512).contains(windowOrder),(0..<4096).contains(tabOrder),
              [settingsName,customTitle].allSatisfy({value in value.map {$0.count<=256 && !$0.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains)} ?? true}),
              settingsName.map({!$0.isEmpty}) ?? true else {throw AppError.message("Terminal의 창·탭 순서와 설정 프로필을 확인해주세요.")}
        return self
    }
    public var label:String {"창 \(windowOrder+1) · 탭 \(tabOrder+1)"+(selected ? " · 선택 탭":"")}
}

/// A resumable conversation, never a saved shell command, transcript or credential.
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
    public init(id: UUID = UUID(), title: String, agent: String, cwd: String, conversationID: String,
                providerHome: String? = nil, host: Host = .terminal,terminalTab:TerminalProfileTabLayout?=nil) {
        self.id=id; self.title=title; self.agent=agent; self.cwd=cwd; self.conversationID=conversationID
        self.providerHome=providerHome; self.host=host;self.terminalTab=terminalTab
    }
    public var key: String { agent+"\n"+(providerHome ?? "")+"\n"+conversationID.lowercased() }
    public var terminalTabSummary:String {
        guard host == .terminal else {return ""}
        return (terminalTab?.label ?? "한 창의 탭으로 복원")+(terminalTab?.settingsName.map {" · 설정: "+$0} ?? "")
    }
    public func validated() throws -> Self {
        guard ["codex","claude"].contains(agent), UUID(uuidString:conversationID) != nil,
              Self.path(cwd), providerHome.map(Self.path) ?? true,
              title.count <= 256, !title.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else {
            throw AppError.message("프로필의 CLI 종류·폴더·대화 ID를 확인해주세요.")
        }
        var copy=self; copy.conversationID=UUID(uuidString:conversationID)!.uuidString.lowercased();copy.terminalTab=try terminalTab?.validated();return copy
    }
    private static func path(_ value: String) -> Bool {
        value.hasPrefix("/") && value.utf8.count <= 4096 && !value.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains)
    }
    /// Fixed CLI grammar, with every user value quoted. No prompt or approval flag is replayed.
    public func resumeCommand() throws -> String {
        let entry=try validated()
        var arguments=["env"]
        if let home=entry.providerHome {arguments.append((agent == "codex" ? "CODEX_HOME":"CLAUDE_CONFIG_DIR")+"="+home)}
        arguments += [agent,agent == "codex" ? "resume":"--resume",entry.conversationID]
        return "cd -- "+HookInstaller.quote(entry.cwd)+" && exec "+arguments.map(HookInstaller.quote).joined(separator:" ")
    }
}

public struct TerminalSessionProfile: Codable, Equatable, Identifiable, Sendable {
    public var schema: Int = 2
    public var id: UUID
    public var name: String
    public var savedAt: Date
    public var entries: [TerminalProfileEntry]
    public init(id: UUID = UUID(), name: String, savedAt: Date = Date(), entries: [TerminalProfileEntry]) {
        self.id=id;self.name=name;self.savedAt=savedAt;self.entries=entries
    }
    public func validated() throws -> Self {
        var result=self; result.name=name.trimmingCharacters(in:.whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard (1...2).contains(schema),schema == 2 || entries.allSatisfy({$0.terminalTab==nil}) else {throw AppError.message("이 프로필 파일 형식은 지원하지 않습니다. AutoApprove 버전을 확인해주세요.")}
        guard !result.name.isEmpty, result.name.count <= 80, !result.name.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains),
              savedAt.timeIntervalSince1970.isFinite, (1...128).contains(entries.count) else {
            throw AppError.message("프로필 이름은 1~80자, 세션은 1~128개로 저장해주세요.")
        }
        result.entries=try entries.map {try $0.validated()}
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

/// Named snapshots change only on explicit save/import. Opening an empty app cannot erase them.
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
    /// Live-only anchor; never encoded in a profile file.
    public var tty:String?
    public init(id: String,entry: TerminalProfileEntry,conversations: [CodexProfileConversation] = [],detail: String? = nil,tty:String?=nil) {
        self.id=id;self.entry=entry;self.conversations=conversations;self.detail=detail;self.tty=tty
    }
}
public struct CodexProfileConversation: Identifiable, Sendable {
    public var id: String
    public var title: String
    public init(id:String,title:String) {self.id=id;self.title=title}
}

public struct TerminalProfileRestoreResult: Identifiable, Sendable {
    public enum Phase: String, Sendable {case opened,alreadyOpen,needsReview,failed}
    public var id: UUID
    public var phase: Phase
    public var detail: String
}

@MainActor public final class TerminalProfileRestorer {
    public private(set) var busy=false
    // nil TTY means an ambiguous write: it cannot be replayed automatically.
    private struct Receipt {var tty:String?}
    private var dispatched:[String:Receipt]=[:]
    public init() {}
    public func restore(_ profile: TerminalSessionProfile,selected: Set<UUID>,active: [TerminalProfileEntry],
                        activeTerminalTTYs:[String:String]=[:],
                        directoryExists: @Sendable (String)->Bool = {var directory:ObjCBool=false;return FileManager.default.fileExists(atPath:$0,isDirectory:&directory)&&directory.boolValue},
                        terminalIsOpen: @Sendable (String) async throws -> Bool = {tty in
                            try await Task.detached(priority:.utility) {try ProcessDiscovery.read().contains {"/dev/"+$0.tty == tty}}.value
                        },
                        launch: @Sendable (TerminalProfileEntry,String?) async throws -> String,
                        selectTab:@Sendable (String) async throws -> Void = {_ in},
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
        let activeKeys=Set(active.map(\.key))
        var anchors:[String:String]=[:],knownTTYs:[String:String]=[:],blocked=Set<String>(),openedGroups=Set<String>()
        // Reuse only the exact saved conversation's verified current Terminal.
        // A receipt that cannot be resolved blocks its group, including later retries.
        for entry in entries {
            if let tty=activeTerminalTTYs[entry.key],activeKeys.contains(entry.key),TerminalProfileLauncher.validTTY(tty) {
                knownTTYs[entry.key]=tty
                if let key=group(entry),anchors[key]==nil {anchors[key]=tty}
                continue
            }
            if let receipt=dispatched[entry.key] {
                if let tty=receipt.tty {
                    let open=try? await terminalIsOpen(tty)
                    if open==false {dispatched.removeValue(forKey:entry.key)}
                    else if open==true {
                        knownTTYs[entry.key]=tty
                        if let key=group(entry),anchors[key]==nil {anchors[key]=tty}
                    } else if let key=group(entry) {blocked.insert(key)}
                } else if !activeKeys.contains(entry.key),let key=group(entry) {blocked.insert(key)}
            }
        }
        for entry in entries where activeKeys.contains(entry.key) {
            if let key=group(entry),anchors[key]==nil {blocked.insert(key)}
        }
        for entry in entries where selected.contains(entry.id) {
            let key=group(entry)
            let result:TerminalProfileRestoreResult
            if !active.contains(where:{$0.key == entry.key}),let receipt=dispatched[entry.key],receipt.tty == nil {
                result = .init(id:entry.id,phase:.needsReview,detail:"이전 복원 결과를 확인하지 못했습니다. 같은 대화를 다시 열기 전에 터미널을 확인해주세요.")
            } else if active.contains(where:{$0.key == entry.key}) || dispatched[entry.key] != nil {
                result = .init(id:entry.id,phase:.alreadyOpen,detail:"이미 열려 있거나 복원 명령을 전달한 세션입니다.")
            } else if key.map({blocked.contains($0)}) == true {
                result = .init(id:entry.id,phase:.needsReview,detail:"같은 창의 앞선 탭 복원을 확인하지 못했습니다. 창이 나뉘지 않도록 후속 탭을 열지 않았습니다. 터미널을 확인한 뒤 다시 시도해주세요.")
            } else if active.contains(where:{$0.agent == entry.agent && $0.cwd == entry.cwd && $0.providerHome == entry.providerHome && UUID(uuidString:$0.conversationID)==nil}) {
                result = .init(id:entry.id,phase:.needsReview,detail:"같은 폴더의 CLI가 실행 중입니다. 원래 대화를 확인한 뒤 복원해주세요.")
            } else if !directoryExists(entry.cwd) {
                result = .init(id:entry.id,phase:.failed,detail:"작업 폴더가 없습니다. 프로필의 폴더 경로를 확인해주세요.")
            } else if Task.isCancelled {
                result = .init(id:entry.id,phase:.needsReview,detail:"복원이 중단되었습니다. 이 항목은 실행하지 않았습니다.")
            } else {
                dispatched[entry.key]=Receipt(tty:nil)
                do {
                    let tty=try await launch(entry,key.flatMap {anchors[$0]});dispatched[entry.key]=Receipt(tty:tty);knownTTYs[entry.key]=tty
                    if let key {anchors[key]=tty;openedGroups.insert(key)}
                    result = .init(id:entry.id,phase:.opened,detail:entry.host == .terminal ? "저장한 창의 탭으로 대화 이어하기 명령을 전달했습니다.":"새 터미널에 저장한 대화의 이어하기 명령을 전달했습니다.")
                }
                catch {
                    let notStarted=(error as? RemoteHTTPError)?.diagnostics?["delivery"] == "not_started"
                    if notStarted {dispatched.removeValue(forKey:entry.key)}
                    if let key {blocked.insert(key)}
                    result = .init(id:entry.id,phase:notStarted ? .failed:.needsReview,detail:notStarted ? error.localizedDescription:"복원 결과를 확인하지 못했습니다. 중복 실행 전에 터미널을 확인해주세요. "+error.localizedDescription)
                }
            }
            results.append(result);progress(result)
        }
        for key in openedGroups where !Task.isCancelled {
            let candidates=entries.filter {group($0)==key && knownTTYs[$0.key] != nil}
            guard let target=candidates.first(where:{$0.terminalTab?.selected == true}) ?? candidates.first,
                  let tty=knownTTYs[target.key] else {continue}
            do {try await selectTab(tty)}
            catch {
                if let index=results.firstIndex(where: {result in result.phase == .opened && entries.contains(where:{$0.id==result.id && group($0)==key})}) {
                    results[index].detail += " 선택 탭 복원은 확인하지 못했습니다: "+error.localizedDescription;progress(results[index])
                }
            }
        }
        return results
    }
}

public enum TerminalProfileLauncher {
    public static func validTTY(_ tty:String)->Bool {tty.range(of:#"^/dev/ttys[0-9]+$"#,options:.regularExpression) != nil}
    public static func script(_ entry: TerminalProfileEntry,targetTTY:String?=nil) throws -> String {
        let entry=try entry.validated(),command=try AutomationScript.literal(entry.resumeCommand())
        if entry.host == .iterm {
            return "const app=Application('com.googlecode.iterm2'); app.activate(); const window=app.createWindowWithDefaultProfile({command:\(command)}); JSON.stringify({tty:window.currentSession().tty()});"
        }
        let target=try AutomationScript.literal(targetTTY as Any? ?? NSNull()),settings=try AutomationScript.literal(entry.terminalTab?.settingsName as Any? ?? NSNull()),title=try AutomationScript.literal(entry.terminalTab?.customTitle as Any? ?? NSNull())
        return """
        (()=>{
          const app=Application('com.apple.Terminal'),target=\(target),settings=\(settings),title=\(title);
          const profile=settings===null ? null:app.settingsSets.byName(settings);
          if(profile!==null && !profile.exists())throw Error('저장한 Terminal 설정 프로필이 없습니다: '+settings);
          let tab;
          if(target!==null){
            const matches=[];
            for(const window of app.windows())for(const item of window.tabs())if(item.tty()===target)matches.push(item);
            if(matches.length!==1)throw Error('새 Terminal 탭을 확인하지 못했습니다.');
            tab=matches[0];
            if(tab.busy() || !tab.processes().length || !tab.processes().every(p=>/^(?:-?(?:zsh|bash|sh|fish|tcsh|csh|dash|ksh)|login)$/.test(String(p).trim().split(/\\s+/)[0].split('/').pop())))throw Error('새 탭에서 다른 작업이 실행 중이어서 대화 명령을 보내지 않았습니다.');
            if(profile!==null)tab.currentSettings=profile;
            if(title!==null)tab.customTitle=title;
            app.doScript(\(command),{in:tab});
          }else{
            tab=app.doScript(\(command));
            if(profile!==null)tab.currentSettings=profile;
            if(title!==null)tab.customTitle=title;
          }
          app.activate();return JSON.stringify({tty:tab.tty()});
        })();
        """
    }
    public static func launch(_ entry: TerminalProfileEntry,anchorTTY:String?=nil) async throws -> String {
        let entry=try entry.validated()
        return try await Task.detached(priority:.userInitiated) {
            var targetTTY:String?
            if entry.host == .terminal,let settings=entry.terminalTab?.settingsName {
                let name=try AutomationScript.literal(settings)
                do {_ = try AutomationScript.run("const app=Application('com.apple.Terminal'); if(!app.settingsSets.byName(\(name)).exists())throw Error('저장한 Terminal 설정 프로필이 없습니다.'); 'ready';",app:"Terminal",denied:.permissionDenied)}
                catch {throw RemoteHTTPError(409,error.localizedDescription,diagnostics:["delivery":"not_started"])}
            }
            if entry.host == .terminal,let anchorTTY {
                targetTTY=try TerminalProfileTabOpener.open(anchorTTY:anchorTTY)
            }
            let body=try script(entry,targetTTY:targetTTY)
            let text:String
            do {text=try AutomationScript.run(body,app:entry.host == .iterm ? "iTerm2":"Terminal",denied:entry.host == .iterm ? .automationDenied("iTerm2"):.permissionDenied)}
            catch let error as TerminalAdapterError {
                throw RemoteHTTPError(403,error.localizedDescription,diagnostics:targetTTY==nil ? ["delivery":"not_started"]:nil)
            }
            guard let object=try JSONSerialization.jsonObject(with:Data(text.utf8)) as? JSONObject,
                  let tty=object["tty"] as? String,validTTY(tty) else {throw AppError.message("복원한 터미널을 확인하지 못했습니다.")}
            return tty
        }.value
    }
    public static func selectTab(_ tty:String) async throws {
        guard validTTY(tty) else {throw AppError.message("선택할 Terminal 탭을 확인하지 못했습니다.")}
        let target=try AutomationScript.literal(tty)
        _ = try await Task.detached(priority:.utility) {
            try AutomationScript.run("const app=Application('com.apple.Terminal'); let found=false; for(const window of app.windows())for(const tab of window.tabs())if(tab.tty()===\(target)){window.selectedTab=tab;found=true;} if(!found)throw Error('선택할 탭이 닫혔습니다.'); 'selected';",app:"Terminal",denied:.permissionDenied)
        }.value
    }
}
