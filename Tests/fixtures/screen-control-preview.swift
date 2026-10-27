import Foundation
import AutoApproveCore

@main struct ScreenControlPreview {
    @MainActor static func main() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),probe=ScreenControlPreviewProbe(root)
        let control=RemoteScreenControl(services:probe.services())
        let sources=[TestScreenSource(id:1,scope:"display",title:"합성 Mac 전체 화면",width:1920,height:1080),TestScreenSource(id:2,scope:"window",title:"합성 단일 창 · "+String(repeating:"긴 창 이름 ",count:12),width:800,height:500,ownerPID:999999,ownerBundleID:"qa.synthetic",ownerStarted:"synthetic-start")]
        let screen=TestScreenSharing(permission:{_ in true},sources:{sources},capture:{source in try await probe.image(source)},remoteControl:control)
        let engine=try ApprovalEngine(paths:AppPaths(directory:root.appendingPathComponent("profile")),processReader:{[]},testScreenSharing:screen,webLoopbackOnly:true,nativeKeyboardActivity:.inactive)
        try engine.start(poll:false);try engine.setWebEnabled(true,port:0,bonjourEnabled:false,discoveryAddresses:{[]})
        while !engine.webStatus.ready {try await Task.sleep(for:.milliseconds(10))}
        let share=try await screen.start(["scope":"display","sourceID":1,"durationSeconds":600],owner:"synthetic-screen-preview")
        let window=try await screen.start(["scope":"window","sourceID":2,"durationSeconds":600],owner:"synthetic-screen-preview")
        let gateway=try RemoteTunnelGateway(pin:RemoteTunnelPIN.create("001234"),handler:{[weak engine] request in
            guard let service=engine?.webService else {return .error(RemoteHTTPError(503,"Synthetic manager stopped"))};return await service.handle(request)
        })
        try gateway.setOrigin("https://screen-control.tunnel-qa.invalid");try await gateway.start(port:0)
        let ready:JSONObject=["port":Int(engine.webStatus.port!),"base":engine.webStatus.loopbackURL!,"gateway":gateway.localURL!,"display":share.id,"window":window.id]
        try JSONSerialization.data(withJSONObject:ready).write(to:root.appendingPathComponent("ready.json"),options:.atomic)
        while !FileManager.default.fileExists(atPath:root.appendingPathComponent("stop").path) {try await Task.sleep(for:.milliseconds(100))}
        gateway.stop();engine.stop()
    }
}
