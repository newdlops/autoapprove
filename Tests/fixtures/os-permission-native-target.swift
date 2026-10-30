// Default mode uses fake permission UI only. Explicit --real-tcc mode queries
// automation authorization for our isolated QA receiver, with operator consent.
import AppKit
import CoreServices
@MainActor final class PermissionTargetDelegate:NSObject,NSApplicationDelegate {
    var window:NSWindow!,alert:NSAlert?,timer:Timer?,toggle:NSButton?
    var phase="",camera=0,opened=0,enabled=0,denied=0
    var authorization:Int32?
    var targetName:String?
    let root=URL(fileURLWithPath:CommandLine.arguments[1])
    func report(settings:Bool=false) {
        var value:[String:Any]=["camera":camera,"openedSettings":opened,"enabledSetting":enabled,"settingsVisible":settings,"toggleOn":toggle?.state == .on,"realOSPermissionsChanged":authorization==0 ? 1:0]
        value["denied"]=denied
        if let authorization {value["automationAuthorizationStatus"]=authorization};if let targetName {value["eventTargetName"]=targetName}
        if let data=try? JSONSerialization.data(withJSONObject:value) {try? data.write(to:root.appendingPathComponent("native-target.json"),options:.atomic)}
    }
    func applicationDidFinishLaunching(_ notification:Notification) {
        window=NSWindow(contentRect:NSRect(x:160,y:180,width:440,height:240),styleMask:[.titled,.closable],backing:.buffered,defer:false);window.title="합성 OS 권한 요청 대상";window.isReleasedWhenClosed=false
        let real=CommandLine.arguments.contains("--real-tcc"),isEventTarget=CommandLine.arguments.contains("--event-target")
        let label=NSTextField(labelWithString:real ? "동의한 QA 앱 쌍의 OS 자동화 권한만 확인합니다. Terminal·카메라·마이크에는 접근하지 않습니다.":"격리된 권한 UI입니다. 실제 macOS 권한은 변경하지 않습니다.");label.frame=NSRect(x:20,y:80,width:400,height:80);label.maximumNumberOfLines=3;window.contentView?.addSubview(label);window.makeKeyAndOrderFront(nil)
        if isEventTarget {window.title="격리된 OS 자동화 수신 대상";return};report()
        timer=Timer.scheduledTimer(withTimeInterval:0.2,repeats:true) {[weak self] _ in Task {@MainActor in self?.readControl()}}
    }
    func readControl() {
        guard let data=try? Data(contentsOf:root.appendingPathComponent("native-control.json")),let object=(try? JSONSerialization.jsonObject(with:data)) as? [String:String],let next=object["phase"],next != phase else {return}
        phase=next
        if next=="real-automation",CommandLine.arguments.contains("--real-tcc") {
            Task {
                let status=await Task.detached {
                    let target=NSAppleEventDescriptor(bundleIdentifier:"local.autoapprove.permission-qa-event-target")
                    return AEDeterminePermissionToAutomateTarget(target.aeDesc,AEEventClass(kAECoreSuite),AEEventID(kAEGetData),true)
                }.value
                authorization=status
                targetName=NSWorkspace.shared.runningApplications.first {$0.bundleIdentifier=="local.autoapprove.permission-qa-event-target"}?.localizedName
                report()
            }
            return
        }
        if next=="revoke" {toggle?.state = .off;report(settings:true);return}
        guard alert==nil,["camera","accessibility"].contains(next) else {return}
        toggle=nil
        let alert=NSAlert();self.alert=alert
        let name=NSRunningApplication.current.localizedName ?? "AutoApprove OS Dialog QA"
        alert.messageText="\"\(name)\" would like to "+(next=="camera" ? "access the camera.":"use Accessibility features.")
        alert.informativeText="Synthetic permission dialog for QA. No camera, screen or accessibility permission is requested."
        alert.addButton(withTitle:next=="camera" ? "Allow":"Open System Settings");alert.addButton(withTitle:"Don't Allow")
        alert.beginSheetModal(for:window) {[weak self] response in
            guard let self else {return};self.alert=nil
            if response == .alertFirstButtonReturn {
                if next=="camera" {self.camera+=1;self.report()}
                else {self.opened+=1;self.showSettings()}
            } else {self.denied+=1;self.report()}
        }
    }
    func showSettings() {
        window.title="합성 Privacy & Security 설정"
        let rootView=NSView(frame:NSRect(x:0,y:0,width:440,height:240));rootView.setAccessibilityElement(true);rootView.setAccessibilityRole(.group)
        let heading=NSTextField(labelWithString:"Accessibility");heading.frame=NSRect(x:20,y:180,width:400,height:30)
        let row=NSView(frame:NSRect(x:20,y:80,width:400,height:70));row.setAccessibilityElement(true);row.setAccessibilityRole(.group)
        let toggle=NSButton(checkboxWithTitle:NSRunningApplication.current.localizedName ?? "AutoApprove OS Dialog QA",target:self,action:#selector(changed));toggle.frame=NSRect(x:0,y:20,width:390,height:32);self.toggle=toggle
        row.addSubview(toggle);row.setAccessibilityChildren([toggle]);rootView.addSubview(heading);rootView.addSubview(row);rootView.setAccessibilityChildren([heading,row]);window.contentView=rootView;report(settings:true)
    }
    @objc func changed() {if toggle?.state == .on {enabled+=1};report(settings:true)}
}
@main struct PermissionTarget {
    static func main() {let app=NSApplication.shared;let delegate=PermissionTargetDelegate();app.delegate=delegate;app.setActivationPolicy(.regular);app.run()}
}
