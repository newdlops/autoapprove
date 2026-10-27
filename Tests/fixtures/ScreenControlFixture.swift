import Foundation
import AutoApproveCore
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// All sources and targets are synthetic. Quartz events are inspected, never posted.
@MainActor final class ScreenControlPreviewProbe {
    let root:URL
    var serial=0
    var text=""
    init(_ root:URL) {self.root=root}
    func flag(_ name:String)->Bool {FileManager.default.fileExists(atPath:root.appendingPathComponent(name).path)}
    func record(_ event:CGEvent) throws {
        if flag("fail-native-once") {try FileManager.default.removeItem(at:root.appendingPathComponent("fail-native-once"));throw AppError.message("Synthetic native failure")}
        serial+=1
        var row:JSONObject=["serial":serial,"type":Int(event.type.rawValue),"flags":event.flags.rawValue]
        if [.keyDown,.keyUp].contains(event.type) {
            row["keyCode"]=event.getIntegerValueField(.keyboardEventKeycode)
            var count=0;event.keyboardGetUnicodeString(maxStringLength:0,actualStringLength:&count,unicodeString:nil)
            if count>0 {
                var units=[UniChar](repeating:0,count:count),written=0
                units.withUnsafeMutableBufferPointer {event.keyboardGetUnicodeString(maxStringLength:$0.count,actualStringLength:&written,unicodeString:$0.baseAddress)}
                let value=String(decoding:units.prefix(written),as:UTF16.self);row["text"]=value
                if event.type == .keyDown {text+=value;try Data(text.utf8).write(to:root.appendingPathComponent("typed.txt"),options:.atomic)}
            }
        } else {
            row["x"]=event.location.x;row["y"]=event.location.y
            row["clickCount"]=event.getIntegerValueField(.mouseEventClickState)
            if event.type == .scrollWheel {row["deltaX"]=event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2);row["deltaY"]=event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)}
        }
        let log=root.appendingPathComponent("screen-events.ndjson")
        if !FileManager.default.fileExists(atPath:log.path) {FileManager.default.createFile(atPath:log.path,contents:Data())}
        let handle=try FileHandle(forWritingTo:log);defer {try? handle.close()};try handle.seekToEnd()
        var data=try JSONSerialization.data(withJSONObject:row);data.append(10);try handle.write(contentsOf:data)
    }
    func services()->RemoteScreenControlServices {
        RemoteScreenControlServices(permission:{_ in !self.flag("control-denied")},target:{source in
            if self.flag("source-gone") {throw RemoteHTTPError(410,"합성 공유 대상이 종료되었습니다.")}
            let generation=self.flag("source-changed") ? "changed":"initial"
            return RemoteScreenControlTarget(identity:"\(source.scope):\(source.id):\(generation)",bounds:source.scope=="display" ? CGRect(x:-1920,y:-200,width:1920,height:1080):CGRect(x:200,y:100,width:800,height:500),focused:!self.flag("focus-denied"))
        },post:{try self.record($0)},frontmostBundle:{"com.apple.Terminal"})
    }
    func image(_ source:TestScreenSource) throws ->TerminalNativeImage {
        if flag("capture-denied") {throw RemoteHTTPError(403,"합성 화면 녹음 권한이 해제되었습니다.")}
        let width=source.scope=="display" ? 960:800,height=source.scope=="display" ? 540:500
        let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red:0.08,green:0.12,blue:0.18,alpha:1));context.fill(CGRect(x:0,y:0,width:width,height:height))
        for (x,y,color) in [(0,0,CGColor(red:0.2,green:0.5,blue:0.8,alpha:1)),(width-100,0,CGColor(red:0.3,green:0.7,blue:0.4,alpha:1)),(0,height-100,CGColor(red:0.7,green:0.4,blue:0.2,alpha:1))] {
            context.setFillColor(color);context.fill(CGRect(x:x,y:y,width:100,height:100))
        }
        let font=CTFontCreateWithName("Helvetica" as CFString,22,nil)
        let message=NSAttributedString(string:"SYNTHETIC TARGET ONLY  ·  \(serial) events\n"+String(text.suffix(50)),attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:1,alpha:1)])
        context.textPosition=CGPoint(x:120,y:height/2);CTLineDraw(CTLineCreateWithAttributedString(message),context)
        let bytes=NSMutableData(),destination=CGImageDestinationCreateWithData(bytes,UTType.jpeg.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(destination,context.makeImage()!,[kCGImageDestinationLossyCompressionQuality:0.65] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {throw AppError.message("Synthetic image encoding failed")}
        return TerminalNativeImage(data:(bytes as Data).base64EncodedString(),width:width,height:height)
    }
}
