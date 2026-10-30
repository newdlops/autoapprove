import SwiftUI
import AppKit
import AutoApproveCore

@MainActor final class NativePermissionQA:NSObject,NSApplicationDelegate {
    var window:NSWindow!,engine:ApprovalEngine?,child:Process?,task:Task<Void,Never>?
    var requester:NSRunningApplication?,eventTarget:Process?
    let root=URL(fileURLWithPath:CommandLine.arguments[1]),childURL=URL(fileURLWithPath:CommandLine.arguments[2])
    var sessionID="",nativeActions=0,productionIgnoredFixture=false,staleButtonRejected=false,revocationRejected=false
    var realTCC:Bool {CommandLine.arguments.contains("--real-tcc")}
    func applicationDidFinishLaunching(_ notification:Notification) {Task {await prepare()}}
    func prepare() async {
        do {
            let pid:Int32
            if realTCC {
                let target=Process();target.executableURL=root.appendingPathComponent("AutoApprove OS Event Target QA.app/Contents/MacOS/PermissionTarget");target.arguments=[root.path,"--event-target"];try target.run();eventTarget=target
                let configuration=NSWorkspace.OpenConfiguration();configuration.arguments=[root.path,"--real-tcc"];configuration.createsNewApplicationInstance=true
                requester=try await NSWorkspace.shared.openApplication(at:childURL,configuration:configuration);pid=requester!.processIdentifier
            } else {
                let child=Process();child.executableURL=childURL.appendingPathComponent("Contents/MacOS/PermissionTarget");child.arguments=[root.path];try child.run();self.child=child;pid=child.processIdentifier
            }
            let expected=childURL.path,root=self.root
            let native=OSPermissionAutomation(ownerVerifier:{$0.processIdentifier==pid && $0.bundleURL?.path==expected},settingsOwner:{app in
                guard app.processIdentifier==pid,let data=try? Data(contentsOf:root.appendingPathComponent("native-target.json")),let object=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else {return false};return object["settingsVisible"] as? Bool==true
            })
            let actual=OSPermissionAutomation.system,useReal=realTCC
            let services=OSPermissionServices(scan:{try (useReal ? actual:native).scan(targets:$0)},approve:{[weak self] request,authorized in
                let result=(useReal ? actual:native).approve(request,authorized:authorized);if result == .sent {self?.nativeActions+=1};return result
            },respond:{[weak self] request,button,authorized in
                var changed=button;changed.id="stale-"+button.id
                if case .unavailable=(useReal ? actual:native).respond(request,button:changed,authorized:{true}) {self?.staleButtonRejected=true}
                if case .unavailable=(useReal ? actual:native).respond(request,button:button,authorized:{false}) {self?.revocationRejected=true}
                let result=(useReal ? actual:native).respond(request,button:button,authorized:authorized);if result == .sent {self?.nativeActions+=1};return result
            })
            let records=ProcessDiscovery.parse("101950 1 ttys950 101950 101950 Wed Oct 28 22:00:00 2026 /fixture/codex")
            let adapter=ScreenHostAdapter(screens:{targets in .init(screens:targets.map {.init(tty:$0.tty,contents:"Working\n› Ask Codex to do anything")})},approve:{_,_,_ in .missingTarget},reveal:{_ in nil})
            let engine=try ApprovalEngine(paths:.init(directory:root.appendingPathComponent("native-engine")),processReader:{records},screenAdapters:[.terminal:adapter],osPermissionServices:services);self.engine=engine
            var session=ProcessDiscovery.sessions(records)[0];session.terminal = .terminal;sessionID=session.id
            engine.updateDiscovery([session],records:records);await engine.connectTerminal();try engine.setAutomatic(session.id,enabled:true)
            window=NSWindow(contentRect:NSRect(x:640,y:110,width:620,height:820),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false);window.title="OS 권한 세션 정책 QA";window.isReleasedWhenClosed=false
            window.contentView=NSHostingView(rootView:NativePermissionRoot(engine:engine,id:sessionID,realTCC:realTCC,control:{[weak self] value in self?.control(value)}));window.makeKeyAndOrderFront(nil)
            task=Task {[weak self] in
                while !Task.isCancelled,let self {
                    await engine.refreshOSPermissions()
                    let productionRead=Task.detached {try OSPermissionAutomation().scan(targets:[])}
                    if let status=try? await productionRead.value {self.productionIgnoredFixture=status.available && status.requests.allSatisfy {$0.ownerPID != pid}}
                    self.report();do {try await Task.sleep(for:.milliseconds(300))} catch {break}
                }
            }
            print("READY: isolated native permission policy QA");fflush(stdout)
        } catch {print("FAIL: \(error)");NSApplication.shared.terminate(nil)}
    }
    func control(_ value:String) {
        if value=="manual-deny",!realTCC,let engine,let request=engine.snapshot.osPermissions?.requests.first(where:{$0.phase == .waiting}),let button=request.buttons?.first(where:{$0.kind == .deny}) {
            do {try engine.setAutomatic(sessionID,enabled:false);try engine.assignOSPermission(sessionID,requestID:request.id,token:request.immutableToken,remember:false);try engine.respondOSPermission(sessionID,requestID:request.id,token:request.immutableToken,buttonID:button.id)} catch {print("Manual fixture response failed: \(error.localizedDescription)")};report();return
        }
        if let data=try? JSONSerialization.data(withJSONObject:["phase":value]) {try? data.write(to:root.appendingPathComponent("native-control.json"),options:.atomic)}
    }
    func report() {
        let status=engine?.snapshot.osPermissions
        let value:[String:Any]=["available":status?.available==true,"detail":status?.detail ?? "","nativeActions":nativeActions,"requests":status?.requests.count ?? 0,"states":status?.requests.map {["phase":$0.phase.rawValue,"detail":$0.detail,"action":$0.action.rawValue]} ?? [],"productionIgnoredFixture":productionIgnoredFixture,"realTCC":realTCC,"originalTerminalInputs":0]
        var report=value;report["staleButtonRejected"]=staleButtonRejected;report["revocationRejected"]=revocationRejected
        if let data=try? JSONSerialization.data(withJSONObject:report) {try? data.write(to:root.appendingPathComponent("native-driver.json"),options:.atomic)}
    }
    func applicationWillTerminate(_ notification:Notification) {task?.cancel();engine?.stop();if child?.isRunning==true {child?.terminate()};requester?.terminate();if eventTarget?.isRunning==true {eventTarget?.terminate()}}
}
struct NativePermissionRoot:View {
    @ObservedObject var engine:ApprovalEngine
    let id:String
    var realTCC=false
    let control:(String)->Void
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                Text("OS 권한 세션 정책 QA").font(.title2.bold())
                Text(realTCC ? "동의한 QA 앱 쌍의 실제 OS 자동화 권한을 확인합니다. 사용자 Terminal·카메라·마이크에는 접근하지 않습니다.":"합성 CLI·권한창입니다. 실제 사용자 Terminal과 OS 권한은 변경하지 않습니다.").font(.callout)
                if realTCC {Button("격리된 자동화 권한 요청") {control("real-automation")}}
                else {
                    HStack {Button("카메라 요청 만들기") {control("camera")};Button("손쉬운 사용 요청 만들기") {control("accessibility")}}
                    Button("테스트 권한 다시 끄기") {control("revoke")}
                    Button("현재 요청 거부로 응답") {control("manual-deny")}
                }
                if let session=engine.snapshot.sessions.first(where:{$0.id==id}) {
                    OSPermissionPolicyView(session:session,status:engine.snapshot.osPermissions,paused:engine.snapshot.paused,setAllowed:{try engine.setOSPermissionPolicy(id,allowed:$0)},assign:{try engine.assignOSPermission(id,requestID:$0,token:$1,remember:$2)},remove:{try engine.removeOSPermissionTarget(id,targetID:$0)},acknowledge:{try engine.acknowledgeOSPermission(id,requestID:$0,token:$1)},initiallyExpanded:true)
                }
            }.padding(24)
        }.frame(minWidth:480,minHeight:600)
    }
}
@main struct PermissionQA {
    static func main() {
        let app=NSApplication.shared,menu=NSMenu(),item=NSMenuItem(),submenu=NSMenu();submenu.addItem(withTitle:"QA 종료",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");item.submenu=submenu;menu.addItem(item);app.mainMenu=menu
        let delegate=NativePermissionQA();app.delegate=delegate;app.setActivationPolicy(.regular);app.run()
    }
}
