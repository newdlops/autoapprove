import SwiftUI
import AppKit
import AutoApproveCore

@MainActor private struct TunnelSnapshotRoot:View {
    @ObservedObject var engine:ApprovalEngine
    var body:some View {TunnelSettings(engine:engine)}
}

@main struct TunnelSettingsPreview {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let output=URL(fileURLWithPath:CommandLine.arguments[1]),root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-tunnel-ui-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let scenarios=RemoteTunnelProvider.allCases.map {($0.rawValue,$0)}+[("managed-authorized",.managed),("managed-empty",.managed),("managed-error",.managed),("https-authorized",.https),("https-empty",.https),("https-error",.https),("https-pin",.https)]
        for (scenario,provider) in scenarios {
            let paths=AppPaths(directory:root.appendingPathComponent(scenario));try paths.prepare()
            var configuration=RemoteTunnelConfiguration();configuration.provider=provider
            configuration.publicURL="https://terminal-with-a-long-name.for-existing-settings-layout.example.com"
            let store=try AuditStore(path:paths.database)
            try store.set("remoteTunnel",String(decoding:JSONEncoder().encode(configuration),as:UTF8.self))
            let fixture=CloudflareFixture()
            let workers=WorkersFixture()
            if scenario == "managed-empty" {fixture.pages=[[]]}
            if scenario == "https-empty" {workers.empty=true}
            let engine=try ApprovalEngine(paths:paths,processReader:{[]},cloudflareServices:provider == .https ? workers.http:fixture.services,workersServices:workers.tools)
            if scenario.hasPrefix("managed-") {try await engine.authorizeCloudflare(executable:"/usr/bin/true")}
            if scenario == "managed-error" {fixture.indexStatus=401;try? await engine.loadCloudflareDomains()}
            if scenario.hasPrefix("https-") {try await engine.authorizeCloudflare(provider:.https)}
            if scenario == "https-error" {workers.indexStatus=403;try? await engine.loadCloudflareDomains(provider:.https)}
            if scenario == "https-pin" {try await engine.setTunnelPIN("001234")}
            for (name,scheme) in [("light",ColorScheme.light),("dark",ColorScheme.dark)] {
                let view=TunnelSnapshotRoot(engine:engine).padding(24).frame(width:600,height:660,alignment:.topLeading)
                    .background(Color(nsColor:.windowBackgroundColor)).environment(\.colorScheme,scheme)
                let host=NSHostingView(rootView:view);host.frame=NSRect(x:0,y:0,width:600,height:660)
                host.appearance=NSAppearance(named:scheme == .dark ? .darkAqua : .aqua)
                let window=NSWindow(contentRect:host.frame,styleMask:[.borderless],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=host
                // Allow onAppear and the view's ordinary state update to finish.
                try await Task.sleep(for:.milliseconds(250))
                for _ in 0..<100 where engine.cloudflareStatus.busy {try await Task.sleep(for:.milliseconds(10))}
                host.layoutSubtreeIfNeeded();host.displayIfNeeded()
                guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else {throw AppError.message("Native tunnel preview unavailable")}
                host.cacheDisplay(in:host.bounds,to:bitmap)
                guard let png=bitmap.representation(using:.png,properties:[:]) else {throw AppError.message("Native tunnel PNG unavailable")}
                try png.write(to:output.appendingPathComponent(scenario+"-"+name+".png"));window.close()
            }
            engine.stop()
        }
        print("PASS: five native connection modes and both approval methods' authorized/empty/error states in light/dark at 600×660; synthetic profiles, no public connection, keychain or permission changes")
    }
}
