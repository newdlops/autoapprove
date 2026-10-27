import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AutoApproveCore

private final class ScreenApprovalCounter:@unchecked Sendable {
    private let lock=NSLock()
    private var calls=0
    func send()->TerminalDelivery {lock.lock();defer {lock.unlock()};calls+=1;return .sent}
    var count:Int {lock.lock();defer {lock.unlock()};return calls}
}
@MainActor private final class ScreenControlProbe {
    var allowed=true
    var clock:TimeInterval=0
    var bundle:String?="com.apple.Terminal"
    var target=RemoteScreenControlTarget(identity:"display-generation-1",bounds:CGRect(x:-1920,y:-200,width:1920,height:1080))
    var events:[CGEvent]=[]
    var failOnceAt:Int?
    var targetReads=0
    func services()->RemoteScreenControlServices {
        RemoteScreenControlServices(permission:{_ in self.allowed},target:{_ in self.targetReads+=1;return self.target},post:{event in
            if self.failOnceAt==self.events.count {self.failOnceAt=nil;throw AppError.message("synthetic native sink failure")}
            self.events.append(event)
        },frontmostBundle:{self.bundle},clock:{self.clock})
    }
}
@MainActor private struct ScreenControlFixture {
    let probe:ScreenControlProbe
    let control:RemoteScreenControl
    let sharing:TestScreenSharing
    let share:TestScreenShare
    let frame:TestScreenFrame
    static func make() async throws ->Self {
        let probe=ScreenControlProbe(),control=RemoteScreenControl(services:probe.services())
        let source=TestScreenSource(id:1,scope:"display",title:"Synthetic screen only",width:1920,height:1080)
        let context=CGContext(data:nil,width:8,height:8,bitsPerComponent:8,bytesPerRow:32,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray:0.25,alpha:1));context.fill(CGRect(x:0,y:0,width:8,height:8))
        let bytes=NSMutableData(),destination=CGImageDestinationCreateWithData(bytes,UTType.jpeg.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(destination,context.makeImage()!,nil);try expect(CGImageDestinationFinalize(destination))
        let image=TerminalNativeImage(data:(bytes as Data).base64EncodedString(),width:8,height:8)
        let sharing=TestScreenSharing(permission:{_ in true},sources:{[source]},capture:{_ in image},remoteControl:control)
        let share=try await sharing.start(["sourceID":1],owner:"screen-control-qa"),frame=try await sharing.frame(share.id)
        return Self(probe:probe,control:control,sharing:sharing,share:share,frame:frame)
    }
    func begin() throws ->RemoteScreenControlGrant {try sharing.beginControl(["shareID":share.id])}
    func credentials(_ grant:RemoteScreenControlGrant)->JSONObject {["shareID":share.id,"controlID":grant.controlID,"token":grant.token]}
    @discardableResult func send(_ input:RemoteScreenInput,_ sequence:Int,grant:RemoteScreenControlGrant) throws ->JSONObject {
        var object=credentials(grant);object["sequence"]=sequence;object["payload"]=try input.encoded().base64EncodedString()
        return try sharing.screenInput(object)
    }
}

