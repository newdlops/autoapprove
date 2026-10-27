import Foundation
import AppKit
import CoreGraphics
import Security
import CryptoKit

public struct RemoteScreenControlTarget {
    public var identity:String
    public var bounds:CGRect
    public var focused:Bool
    public var occluders:[CGRect]
    public init(identity:String,bounds:CGRect,focused:Bool = true,occluders:[CGRect] = []) {
        self.identity=identity;self.bounds=bounds;self.focused=focused;self.occluders=occluders
    }
    public func point(x:UInt16,y:UInt16) throws ->CGPoint {
        guard [bounds.minX,bounds.minY,bounds.maxX,bounds.maxY,bounds.width,bounds.height].allSatisfy(\.isFinite),bounds.width>0,bounds.height>0 else {throw RemoteHTTPError(410,"공유 대상의 현재 위치를 확인하지 못했습니다.")}
        let point=CGPoint(x:bounds.minX+min(bounds.width*(1-1e-9),Double(x)/65535*bounds.width),y:bounds.minY+min(bounds.height*(1-1e-9),Double(y)/65535*bounds.height))
        guard !occluders.contains(where:{$0.contains(point)}) else {throw RemoteHTTPError(409,"공유한 창이 다른 창에 가려져 있습니다. Mac 전체 화면 공유에서 창을 앞으로 가져온 뒤 다시 조작해주세요.")}
        return point
    }
}

/// Replace the event sink in tests; constructing a Quartz event never posts it.
@MainActor public struct RemoteScreenControlServices {
    public var permission:(Bool)->Bool
    public var target:(TestScreenSource)throws->RemoteScreenControlTarget
    public var post:(CGEvent)throws->Void
    public var frontmostBundle:()->String?
    public var clock:()->TimeInterval
    public init(permission:@escaping(Bool)->Bool,target:@escaping(TestScreenSource)throws->RemoteScreenControlTarget,
                post:@escaping(CGEvent)throws->Void,frontmostBundle:@escaping()->String? = {nil},
                clock:@escaping()->TimeInterval = {ProcessInfo.processInfo.systemUptime}) {
        self.permission=permission;self.target=target;self.post=post;self.frontmostBundle=frontmostBundle;self.clock=clock
    }
    public static var live:Self {
        Self(permission:{_ in CGPreflightPostEventAccess()},target:liveTarget,post:{$0.post(tap:.cghidEventTap)},frontmostBundle:{NSWorkspace.shared.frontmostApplication?.bundleIdentifier})
    }
    private static func liveTarget(_ source:TestScreenSource)throws->RemoteScreenControlTarget {
        if source.scope=="display" {
            guard CGDisplayIsActive(source.id) != 0 else {throw RemoteHTTPError(410,"공유한 디스플레이가 연결 해제되었습니다.")}
            return RemoteScreenControlTarget(identity:"display:\(source.id)",bounds:CGDisplayBounds(source.id))
        }
        guard source.scope=="window",let pid=source.ownerPID,let started=source.ownerStarted,
              let process=try ProcessDiscovery.read(pid:pid).first,process.started==started,
              let app=NSRunningApplication(processIdentifier:pid),!app.isTerminated,app.bundleIdentifier==source.ownerBundleID,
              let windows=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]],
              let index=windows.firstIndex(where:{($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value==source.id}),
              (windows[index][kCGWindowOwnerPID as String] as? NSNumber)?.int32Value==pid,
              (windows[index][kCGWindowAlpha as String] as? Double ?? 1)>0.01,
              let bounds=windowBounds(windows[index]) else {throw RemoteHTTPError(410,"공유한 Mac 창이 닫혔거나 다른 실행으로 바뀌었습니다.")}
        let normal=windows.first {($0[kCGWindowLayer as String] as? Int)==0 && ($0[kCGWindowAlpha as String] as? Double ?? 1)>0.01}
        let focused=NSWorkspace.shared.frontmostApplication?.processIdentifier==pid && (normal?[kCGWindowNumber as String] as? NSNumber)?.uint32Value==source.id
        let covers=windows[..<index].filter {($0[kCGWindowAlpha as String] as? Double ?? 1)>0.01}.compactMap(windowBounds)
        return RemoteScreenControlTarget(identity:"window:\(source.id):\(pid):\(started)",bounds:bounds,focused:focused,occluders:covers)
    }
    private static func windowBounds(_ object:[String:Any])->CGRect? {
        guard let value=object[kCGWindowBounds as String] as? [String:Any],let x=value["X"] as? Double,let y=value["Y"] as? Double,
              let width=value["Width"] as? Double,let height=value["Height"] as? Double,
              [x,y,width,height].allSatisfy(\.isFinite),width>0,height>0 else {return nil}
        return CGRect(x:x,y:y,width:width,height:height)
    }
}

