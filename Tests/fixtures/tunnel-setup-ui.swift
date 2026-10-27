// A native interaction fixture: empty profile, loopback only, no user terminals.
import SwiftUI
import AppKit
import AutoApproveCore

@MainActor private final class SetupDelegate:NSObject,NSApplicationDelegate {
    var engine:ApprovalEngine?
    var clipboard:[[NSPasteboard.PasteboardType:Data]]=[]
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {true}
    func applicationWillTerminate(_ notification:Notification) {
        engine?.stop()
        if ["http://127.0.0.1:8766","sudo cloudflared service install SyntheticToken0123456789abcdef"].contains(NSPasteboard.general.string(forType:.string) ?? "") {
            NSPasteboard.general.clearContents()
            let items=clipboard.map {values in let item=NSPasteboardItem();for (type,data) in values {item.setData(data,forType:type)};return item}
            NSPasteboard.general.writeObjects(items)
        }
    }
}

@MainActor private struct SetupRoot:View {
    @ObservedObject var engine:ApprovalEngine
    var body:some View {ScrollView {TunnelSettings(engine:engine).padding(24)}.frame(minWidth:560,minHeight:600)}
}

@main struct TunnelSetupUI {
    @MainActor static func main() {
        let app=NSApplication.shared,delegate=SetupDelegate();app.delegate=delegate;app.setActivationPolicy(.regular)
        delegate.clipboard=(NSPasteboard.general.pasteboardItems ?? []).map {item in Dictionary(uniqueKeysWithValues:item.types.compactMap {type in item.data(forType:type).map {(type,$0)} })}
        Task { @MainActor in
            do {
                let output=Bundle.main.bundleURL.deletingLastPathComponent(),root=output.appendingPathComponent("ui-profile")
                let fixture=CloudflareFixture();fixture.loginDelay=1_000_000_000
                let workers=WorkersFixture();workers.delay=1_000_000_000
                fixture.pages=[[CloudflareFixture.domain(),CloudflareFixture.domain("registered-example.net",id:CloudflareFixture.otherZone),CloudflareFixture.domain("long-registered-domain-for-layout-verification.example.org",id:String(repeating:"d",count:32))]]
                let relay=CloudflareRelayServices(connect:{_ in
                    let session=URLSession(configuration:.ephemeral)
                    return CloudflareRelaySocket(session:session,task:session.webSocketTask(with:URL(string:"ws://127.0.0.1:9")!))
                },probe:{_ in CloudflareHTTPReply(data:Data(),status:503)})
                let engine=try ApprovalEngine(paths:AppPaths(directory:root),claudeRegistryReader:{_ in []},processReader:{[]},webLoopbackOnly:true,cloudflareServices:workers.http,workersServices:workers.tools,relayServices:relay)
                delegate.engine=engine;try engine.start(poll:false)
                if FileManager.default.fileExists(atPath:output.appendingPathComponent("reconnect-fixture").path) {
                    var config = RemoteTunnelConfiguration();config.executable = "/usr/bin/true"
                    try await engine.connectTunnel(config)
                }
                let view=SetupRoot(engine:engine)
                let window=NSWindow(contentRect:NSRect(x:0,y:0,width:680,height:760),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
                window.isReleasedWhenClosed=false
                window.title="AutoApprove · Cloudflare 설정 확인";window.contentView=NSHostingView(rootView:view)
                window.center();window.makeKeyAndOrderFront(nil);app.activate(ignoringOtherApps:true)
                var previous=Data()
                while true {
                    let command=try? String(contentsOf:output.appendingPathComponent("ui-control"),encoding:.utf8)
                    if command == "quit" {app.terminate(nil);return}
                    if command == "clipboard" {
                        NSPasteboard.general.clearContents();NSPasteboard.general.setString("sudo cloudflared service install SyntheticToken0123456789abcdef",forType:.string)
                        try? FileManager.default.removeItem(at:output.appendingPathComponent("ui-control"))
                    }
                    let value:JSONObject=["phase":engine.tunnelStatus.phase,"detail":engine.tunnelStatus.detail,"webReady":engine.webStatus.ready,"enabled":engine.tunnelConfiguration.enabled,"provider":engine.tunnelConfiguration.provider.rawValue,"sessions":engine.snapshot.sessions.count,"cloudflarePhase":engine.cloudflareStatus.phase,"authorized":engine.cloudflareStatus.authorized,"domains":engine.cloudflareStatus.domains.map(\.name),"syntheticAPI":workers.summary]
                    let data=try JSONSerialization.data(withJSONObject:value,options:.sortedKeys)
                    if data != previous {try data.write(to:output.appendingPathComponent("ui-status.json"),options:.atomic);previous=data}
                    try await Task.sleep(for:.milliseconds(100))
                }
            } catch {FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8));app.terminate(nil)}
        }
        app.run()
    }
}
