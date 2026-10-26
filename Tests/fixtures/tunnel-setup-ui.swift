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
                let engine=try ApprovalEngine(paths:AppPaths(directory:root),claudeRegistryReader:{_ in []},processReader:{[]},webLoopbackOnly:true)
                delegate.engine=engine;try engine.start(poll:false)
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
                    let value:JSONObject=["phase":engine.tunnelStatus.phase,"detail":engine.tunnelStatus.detail,"webReady":engine.webStatus.ready,"toolInstalled":engine.tunnelToolPath != nil,"enabled":engine.tunnelConfiguration.enabled,"sessions":engine.snapshot.sessions.count]
                    let data=try JSONSerialization.data(withJSONObject:value,options:.sortedKeys)
                    if data != previous {try data.write(to:output.appendingPathComponent("ui-status.json"),options:.atomic);previous=data}
                    try await Task.sleep(for:.milliseconds(100))
                }
            } catch {FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8));app.terminate(nil)}
        }
        app.run()
    }
}