public struct RemoteScreenControlGrant:Encodable {
    public let shareID:String
    public let controlID:String
    public let token:String
    public let streamID:String
    public let timeoutMilliseconds=5000
    public let keyCodes=RemoteScreenInput.keyCodes
    init(shareID:String,controlID:String,token:String) {self.shareID=shareID;self.controlID=controlID;self.token=token;streamID=controlID}
}

/// A short, nonpersistent capability for the one shared pointer/keyboard.
/// Revocation releases held buttons, including when the last HTTP reply is lost.
@MainActor public final class RemoteScreenControl {
    private struct Pressed {var point:CGPoint;var clickCount:Int64}
    private struct Click {var point:CGPoint;var at:TimeInterval;var count:Int64}
    private struct Lease {
        var share:TestScreenShare
        var grant:RemoteScreenControlGrant
        var tokenDigest:SHA256.Digest
        var identity:String
        var seen:TimeInterval
        var sequence:UInt32=0
        var pressed:[UInt8:Pressed]=[:]
        var clicks:[UInt8:Click]=[:]
        var point:CGPoint?
        var rate:[TimeInterval]=[]
    }
    private let services:RemoteScreenControlServices
    private var lease:Lease?
    private var watchdog:Task<Void,Never>?
    private var lastInputAt:TimeInterval?
    private lazy var eventSource=CGEventSource(stateID:.privateState)
    public init(services:RemoteScreenControlServices? = nil) {self.services=services ?? .live}
    public nonisolated static var permissionGranted:Bool {CGPreflightPostEventAccess()}
    @discardableResult public static func requestPermission()->Bool {CGRequestPostEventAccess()}
    public func isControlling(_ id:String)->Bool {expire();return lease?.share.id==id}
    public func hasInputPriority(terminal:TerminalKind)->Bool {
        expire()
        guard let at=lastInputAt else {return false}
        let idle=lease?.pressed.isEmpty==false ? 0:services.clock()-at,bundle=services.frontmostBundle()
        return NativeKeyboardActivity(idleSeconds:{idle},frontmostBundle:{bundle}).hasPriority(terminal:terminal)
    }
    public func begin(share:TestScreenShare,frame:TestScreenFrame?) throws ->RemoteScreenControlGrant {
        expire()
        guard lease==nil else {throw RemoteHTTPError(409,"이 Mac을 다른 화면에서 조작 중입니다. 먼저 조작을 종료해주세요.")}
        try checkFrame(frame,share:share);try checkPermission()
        let target=try services.target(share.source)
        _ = try target.point(x:32768,y:32768)
        let grant=RemoteScreenControlGrant(shareID:share.id,controlID:UUID().uuidString,token:try Self.random())
        lease=Lease(share:share,grant:grant,tokenDigest:SHA256.hash(data:Data(grant.token.utf8)),identity:target.identity,seen:services.clock())
        // Retain the releaser until its short lease ends, even if a viewer or
        // owner is destroyed without its normal shutdown callback.
        watchdog=Task { [self] in
            while !Task.isCancelled {
                do {try await Task.sleep(for:.seconds(1))} catch {return}
                guard !Task.isCancelled,lease != nil else {return};expire()
            }
        }
        return grant
    }
    public func validate(_ object:JSONObject,frame:TestScreenFrame?) throws {
        _ = try validatedTarget(object,frame:frame)
    }
    private func validatedTarget(_ object:JSONObject,frame:TestScreenFrame?) throws ->RemoteScreenControlTarget {
        expire();try authenticate(object)
        guard let current=lease else {throw ended()}
        let target:RemoteScreenControlTarget
        do {try checkFrame(frame,share:current.share);try checkPermission();target=try services.target(current.share.source);guard target.identity==current.identity else {throw ended()}}
        catch {revoke();throw error}
        lease?.seen=services.clock()
        return target
    }
    public func heartbeat(_ object:JSONObject,frame:TestScreenFrame?) throws {try validate(object,frame:frame)}
    public func input(_ object:JSONObject,frame:TestScreenFrame?) throws ->JSONObject {
        let target=try validatedTarget(object,frame:frame)
        guard let raw=object["sequence"] as? NSNumber,CFGetTypeID(raw) != CFBooleanGetTypeID(),raw.doubleValue.rounded()==raw.doubleValue,raw.doubleValue>=1,raw.doubleValue<=Double(UInt32.max),
              let sequence=UInt32(exactly:raw.uint64Value),let current=lease,current.sequence<UInt32.max,sequence==current.sequence+1,
              let text=object["payload"] as? String,text.utf8.count<=11000,let data=Data(base64Encoded:text) else {throw RemoteScreenInput.invalid()}
        let input=try RemoteScreenInput.decode(data),now=services.clock()
        lease?.rate.removeAll {now-$0>=1}
        guard (lease?.rate.count ?? 0)<240 else {revoke();throw RemoteHTTPError(429,"화면 입력이 너무 빠르게 쌓여 조작을 멈췄습니다. 다시 연결해주세요.")}
        lease?.sequence=sequence;lease?.rate.append(now)
        do {try deliver(input,target:target);return ["accepted":true,"sequence":Int(sequence)]}
        catch {revoke();throw error}
    }
    public func end(_ object:JSONObject) throws {expire();guard lease != nil else {return};try authenticate(object);revoke()}
    public func revoke(shareID:String? = nil) {
        guard let current=lease,shareID==nil || current.share.id==shareID else {return}
        lease=nil;watchdog?.cancel();watchdog=nil
        for (button,pressed) in current.pressed {try? postMouse(down:false,button:button,point:current.point ?? pressed.point,flags:[],clickCount:pressed.clickCount)}
    }
    private func expire() {
        if let current=lease,services.clock()-current.seen>=5 || current.share.expiresAt<=Date() {revoke()}
    }
    private func ended()->RemoteHTTPError {RemoteHTTPError(410,"화면 조작 연결이 종료되었습니다. 다시 조작하기를 눌러주세요.")}
    private func checkPermission() throws {
        guard services.permission(false) else {throw RemoteHTTPError(403,"Mac의 연결 설정에서 화면 조작 허용을 누르고, 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 AutoApprove를 허용해주세요.")}
    }
    private func checkFrame(_ frame:TestScreenFrame?,share:TestScreenShare) throws {
        guard share.expiresAt>Date(),let frame,frame.shareID==share.id,(0..<3).contains(Date().timeIntervalSince(frame.observedAt)) else {throw RemoteHTTPError(409,"최신 공유 화면을 받은 뒤 다시 조작해주세요.")}
    }
    private func authenticate(_ object:JSONObject) throws {
        guard let current=lease,object["shareID"] as? String==current.share.id,object["controlID"] as? String==current.grant.controlID,
              let token=object["token"] as? String,token.utf8.count<=128 else {throw ended()}
        let expected=current.tokenDigest,actual=SHA256.hash(data:Data(token.utf8))
        guard zip(expected,actual).reduce(UInt8(0),{$0 | ($1.0 ^ $1.1)})==0 else {throw ended()}
    }
    private func deliver(_ input:RemoteScreenInput,target:RemoteScreenControlTarget) throws {
        guard let current=lease else {throw ended()}
        // No await or callback separates this fresh snapshot from dispatch.
        guard target.identity==current.identity else {throw ended()}
        func point(_ x:UInt16,_ y:UInt16) throws ->CGPoint {try target.point(x:x,y:y)}
        switch input {
        case let .move(x,y,modifiers):
            let location=try point(x,y),button=current.pressed.keys.sorted().first
            let type:CGEventType=button==nil ? .mouseMoved:button==0 ? .leftMouseDragged:button==2 ? .rightMouseDragged:.otherMouseDragged
            guard let event=CGEvent(mouseEventSource:eventSource,mouseType:type,mouseCursorPosition:location,mouseButton:Self.mouseButton(button ?? 0)) else {throw eventFailure()}
            event.flags=Self.flags(modifiers);try post(event);lease?.point=location
            if button != nil {lastInputAt=services.clock()}
        case let .button(down,button,x,y,modifiers):
            let location=try point(x,y)
            if down {
                guard current.pressed[button]==nil else {throw RemoteScreenInput.invalid()}
                let previous=current.clicks[button],now=services.clock()
                let repeated=previous.map {now-$0.at<NSEvent.doubleClickInterval && hypot(location.x-$0.point.x,location.y-$0.point.y)<5} ?? false
                let count=repeated ? min(3,(previous?.count ?? 0)+1):1
                // Reserve before posting; cleanup also covers a partial native failure.
                lease?.pressed[button]=Pressed(point:location,clickCount:count)
                try postMouse(down:true,button:button,point:location,flags:Self.flags(modifiers),clickCount:count)
            } else {
                guard let pressed=current.pressed[button] else {throw RemoteScreenInput.invalid()}
                try postMouse(down:false,button:button,point:location,flags:Self.flags(modifiers),clickCount:pressed.clickCount)
                lease?.pressed.removeValue(forKey:button)
                if hypot(location.x-pressed.point.x,location.y-pressed.point.y)<5 {lease?.clicks[button]=Click(point:location,at:services.clock(),count:pressed.clickCount)}
                else {lease?.clicks.removeValue(forKey:button)}
            }
            lease?.point=location;lastInputAt=services.clock()
        case let .scroll(x,y,dx,dy,modifiers):
            let location=try point(x,y)
            guard let event=CGEvent(scrollWheelEvent2Source:eventSource,units:.pixel,wheelCount:2,wheel1:-Int32(dy),wheel2:-Int32(dx),wheel3:0) else {throw eventFailure()}
            event.location=location;event.flags=Self.flags(modifiers);try post(event);lastInputAt=services.clock()
        case let .text(value):
            guard target.focused else {throw RemoteHTTPError(409,"공유한 창을 먼저 클릭해 선택한 뒤 키보드를 입력해주세요.")}
            var units:[UniChar]=[]
            func flush() throws {if !units.isEmpty {try key(code:0,flags:[],unicode:units);units.removeAll(keepingCapacity:true)}}
            for scalar in value.unicodeScalars {
                let next=Array(String(scalar).utf16);if units.count+next.count>20 {try flush()};units.append(contentsOf:next)
            }
            try flush();lastInputAt=services.clock()
        case let .key(code,modifiers):
            guard target.focused else {throw RemoteHTTPError(409,"공유한 창을 먼저 클릭해 선택한 뒤 키보드를 입력해주세요.")}
            try key(code:code,flags:Self.flags(modifiers));lastInputAt=services.clock()
        case .release:
            for (button,pressed) in current.pressed {try postMouse(down:false,button:button,point:current.point ?? pressed.point,flags:[],clickCount:pressed.clickCount)}
            lease?.pressed.removeAll()
        }
    }
    private func key(code:UInt16,flags:CGEventFlags,unicode:[UniChar]? = nil) throws {
        guard let down=CGEvent(keyboardEventSource:eventSource,virtualKey:code,keyDown:true),let up=CGEvent(keyboardEventSource:eventSource,virtualKey:code,keyDown:false) else {throw eventFailure()}
        down.flags=flags;up.flags=flags
        if let unicode {unicode.withUnsafeBufferPointer {down.keyboardSetUnicodeString(stringLength:$0.count,unicodeString:$0.baseAddress);up.keyboardSetUnicodeString(stringLength:$0.count,unicodeString:$0.baseAddress)}}
        do {try post(down);try post(up)} catch {try? post(up);throw error}
    }
    private func postMouse(down:Bool,button:UInt8,point:CGPoint,flags:CGEventFlags,clickCount:Int64) throws {
        let type:CGEventType=button==0 ? (down ? .leftMouseDown:.leftMouseUp):button==2 ? (down ? .rightMouseDown:.rightMouseUp):(down ? .otherMouseDown:.otherMouseUp)
        guard let event=CGEvent(mouseEventSource:eventSource,mouseType:type,mouseCursorPosition:point,mouseButton:Self.mouseButton(button)) else {throw eventFailure()}
        event.flags=flags;event.setIntegerValueField(.mouseEventClickState,value:clickCount);try post(event)
    }
    private func post(_ event:CGEvent) throws {event.setIntegerValueField(.eventSourceUserData,value:0x41415343);try services.post(event)}
    private func eventFailure()->RemoteHTTPError {RemoteHTTPError(503,"Mac에 화면 조작 입력을 만들지 못했습니다. 다시 연결해주세요.")}
    private static func mouseButton(_ value:UInt8)->CGMouseButton {value==0 ? .left:value==2 ? .right:.center}
    private static func flags(_ value:UInt8)->CGEventFlags {
        var flags=CGEventFlags();for (bit,flag) in [(UInt8(1),CGEventFlags.maskShift),(2,.maskControl),(4,.maskAlternate),(8,.maskCommand)] where value & bit != 0 {flags.insert(flag)};return flags
    }
    private static func random() throws ->String {
        var bytes=[UInt8](repeating:0,count:32)
        guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes)==errSecSuccess else {throw RemoteHTTPError(503,"화면 조작 연결을 만들지 못했습니다.")}
        return Data(bytes).base64EncodedString()
    }
}
