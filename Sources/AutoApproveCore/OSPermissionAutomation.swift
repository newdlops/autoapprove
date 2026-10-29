import AppKit
import ApplicationServices
import Security

/// Uses ordinary Accessibility actions on verified Apple-owned permission UI.
/// No TCC database, elevated helper, global key press, or coordinate click is used.
public final class OSPermissionAutomation:@unchecked Sendable {
    public static let system = OSPermissionAutomation()
    public static var live:OSPermissionServices {
        .init(scan:{try system.scan(targets:$0)},approve:{request,authorized in system.approve(request,authorized:authorized)})
    }
    private let lock=NSLock()
    private let ownerVerifier:@Sendable (NSRunningApplication)->Bool
    private let settingsOwner:@Sendable (NSRunningApplication)->Bool
    private let usesAppleOwners:Bool
    private var settings:[String:(OSPermissionTarget,OSPermissionKind)] = [:]
    private static let owners:Set<String> = ["com.apple.UserNotificationCenter","com.apple.CoreServicesUIAgent","com.apple.coreservices.uiagent","com.apple.SecurityAgent","com.apple.systemuiserver","com.apple.notificationcenterui","com.apple.systempreferences","com.apple.controlcenter","com.apple.tccd"]
    private struct Handle {var request:OSPermissionRequest;var window:AXUIElement;var button:AXUIElement}
    private struct Node {var element:AXUIElement;var role:String;var texts:[String];var children:[Node];var enabled:Bool;var value:String
        var all:[Node] {[self]+children.flatMap(\.all)}
        var text:String {texts.joined(separator:"\n")}
    }
    public init(ownerVerifier:(@Sendable (NSRunningApplication)->Bool)?=nil,settingsOwner:(@Sendable (NSRunningApplication)->Bool)?=nil) {
        self.ownerVerifier=ownerVerifier ?? {OSPermissionAutomation.appleOwner($0)}
        self.settingsOwner=settingsOwner ?? {$0.bundleIdentifier=="com.apple.systempreferences"}
        usesAppleOwners=ownerVerifier==nil
    }
    private static func attribute(_ element:AXUIElement,_ name:String)->CFTypeRef? {
        var value:CFTypeRef?;return AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success ? value:nil
    }
    private static func elements(_ element:AXUIElement,_ name:String)->[AXUIElement] {attribute(element,name) as? [AXUIElement] ?? []}
    private static func string(_ element:AXUIElement,_ name:String)->String {attribute(element,name) as? String ?? ""}
    private static func node(_ element:AXUIElement,depth:Int=0,budget:inout Int,deadline:TimeInterval=ProcessInfo.processInfo.systemUptime+0.35)->Node? {
        guard depth<=10,budget>0,ProcessInfo.processInfo.systemUptime<deadline else {return nil};budget-=1
        AXUIElementSetMessagingTimeout(element,0.04)
        let role=string(element,kAXRoleAttribute),value=attribute(element,kAXValueAttribute)
        if role==kAXTextFieldRole || role=="AXSecureTextField" {return .init(element:element,role:role,texts:[],children:[],enabled:false,value:"")}
        let texts=[kAXTitleAttribute,kAXDescriptionAttribute,kAXValueAttribute].compactMap {name -> String? in
            guard let s=attribute(element,name) as? String,!s.isEmpty,s.utf8.count<=8192 else {return nil};return s
        }
        let children=depth<10 ? elements(element,kAXChildrenAttribute).prefix(100).compactMap {node($0,depth:depth+1,budget:&budget,deadline:deadline)}:[]
        return .init(element:element,role:role,texts:texts,children:children,enabled:(attribute(element,kAXEnabledAttribute) as? Bool) != false,value:(value as? NSNumber)?.stringValue ?? (value as? String ?? ""))
    }
    private static func runningCode(_ pid:Int32)->SecCode? {
        var code:SecCode?;guard SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid:pid] as CFDictionary,[],&code)==errSecSuccess else {return nil};return code
    }
    private static func appleOwner(_ app:NSRunningApplication)->Bool {
        guard let id=app.bundleIdentifier,owners.contains(id),app.bundleURL?.resolvingSymlinksInPath().path.hasPrefix("/System/")==true,let code=runningCode(app.processIdentifier) else {return false}
        var info:CFDictionary?,staticCode:SecStaticCode?
        guard SecCodeCopyStaticCode(code,[],&staticCode)==errSecSuccess,let staticCode,
              SecCodeCopySigningInformation(staticCode,SecCSFlags(rawValue:kSecCSSigningInformation),&info)==errSecSuccess,(info as? [String:Any])?[kSecCodeInfoIdentifier as String] as? String==id else {return false}
        var requirement:SecRequirement?
        return SecRequirementCreateWithString("anchor apple" as CFString,[],&requirement)==errSecSuccess && SecCodeCheckValidity(code,[],requirement)==errSecSuccess
    }
    private static func target(_ app:NSRunningApplication)->OSPermissionTarget? {
        guard !app.isTerminated,let url=app.bundleURL,let bundleID=app.bundleIdentifier,
              let code=runningCode(app.processIdentifier),SecCodeCheckValidity(code,[],nil)==errSecSuccess else {return nil}
        var req:SecRequirement?,text:CFString?,staticCode:SecStaticCode?
        guard SecCodeCopyStaticCode(code,[],&staticCode)==errSecSuccess,let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode,[],&req)==errSecSuccess,let req,
              SecRequirementCopyString(req,[],&text)==errSecSuccess,let text,
              let record=try? ProcessDiscovery.read(pid:app.processIdentifier).first,!record.started.isEmpty else {return nil}
        return .init(name:app.localizedName ?? url.deletingPathExtension().lastPathComponent,bundleID:bundleID,path:url.resolvingSymlinksInPath().path,requirement:text as String,pid:app.processIdentifier,started:record.started)
    }
    private static func requester(_ text:String,apps:[NSRunningApplication])->OSPermissionTarget? {
        // The first quoted name is the requesting app, never a guessed frontmost app.
        guard let name=OSPermissionPrompt.headline(text)?.name else {return nil}
        let matches=apps.filter {app in app.localizedName==name || app.bundleURL?.deletingPathExtension().lastPathComponent==name}
        guard matches.count==1 else {return nil};return target(matches[0])
    }
    private static let allows:Set<String>=["Allow","OK","Allow While Using the App","허용","확인","앱을 사용하는 동안 허용"]
    private static let openSettings:Set<String>=["Open System Settings","Open Settings","시스템 설정 열기","설정 열기","시스템 설정"]
    private static func requestNode(_ window:Node)->Node? {
        // Do not treat an ordinary app page or notification as an OS permission dialog.
        let alert=window.all.filter {$0.role==kAXSheetRole || $0.role=="AXDialog" || $0.role=="AXAlert"}
        if alert.count==1 {return alert[0]}
        if string(window.element,kAXSubroleAttribute)==kAXSystemDialogSubrole || string(window.element,kAXSubroleAttribute)==kAXDialogSubrole {return window}
        return nil
    }
    private func handles(targets:[OSPermissionTarget]) throws -> [Handle] {
        guard AXIsProcessTrusted() else {return []}
        let apps=NSWorkspace.shared.runningApplications
        lock.lock();let expected=Array(settings.values);lock.unlock()
        var result:[Handle]=[]
        let deadline=ProcessInfo.processInfo.systemUptime+1.5
        for app in apps {
            if settingsOwner(app),expected.isEmpty {continue}
            guard ownerVerifier(app) else {continue}
            guard let owner=try? ProcessDiscovery.read(pid:app.processIdentifier).first,!owner.started.isEmpty else {continue}
            let ax=AXUIElementCreateApplication(app.processIdentifier);AXUIElementSetMessagingTimeout(ax,0.12)
            for window in Self.elements(ax,kAXWindowsAttribute).prefix(12) {
                AXUIElementSetMessagingTimeout(window,0.04)
                if !settingsOwner(app) {
                    let subrole=Self.string(window,kAXSubroleAttribute),role=Self.string(window,kAXRoleAttribute)
                    if usesAppleOwners,["com.apple.UserNotificationCenter","com.apple.notificationcenterui"].contains(app.bundleIdentifier ?? ""),subrole != kAXSystemDialogSubrole {continue}
                    let isDialog=[kAXSystemDialogSubrole,kAXDialogSubrole,"AXSheet","AXAlert"].contains(subrole) || ["AXSheet","AXDialog","AXAlert"].contains(role)
                    let hasSheet = !Self.elements(window,"AXSheets").isEmpty || Self.elements(window,kAXChildrenAttribute).prefix(12).contains { ["AXSheet","AXDialog","AXAlert"].contains(Self.string($0,kAXRoleAttribute)) }
                    if !isDialog && !hasSheet && !["com.apple.SecurityAgent","com.apple.CoreServicesUIAgent","com.apple.coreservices.uiagent"].contains(app.bundleIdentifier ?? "") {continue}
                }
                guard ProcessInfo.processInfo.systemUptime<deadline else {throw AppError.message("OS 권한창 조회 시간이 지났습니다. 다음 관찰에서 다시 확인합니다.")}
                var budget=500;let treeDeadline=min(deadline,ProcessInfo.processInfo.systemUptime+0.35)
                guard let tree=Self.node(window,budget:&budget,deadline:treeDeadline),budget>0,ProcessInfo.processInfo.systemUptime<treeDeadline else {throw AppError.message("OS 권한창 전체를 확인하지 못했습니다. 확인되지 않은 창을 닫힘으로 처리하지 않습니다.")}
                if settingsOwner(app) {
                    for (target,kind) in expected where targets.contains(where:{$0.matches(target)}) {
                        guard let current=apps.first(where:{$0.processIdentifier==target.pid}),Self.target(current)==target else {continue}
                        let headings=tree.all.filter {![kAXButtonRole,kAXCheckBoxRole].contains($0.role)}.flatMap(\.texts)
                        let names:[String]
                        switch kind {
                        case .accessibility:names=["Accessibility","손쉬운 사용","Device Control and Data Access","기기 제어 및 데이터 접근"]
                        case .screenRecording:names=["Screen Recording","Screen & System Audio Recording","화면 기록","화면 및 시스템 오디오 녹음"]
                        case .fullDiskAccess:names=["Full Disk Access","전체 디스크 접근 권한","전체 디스크 접근"]
                        case .appManagement:names=["App Management","앱 관리"]
                        default:continue
                        }
                        guard headings.contains(where:names.contains) else {continue}
                        let rows=tree.all.filter {node in
                            [kAXRowRole,kAXGroupRole].contains(node.role) && node.all.count<40 && node.all.contains {$0.texts.contains(target.name)} && node.all.filter {$0.role==kAXCheckBoxRole || $0.role=="AXSwitch"}.count==1
                        }
                        let switches=rows.flatMap(\.all).filter {$0.role==kAXCheckBoxRole || $0.role=="AXSwitch"}
                        let unique=Dictionary(grouping:switches,by:{CFHash($0.element)})
                        guard unique.count==1,let button=unique.values.first?.first else {continue}
                        if button.value=="1" {lock.lock();settings.removeValue(forKey:target.id);lock.unlock();continue}
                        guard button.enabled,button.value=="0" else {continue}
                        let token=String(CFHash(window)),action=String(CFHash(button.element))
                        let request=OSPermissionRequest(kind:kind,requester:target,ownerPID:owner.pid,ownerStarted:owner.started,ownerBundleID:app.bundleIdentifier!,windowToken:token,content:"\(target.name) · \(kind.title) · 꺼짐",action:.enableSetting,actionToken:action)
                        result.append(.init(request:request,window:window,button:button.element))
                    }
                    continue
                }
                guard let dialog=Self.requestNode(tree) else {continue}
                let content=dialog.all.filter {![kAXButtonRole,kAXCheckBoxRole].contains($0.role)}.flatMap(\.texts).joined(separator:"\n")
                guard content.utf8.count<=16384,let kind=OSPermissionPrompt.headline(content)?.kind ?? OSPermissionKind.detect(content) else {continue}
                let lower=content.lowercased()
                let protected=kind == .authentication || dialog.all.contains(where:{$0.role=="AXSecureTextField" || $0.role==kAXTextFieldRole}) || ["administrator","password","touch id","keychain","관리자","암호","키체인"].contains(where:lower.contains)
                let buttons=dialog.all.filter {$0.role==kAXButtonRole && $0.enabled}
                let allow=buttons.filter {$0.texts.contains(where:Self.allows.contains)}
                let settings=buttons.filter {$0.texts.contains(where:Self.openSettings.contains)}
                let action:OSPermissionRequest.Action,button:Node
                if protected {action = .manual;button=dialog}
                else if allow.count==1 {action = .allow;button=allow[0]}
                else if allow.isEmpty,settings.count==1 {action = .openSettings;button=settings[0]}
                else {continue}
                let request=OSPermissionRequest(kind:kind,requester:Self.requester(content,apps:apps),ownerPID:owner.pid,ownerStarted:owner.started,ownerBundleID:app.bundleIdentifier!,windowToken:String(CFHash(dialog.element)),content:content,action:action,actionToken:String(CFHash(button.element)))
                result.append(.init(request:request,window:window,button:button.element))
            }
        }
        return Dictionary(grouping:result,by:{$0.request.id}).values.compactMap(\.first).sorted {$0.request.id<$1.request.id}
    }
    public func scan(targets:[OSPermissionTarget]) throws -> OSPermissionMonitorStatus {
        guard AXIsProcessTrusted() else {return .init(available:false,detail:"Mac의 손쉬운 사용에서 AutoApprove를 허용하면 OS 권한창을 확인하고 세션 정책으로 조작할 수 있습니다.")}
        return .init(available:true,detail:"OS 권한은 등록한 앱과 이 세션에서 허용한 종류에만 적용합니다.",requests:try handles(targets:targets).map(\.request))
    }
    @MainActor public func approve(_ request:OSPermissionRequest,authorized:@MainActor ()->Bool)->OSPermissionDelivery {
        guard request.action != .manual,authorized(),let target=request.requester else {return .unavailable("이 요청은 Mac에서 직접 인증하거나 요청 앱을 확인해야 합니다.")}
        do {
            let fresh=try handles(targets:[target]).filter {$0.request.immutableToken==request.immutableToken}
            guard fresh.count==1,let handle=fresh.first,authorized(),
                  let requester=NSRunningApplication(processIdentifier:target.pid),Self.target(requester)==target,
                  let owner=NSRunningApplication(processIdentifier:request.ownerPID),ownerVerifier(owner),
                  (try? ProcessDiscovery.read(pid:request.ownerPID).first?.started)==request.ownerStarted else {
                return .unavailable("원래 OS 권한창·요청 앱·세션 정책이 바뀌어 조작하지 않았습니다.")
            }
            // The authorization closure runs immediately before this one native action.
            var budget=500
            guard authorized(),let tree=Self.node(handle.window,budget:&budget),
                  let button=tree.all.first(where:{CFEqual($0.element,handle.button)}),button.enabled else {return .unavailable("정책 또는 OS 버튼이 바뀌어 조작하지 않았습니다.")}
            if request.action == .enableSetting {
                guard button.value=="0",[kAXCheckBoxRole,"AXSwitch"].contains(button.role) else {return .unavailable("OS 권한 스위치가 이미 바뀌어 누르지 않았습니다.")}
            } else {
                guard let dialog=Self.requestNode(tree),!dialog.all.contains(where:{$0.role==kAXTextFieldRole || $0.role=="AXSecureTextField"}),
                      dialog.all.filter({![kAXButtonRole,kAXCheckBoxRole].contains($0.role)}).flatMap(\.texts).joined(separator:"\n")==request.content,
                      button.role==kAXButtonRole,button.texts.contains(where:request.action == .allow ? Self.allows.contains:Self.openSettings.contains) else {return .unavailable("OS 요청 내용이나 허용 버튼이 바뀌어 누르지 않았습니다.")}
            }
            AXUIElementSetMessagingTimeout(handle.button,0.5)
            let error=AXUIElementPerformAction(handle.button,kAXPressAction as CFString)
            if request.action == .enableSetting {lock.lock();settings.removeValue(forKey:target.id);lock.unlock()}
            guard error == .success else {return .uncertain("OS 권한 입력 결과를 확인하지 못했습니다 (AX \(error.rawValue)). 원래 Mac에서 확인해주세요.")}
            if request.action == .openSettings {
                lock.lock();settings[target.id]=(target,request.kind);lock.unlock()
            }
            return .sent
        } catch {return .unavailable(String(error.localizedDescription.prefix(1000)))}
    }
}
