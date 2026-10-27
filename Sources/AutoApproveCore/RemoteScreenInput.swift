import Foundation

/// Small, ordered input records. Coordinates are fractions of the actual image,
/// independent of its JPEG size, browser zoom and Retina backing scale.
public enum RemoteScreenInput: Equatable, Sendable {
    case move(x:UInt16,y:UInt16,modifiers:UInt8)
    case button(down:Bool,button:UInt8,x:UInt16,y:UInt16,modifiers:UInt8)
    case scroll(x:UInt16,y:UInt16,deltaX:Int16,deltaY:Int16,modifiers:UInt8)
    case text(String)
    case key(code:UInt16,modifiers:UInt8)
    case release

    public static let maximumTextBytes=8000
    public static let keyCodes:[String:UInt16]=[
        "KeyA":0,"KeyS":1,"KeyD":2,"KeyF":3,"KeyH":4,"KeyG":5,"KeyZ":6,"KeyX":7,"KeyC":8,"KeyV":9,"IntlBackslash":10,
        "KeyB":11,"KeyQ":12,"KeyW":13,"KeyE":14,"KeyR":15,"KeyY":16,"KeyT":17,"Digit1":18,"Digit2":19,"Digit3":20,
        "Digit4":21,"Digit6":22,"Digit5":23,"Equal":24,"Digit9":25,"Digit7":26,"Minus":27,"Digit8":28,"Digit0":29,
        "BracketRight":30,"KeyO":31,"KeyU":32,"BracketLeft":33,"KeyI":34,"KeyP":35,"Enter":36,"KeyL":37,"KeyJ":38,
        "Quote":39,"KeyK":40,"Semicolon":41,"Backslash":42,"Comma":43,"Slash":44,"KeyN":45,"KeyM":46,"Period":47,
        "Tab":48,"Space":49,"Backquote":50,"Backspace":51,"Escape":53,"F17":64,"NumpadDecimal":65,"NumpadMultiply":67,
        "NumpadAdd":69,"NumLock":71,"NumpadDivide":75,"NumpadEnter":76,"NumpadSubtract":78,"F18":79,"F19":80,
        "NumpadEqual":81,"Numpad0":82,"Numpad1":83,"Numpad2":84,"Numpad3":85,"Numpad4":86,"Numpad5":87,"Numpad6":88,
        "Numpad7":89,"F20":90,"Numpad8":91,"Numpad9":92,"F5":96,"F6":97,"F7":98,"F3":99,"F8":100,"F9":101,
        "F11":103,"F13":105,"F16":106,"F14":107,"F10":109,"F12":111,"F15":113,"Insert":114,"Home":115,
        "PageUp":116,"Delete":117,"F4":118,"End":119,"F2":120,"PageDown":121,"F1":122,"ArrowLeft":123,
        "ArrowRight":124,"ArrowDown":125,"ArrowUp":126
    ]
    private static let allowedKeys=Set(keyCodes.values)
    static func invalid()->RemoteHTTPError {RemoteHTTPError(400,"화면 조작 입력의 형식이나 크기를 확인하지 못했습니다.")}
    public static func decode(_ data:Data) throws -> Self {
        guard (1...maximumTextBytes+1).contains(data.count),let kind=data.first else {throw invalid()}
        let bytes=[UInt8](data)
        func word(_ offset:Int)->UInt16 {UInt16(bytes[offset]) << 8 | UInt16(bytes[offset+1])}
        func flags(_ offset:Int) throws ->UInt8 {guard bytes[offset]<16 else {throw invalid()};return bytes[offset]}
        switch kind {
        case 0:
            guard bytes.count==6 else {throw invalid()}
            return try .move(x:word(1),y:word(3),modifiers:flags(5))
        case 1,2:
            guard bytes.count==7,bytes[1]<3 else {throw invalid()}
            return try .button(down:kind==1,button:bytes[1],x:word(2),y:word(4),modifiers:flags(6))
        case 3:
            guard bytes.count==10 else {throw invalid()}
            let dx=Int16(bitPattern:word(5)),dy=Int16(bitPattern:word(7))
            guard (-2000...2000).contains(Int(dx)),(-2000...2000).contains(Int(dy)),dx != 0 || dy != 0 else {throw invalid()}
            return try .scroll(x:word(1),y:word(3),deltaX:dx,deltaY:dy,modifiers:flags(9))
        case 4:
            guard bytes.count>1,let value=String(data:data.dropFirst(),encoding:.utf8),!value.utf8.contains(0) else {throw invalid()}
            return .text(value)
        case 5:
            guard bytes.count==4,allowedKeys.contains(word(2)) else {throw invalid()}
            return try .key(code:word(2),modifiers:flags(1))
        case 6:
            guard bytes.count==1 else {throw invalid()};return .release
        default:throw invalid()
        }
    }
    public func encoded() throws -> Data {
        func word(_ value:UInt16)->[UInt8] {[UInt8(value >> 8),UInt8(truncatingIfNeeded:value)]}
        let bytes:[UInt8]
        switch self {
        case let .move(x,y,flags):bytes=[0]+word(x)+word(y)+[flags]
        case let .button(down,button,x,y,flags):bytes=[down ? 1:2,button]+word(x)+word(y)+[flags]
        case let .scroll(x,y,dx,dy,flags):bytes=[3]+word(x)+word(y)+word(UInt16(bitPattern:dx))+word(UInt16(bitPattern:dy))+[flags]
        case let .text(value):bytes=[4]+Array(value.utf8)
        case let .key(code,flags):bytes=[5,flags]+word(code)
        case .release:bytes=[6]
        }
        let result=Data(bytes);_ = try Self.decode(result);return result
    }
}