extension ApprovalTests {
    func testScreenControlUsesOneFreshTargetWithoutCachingAcrossInputs() async throws {
        let f=try await ScreenControlFixture.make();defer {f.control.revoke()};let grant=try f.begin(),before=f.probe.targetReads
        try f.send(.move(x:0,y:0,modifiers:0),1,grant:grant)
        try expectEqual(f.probe.targetReads-before,1)
        f.probe.target.bounds=CGRect(x:100,y:200,width:800,height:600)
        try f.send(.move(x:0,y:0,modifiers:0),2,grant:grant)
        try expectEqual(f.probe.events.last?.location,CGPoint(x:100,y:200));try expectEqual(f.probe.targetReads-before,2)
        f.probe.target.focused=false
        try expectThrows(try f.send(.text("must not reach the changed focus"),3,grant:grant))
        try expectEqual(f.probe.events.count,2);try expectFalse(f.control.isControlling(f.share.id))
    }
    func testScreenControlBinaryCoordinatesAndValidation() throws {
        let values:[RemoteScreenInput]=[.move(x:0,y:65535,modifiers:15),.button(down:true,button:0,x:123,y:456,modifiers:0),
            .button(down:false,button:2,x:65535,y:0,modifiers:8),.scroll(x:1000,y:2000,deltaX:-2000,deltaY:2000,modifiers:4),
            .text("한글 e\u{301} 👨‍👩‍👧‍👦"),.key(code:0,modifiers:8),.release]
        for value in values {try expectEqual(RemoteScreenInput.decode(value.encoded()),value)}
        try expectEqual(try values[0].encoded(),Data([0,0,0,255,255,15]))
        try expectEqual(try values[3].encoded(),Data([3,3,232,7,208,248,48,7,208,4]))
        for bytes in [Data(),Data([99]),Data([0,0,0,0,0,16]),Data([1,3,0,0,0,0,0]),Data([3,0,0,0,0,0,0,0,0,0]),
                      Data([5,0,255,255]),Data([5,16,0,0]),Data([4,0]),Data([4,255]),Data([6,0]),Data(repeating:4,count:8002)] {
            try expectThrows(try RemoteScreenInput.decode(bytes))
        }
        let target=RemoteScreenControlTarget(identity:"retina-display",bounds:CGRect(x:-1920,y:-200,width:1920,height:1080))
        let point=try target.point(x:32768,y:32768)
        try expect(abs(point.x+960)<0.02);try expect(abs(point.y-340)<0.02)
        try expect(target.bounds.contains(try target.point(x:65535,y:65535)))
        try expectThrows(try RemoteScreenControlTarget(identity:"bad",bounds:CGRect(x:0,y:0,width:0,height:100)).point(x:0,y:0))
        try expectThrows(try RemoteScreenControlTarget(identity:"covered",bounds:target.bounds,occluders:[target.bounds]).point(x:32768,y:32768))
    }
    func testScreenControlRequiresFreshExplicitCapabilityAndPermission() async throws {
        let f=try await ScreenControlFixture.make();defer {f.control.revoke()}
        try expect(f.probe.events.isEmpty)
        try expectThrows(try f.control.begin(share:f.share,frame:nil))
        var stale=f.frame;stale.observedAt=Date().addingTimeInterval(-4)
        try expectThrows(try f.control.begin(share:f.share,frame:stale))
        f.probe.allowed=false
        try expectThrows(try f.begin());try expect(f.probe.events.isEmpty)
        f.probe.allowed=true;let grant=try f.begin()
        try expectEqual(Data(base64Encoded:grant.token)?.count,32);try expectEqual(grant.streamID,grant.controlID)
        try expectThrows(try f.begin())
        var foreign=f.credentials(grant);foreign["token"]=String(repeating:"a",count:44)
        try expectThrows(try f.control.end(foreign));try expect(f.control.isControlling(f.share.id))
        try f.send(.move(x:0,y:0,modifiers:0),1,grant:grant)
        try expectThrows(try f.send(.move(x:0,y:0,modifiers:0),1,grant:grant))
        try expectEqual(f.probe.events.count,1)
        var boolean=f.credentials(grant);boolean["sequence"]=true;boolean["payload"]=try RemoteScreenInput.release.encoded().base64EncodedString()
        try expectThrows(try f.sharing.screenInput(boolean))
        try f.control.end(f.credentials(grant));try expectFalse(f.control.isControlling(f.share.id))
    }
    func testScreenControlNativePointerDragWheelAndRelease() async throws {
        let f=try await ScreenControlFixture.make();defer {f.control.revoke()};let grant=try f.begin()
        try f.send(.button(down:true,button:0,x:32768,y:32768,modifiers:1),1,grant:grant)
        try f.send(.move(x:40000,y:35000,modifiers:1),2,grant:grant)
        try f.send(.button(down:false,button:0,x:40000,y:35000,modifiers:1),3,grant:grant)
        try expectEqual(f.probe.events.map(\.type),[.leftMouseDown,.leftMouseDragged,.leftMouseUp])
        try expect(f.probe.events[0].flags.contains(.maskShift));try expect(abs(f.probe.events[0].location.x+960)<0.02)
        f.probe.clock=0.1
        try f.send(.button(down:true,button:0,x:40000,y:35000,modifiers:0),4,grant:grant)
        try expectEqual(f.probe.events.last?.getIntegerValueField(.mouseEventClickState),1,"A drag must not become a double-click")
        try f.send(.button(down:false,button:0,x:40000,y:35000,modifiers:0),5,grant:grant)
        try f.send(.button(down:true,button:0,x:40000,y:35000,modifiers:0),6,grant:grant)
        try expectEqual(f.probe.events.last?.getIntegerValueField(.mouseEventClickState),2)
        try f.send(.release,7,grant:grant);try expectEqual(f.probe.events.last?.type,.leftMouseUp)
        try f.send(.button(down:true,button:2,x:32768,y:32768,modifiers:0),8,grant:grant)
        try expectEqual(f.probe.events.last?.type,.rightMouseDown)
        try f.send(.scroll(x:32768,y:32768,deltaX:30,deltaY:-40,modifiers:4),9,grant:grant)
        let wheel=f.probe.events.last!;try expectEqual(wheel.type,.scrollWheel);try expect(wheel.flags.contains(.maskAlternate))
        try expectEqual(wheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),40)
        try expectEqual(wheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis2),-30)
        f.control.revoke();try expectEqual(f.probe.events.last?.type,.rightMouseUp)
        let count=f.probe.events.count;f.control.revoke();try expectEqual(f.probe.events.count,count)
    }
    func testScreenControlUnicodeChunksAndAtomicShortcut() async throws {
        let f=try await ScreenControlFixture.make();defer {f.control.revoke()};let grant=try f.begin()
        let value="한글 e\u{301} 🙂 "+String(repeating:"🧑🏽‍💻가",count:8)
        try f.send(.text(value),1,grant:grant)
        var joined=[UniChar]()
        for event in f.probe.events.filter({$0.type == .keyDown}) {
            var count=0;event.keyboardGetUnicodeString(maxStringLength:0,actualStringLength:&count,unicodeString:nil)
            try expect((1...20).contains(count));var units=[UniChar](repeating:0,count:count)
            var written=0
            units.withUnsafeMutableBufferPointer {event.keyboardGetUnicodeString(maxStringLength:$0.count,actualStringLength:&written,unicodeString:$0.baseAddress)}
            try expectEqual(written,count)
            try expectFalse((0xdc00...0xdfff).contains(units.first!));try expectFalse((0xd800...0xdbff).contains(units.last!));joined.append(contentsOf:units)
        }
        try expectEqual(String(decoding:joined,as:UTF16.self),value)
        try expectEqual(f.probe.events.filter {$0.type == .keyDown}.count,f.probe.events.filter {$0.type == .keyUp}.count)
        try f.send(.key(code:RemoteScreenInput.keyCodes["KeyS"]!,modifiers:8),2,grant:grant)
        let keys=Array(f.probe.events.suffix(2));try expectEqual(keys.map(\.type),[.keyDown,.keyUp])
        try expect(keys.allSatisfy {$0.flags.contains(.maskCommand)&&$0.getIntegerValueField(.keyboardEventKeycode)==1})
        try expect(f.control.hasInputPriority(terminal:.terminal));try expectFalse(f.control.hasInputPriority(terminal:.iterm))
        f.probe.bundle="com.apple.Safari";try expectFalse(f.control.hasInputPriority(terminal:.terminal))
        f.probe.bundle="com.apple.Terminal";f.probe.clock=1.3;try expectFalse(f.control.hasInputPriority(terminal:.terminal))
    }
    func testScreenControlRevokesOnExpiryOwnerChangeAndStop() async throws {
        let f=try await ScreenControlFixture.make();defer {f.control.revoke()};var grant=try f.begin()
        try f.send(.button(down:true,button:0,x:100,y:100,modifiers:0),1,grant:grant)
        f.probe.clock=4;try expect(f.control.hasInputPriority(terminal:.terminal));_ = try f.sharing.heartbeatControl(f.credentials(grant));f.probe.clock=8
        try expect(f.control.isControlling(f.share.id));f.probe.clock=10
        try expectFalse(f.control.isControlling(f.share.id));try expectEqual(f.probe.events.last?.type,.leftMouseUp)
        grant=try f.begin();try f.send(.button(down:true,button:0,x:100,y:100,modifiers:0),1,grant:grant)
        f.probe.target.identity="reused-owner"
        try expectThrows(try f.send(.move(x:200,y:200,modifiers:0),2,grant:grant));try expectEqual(f.probe.events.last?.type,.leftMouseUp)
        try expectFalse(f.control.isControlling(f.share.id))
        grant=try f.begin();f.sharing.stopAll(owner:"unrelated-owner");try expect(f.control.isControlling(f.share.id))
        try f.send(.button(down:true,button:1,x:200,y:200,modifiers:0),1,grant:grant)
        f.sharing.stopAll(owner:"screen-control-qa");try expectFalse(f.control.isControlling(f.share.id));try expectEqual(f.probe.events.last?.type,.otherMouseUp)
    }
    func testScreenControlFocusFailureAndFloodNeverReplay() async throws {
        let f=try await ScreenControlFixture.make();defer {f.control.revoke()};var grant=try f.begin()
        f.probe.target.focused=false
        try expectThrows(try f.send(.text("must not reach another window"),1,grant:grant));try expect(f.probe.events.isEmpty)
        f.probe.target.focused=true;grant=try f.begin();f.probe.failOnceAt=1
        try expectThrows(try f.send(.key(code:0,modifiers:8),1,grant:grant))
        try expectEqual(f.probe.events.map(\.type),[.keyDown,.keyUp]);try expectFalse(f.control.isControlling(f.share.id))
        try expectThrows(try f.send(.key(code:0,modifiers:8),1,grant:grant));try expectEqual(f.probe.events.count,2)
        grant=try f.begin()
        for sequence in 1...240 {try f.send(.release,sequence,grant:grant)}
        do {try f.send(.release,241,grant:grant);throw AppError.message("Unbounded native input accepted")}
        catch let error as RemoteHTTPError {try expectEqual(error.status,429)}
        try expectFalse(f.control.isControlling(f.share.id))
    }
    func testScreenControlTypingYieldsAutomationOnlyInItsTerminalHost() async throws {
        let f=try await ScreenControlFixture.make(),counter=ScreenApprovalCounter()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-screen-priority-"+UUID().uuidString)
        let records=ProcessDiscovery.parse("82001 1 ttys891 82001 82001 Mon Sep 21 09:00:00 2026 /usr/local/bin/codex")
        var session=AgentSession(id:records[0].key,agent:.codex,pid:82001,started:records[0].started,tty:"/dev/ttys891",cwd:"/tmp/synthetic-screen-priority",terminal:.iterm)
        session.channel = .itermScreen
        let adapter=ScreenHostAdapter(screens:{_ in TerminalSnapshot()},approve:{_,_,_ in counter.send()},reveal:{_ in nil})
        let engine=try ApprovalEngine(paths:AppPaths(directory:root),processReader:{records},screenAdapters:[.iterm:adapter],testScreenSharing:f.sharing,nativeKeyboardActivity:.inactive)
        defer {engine.stop();f.control.revoke();try? FileManager.default.removeItem(at:root)}
        engine.updateDiscovery([session],records:records);try engine.setAutomatic(session.id,enabled:true)
        let grant=try f.begin();f.probe.bundle=ScreenHost.iterm.bundleID
        try f.send(.text("synthetic remote typing"),1,grant:grant)
        func prompt(_ command:String)->String {"Would you like to run the following command?\n\n  $ \(command)\n\n› 1. Yes\n  2. No\n\nEnter to confirm or esc to cancel"}
        for _ in 0..<8 {engine.receiveScreen(sessionID:session.id,raw:prompt("echo screen-input"),generation:"screen-input");try await Task.sleep(for:.milliseconds(10))}
        try expectEqual(counter.count,0,"Automatic Enter must yield while the same terminal is being controlled")
        try expect(engine.snapshot.sessions.first?.automatic==true)
        f.probe.clock=1.3;engine.receiveScreen(sessionID:session.id,raw:prompt("echo screen-input"),generation:"screen-input")
        for _ in 0..<150 where counter.count<1 {try await Task.sleep(for:.milliseconds(10))}
        try expectEqual(counter.count,1)
        _ = try await f.sharing.frame(f.share.id)
        f.probe.bundle="com.apple.Safari";try f.send(.text("another application"),2,grant:grant)
        engine.receiveScreen(sessionID:session.id,raw:prompt("echo background-input"),generation:"screen-input")
        for _ in 0..<150 where counter.count<2 {try await Task.sleep(for:.milliseconds(10))}
        try expectEqual(counter.count,2,"Screen input in another application must preserve background approvals")
    }
}
