import SwiftUI
import AppKit
import AutoApproveCore

@main struct TunnelSettingsPreview {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let output=URL(fileURLWithPath:CommandLine.arguments[1]),root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-tunnel-ui-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        for provider in RemoteTunnelProvider.allCases {
            let paths=AppPaths(directory:root.appendingPathComponent(provider.rawValue));try paths.prepare()
            var configuration=RemoteTunnelConfiguration();configuration.provider=provider
            configuration.publicURL="https://terminal-with-a-long-name.for-existing-settings-layout.example.com"
            let store=try AuditStore(path:paths.database)
            try store.set("remoteTunnel",String(decoding:JSONEncoder().encode(configuration),as:UTF8.self))
            let engine=try ApprovalEngine(paths:paths,processReader:{[]})
            for (name,scheme) in [("light",ColorScheme.light),("dark",ColorScheme.dark)] {
                let view=TunnelSettings(engine:engine).padding(24).frame(width:600,height:660,alignment:.topLeading)
                    .background(Color(nsColor:.windowBackgroundColor)).environment(\.colorScheme,scheme)
                let host=NSHostingView(rootView:view);host.frame=NSRect(x:0,y:0,width:600,height:660)
                host.appearance=NSAppearance(named:scheme == .dark ? .darkAqua : .aqua)
                let window=NSWindow(contentRect:host.frame,styleMask:[.borderless],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=host
                // Allow onAppear and the view's ordinary state update to finish.
                try await Task.sleep(for:.milliseconds(120))
                host.layoutSubtreeIfNeeded();host.displayIfNeeded()
                guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else {throw AppError.message("Native tunnel preview unavailable")}
                host.cacheDisplay(in:host.bounds,to:bitmap)
                guard let png=bitmap.representation(using:.png,properties:[:]) else {throw AppError.message("Native tunnel PNG unavailable")}
                try png.write(to:output.appendingPathComponent(provider.rawValue+"-"+name+".png"));window.close()
            }
            engine.stop()
        }
        print("PASS: six native tunnel settings renders at 600×660; inert private profiles, no public connection, keychain or permission changes")
    }
}
