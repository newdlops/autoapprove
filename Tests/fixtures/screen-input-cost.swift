import Foundation
import CoreGraphics
import AutoApproveCore

@main struct ScreenInputCost {
    @MainActor static func main() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),probe=ScreenControlPreviewProbe(root)
        var targets=0,posted=0,time:TimeInterval=0
        let services=RemoteScreenControlServices(permission:{_ in true},target:{_ in
            targets+=1
            return RemoteScreenControlTarget(identity:"synthetic-cost-target",bounds:CGRect(x:-1920,y:-200,width:1920,height:1080))
        },post:{_ in posted+=1},clock:{time})
        let control=RemoteScreenControl(services:services),source=TestScreenSource(id:1,scope:"display",title:"Synthetic input cost",width:1920,height:1080)
        let image=try probe.image(source)
        let sharing=TestScreenSharing(permission:{_ in true},sources:{[source]},capture:{_ in image},remoteControl:control)
        let share=try await sharing.start(["sourceID":1],owner:"synthetic-input-cost"),frame=try await sharing.frame(share.id)
        let grant=try control.begin(share:share,frame:frame),before=targets,count=2400
        let payload=try RemoteScreenInput.move(x:32768,y:32768,modifiers:0).encoded().base64EncodedString(),began=DispatchTime.now().uptimeNanoseconds
        for sequence in 1...count {
            time+=0.01
            _=try control.input(["shareID":share.id,"controlID":grant.controlID,"token":grant.token,"sequence":sequence,"payload":payload],frame:frame)
        }
        control.revoke();sharing.stopAll()
        let result:JSONObject=["inputs":count,"targetReads":targets-before,"targetReadsPerInput":Double(targets-before)/Double(count),"constructedEvents":posted,
            "elapsedMS":Double(DispatchTime.now().uptimeNanoseconds-began)/1_000_000,"userDesktopPosts":0]
        print(String(decoding:try JSONSerialization.data(withJSONObject:result),as:UTF8.self))
    }
}
