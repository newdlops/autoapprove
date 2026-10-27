import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AutoApproveCore

private actor TransferImage {
    var image:TerminalNativeImage
    var captures=0
    init(_ image:TerminalNativeImage) {self.image=image}
    func set(_ image:TerminalNativeImage) {self.image=image}
    func capture()->TerminalNativeImage {captures+=1;return image}
}
private actor TransferGate {
    let image:TerminalNativeImage
    var holding=false
    var captures=0
    init(_ image:TerminalNativeImage) {self.image=image}
    func hold(_ value:Bool) {holding=value}
    func capture() async throws ->TerminalNativeImage {
        captures+=1
        while holding {try await Task.sleep(for:.milliseconds(5))}
        return image
    }
}
private func transferImage(_ gray:CGFloat,width:Int=8)throws->TerminalNativeImage {
    let context=CGContext(data:nil,width:width,height:8,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(gray:gray,alpha:1));context.fill(CGRect(x:0,y:0,width:width,height:8))
    let bytes=NSMutableData(),destination=CGImageDestinationCreateWithData(bytes,UTType.jpeg.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(destination,context.makeImage()!,nil);try expect(CGImageDestinationFinalize(destination))
    return TerminalNativeImage(data:(bytes as Data).base64EncodedString(),width:width,height:8)
}
extension ApprovalTests {
    func testScreenTransferCancelledViewerKeepsOtherReadersAndControl() async throws {
        let image=try transferImage(0.5),gate=TransferGate(image),source=TestScreenSource(id:1,scope:"display",title:"Synthetic shared capture",width:8,height:8)
        let control=RemoteScreenControl(services:RemoteScreenControlServices(permission:{_ in true},target:{_ in RemoteScreenControlTarget(identity:"synthetic-owner",bounds:CGRect(x:0,y:0,width:8,height:8))},post:{_ in throw AppError.message("No desktop input is allowed")}))
        let sharing=TestScreenSharing(permission:{_ in true},sources:{[source]},capture:{_ in try await gate.capture()},remoteControl:control)
        defer {sharing.stopAll()}
        let share=try await sharing.start(["sourceID":1],owner:"shared-readers")
        _=try await sharing.frame(share.id);_ = try sharing.beginControl(["shareID":share.id])
        await gate.hold(true);try await Task.sleep(for:.milliseconds(130))
        let cancelled=Task {try await sharing.frame(share.id)}
        for _ in 0..<100 where await gate.captures<2 {try await Task.sleep(for:.milliseconds(5))}
        try expectEqual(await gate.captures,2)
        let other=Task {try await sharing.frame(share.id)},third=Task {try await sharing.frame(share.id)}
        try await Task.sleep(for:.milliseconds(10));cancelled.cancel();await gate.hold(false)
        do {_ = try await cancelled.value;throw AppError.message("Cancelled viewer received an image")}
        catch is CancellationError {}
        let a=try await other.value,b=try await third.value
        try expectEqual(a.image,image);try expectEqual(a.observedAt,b.observedAt,"Coalesced readers share one actual capture timestamp")
        try expectEqual(await gate.captures,2,"Cancelling one viewer must not restart another viewer's capture")
        try expect(control.isControlling(share.id),"Cancelling a read-only viewer must not revoke another viewer's control lease")
    }
    func testScreenTransferUsesCurrentCaptureBeforeNotModified() async throws {
        let image=try transferImage(0.2),store=TransferImage(image)
        let source=TestScreenSource(id:1,scope:"display",title:"Synthetic conditional frame",width:8,height:8)
        let sharing=TestScreenSharing(permission:{_ in true},sources:{[source]},capture:{_ in await store.capture()})
        defer {sharing.stopAll()}
        let share=try await sharing.start(["sourceID":1],owner:"conditional-qa")
        let first=try await sharing.response(share.id,entityTag:nil)
        try expectEqual(first.status,200);try expect(first.entityTag?.hasPrefix("W/\"screen-")==true)
        let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        try expectEqual(try decoder.decode(TestScreenFrame.self,from:first.body).image,image)
        try await Task.sleep(for:.milliseconds(510))
        let unchanged=try await sharing.response(share.id,entityTag:first.entityTag)
        try expectEqual(unchanged.status,304);try expect(unchanged.body.isEmpty)
        try expectEqual(unchanged.entityTag,first.entityTag);try expect(unchanged.observedAt!>first.observedAt!)
        try expectEqual(await store.captures,2,"304 must follow a fresh capture rather than a permanent screenshot cache")
        await store.set(try transferImage(0.8,width:9));try await Task.sleep(for:.milliseconds(510))
        let changed=try await sharing.response(share.id,entityTag:first.entityTag)
        try expectEqual(changed.status,200);try expect(changed.entityTag != first.entityTag)
        try expectEqual(try decoder.decode(TestScreenFrame.self,from:changed.body).image.width,9)
        let unconditional=try await sharing.response(share.id,entityTag:nil)
        try expectEqual(unconditional.status,200);try expectFalse(unconditional.body.isEmpty)
    }
    func testScreenTransferValidatorCannotBypassPermissionOrShareLifetime() async throws {
        let image=try transferImage(0.4),source=TestScreenSource(id:1,scope:"display",title:"Synthetic revoked frame",width:8,height:8)
        var allowed=true
        let sharing=TestScreenSharing(permission:{_ in allowed},sources:{[source]},capture:{_ in image})
        defer {sharing.stopAll()}
        let first=try await sharing.start(["sourceID":1],owner:"one"),second=try await sharing.start(["sourceID":1],owner:"two")
        let a=try await sharing.response(first.id,entityTag:nil),b=try await sharing.response(second.id,entityTag:a.entityTag)
        try expectEqual(b.status,200);try expect(b.entityTag != a.entityTag,"Identical images from different grants cannot share a validator")
        let wildcard=try await sharing.response(first.id,entityTag:"*")
        try expectEqual(wildcard.status,200)
        allowed=false
        do {_ = try await sharing.response(first.id,entityTag:a.entityTag);throw AppError.message("Validator bypassed revoked screen permission")}
        catch let error as RemoteHTTPError {try expectEqual(error.status,403)}
        allowed=true;try sharing.stop(first.id)
        do {_ = try await sharing.response(first.id,entityTag:a.entityTag);throw AppError.message("Stopped share returned a cached frame")}
        catch let error as RemoteHTTPError {try expectEqual(error.status,410)}
    }
    func testScreenTransferPeerPreservesValidatorAndFreshNodeIdentity() async throws {
        let directory=URL(fileURLWithPath:"/private/tmp/aa-screen-peer-"+UUID().uuidString.prefix(12))
        defer {try? FileManager.default.removeItem(at:directory)}
        let image=try transferImage(0.3),source=TestScreenSource(id:1,scope:"display",title:"Synthetic peer frame",width:8,height:8)
        let sharing=TestScreenSharing(permission:{_ in true},sources:{[source]},capture:{_ in image})
        let peer=try ApprovalEngine(paths:AppPaths(directory:directory.appendingPathComponent("peer")),processReader:{[]},testScreenSharing:sharing,webLoopbackOnly:true)
        defer {peer.stop()};try peer.start(poll:false);try peer.setWebEnabled(true,port:0,bonjourEnabled:false,discoveryAddresses:{[]})
        for _ in 0..<200 where !peer.webStatus.ready {try await Task.sleep(for:.milliseconds(10))}
        try expect(peer.webStatus.ready)
        let share=try await sharing.start(["sourceID":1],owner:"peer-qa")
        let engine=try ApprovalEngine(paths:AppPaths(directory:directory.appendingPathComponent("gateway")),processReader:{[]})
        defer {engine.stop()};try engine.start(poll:false)
        let gateway=RemoteNetworkService(engine:engine,nodeID:UUID().uuidString,bonjourEnabled:false,discoveryAddresses:{[]},onStatus:{_ in})
        defer {gateway.stop()};try gateway.start(port:0)
        func request(_ method:String,_ path:String,_ body:JSONObject?=nil,_ tag:String?=nil)throws->RemoteHTTPRequest {
            let data=try body.map {try JSONSerialization.data(withJSONObject:$0)} ?? Data()
            let headers=(body==nil ? "":"Content-Type: application/json\r\nContent-Length: \(data.count)\r\n")+(tag.map {"If-None-Match: \($0)\r\n"} ?? "")
            return try RemoteHTTPRequest.parse(Data("\(method) \(path) HTTP/1.1\r\nHost: localhost\r\n\(headers)\r\n".utf8)+data)!
        }
        let added=await gateway.handle(try request("POST","/api/peers",["address":peer.webStatus.loopbackURL!]))
        try expectEqual(added.status,200)
        let id=(try JSONSerialization.jsonObject(with:added.body) as! JSONObject)["id"] as! String
        let route="/api/test-screen?node=\(id)&share=\(share.id)"
        let a=await gateway.handle(try request("GET",route)),b=await gateway.handle(try request("GET",route,nil,a.entityTag))
        if b.status != 304 {throw AppError.message("Peer conditional response \(b.status): "+String(decoding:b.body,as:UTF8.self))}
        try expectEqual(a.status,200);try expectEqual(b.status,304);try expect(b.body.isEmpty)
        try expectEqual(b.entityTag,a.entityTag);try expectEqual(b.nodeID,id);try expect(b.observedAt != nil)
        try sharing.stop(share.id)
        let ended=await gateway.handle(try request("GET",route,nil,a.entityTag))
        try expectEqual(ended.status,410,"A relayed validator must never hide remote revocation")
    }
}
