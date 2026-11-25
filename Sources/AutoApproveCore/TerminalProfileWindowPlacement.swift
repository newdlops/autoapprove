import CoreGraphics
import Foundation

extension TerminalWindowBounds {
    var profileRect: CGRect? {
        guard [x, y, width, height].allSatisfy(\.isFinite),
              abs(x) <= 131072, abs(y) <= 131072,
              (1...32767).contains(width), (1...32767).contains(height) else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

enum TerminalProfileWindowPlacement {
    static func frames(_ windows: [[String: Any]], owner: Int32) -> [UInt32: TerminalWindowBounds] {
        var result: [UInt32: TerminalWindowBounds] = [:]
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == owner,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let rect = TerminalCursorReader.windowBounds(window) else { continue }
            let frame = TerminalWindowBounds(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
            if frame.profileRect != nil { result[id] = frame }
        }
        return result
    }

    static func displays() -> [CGRect] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 64)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    static func fit(_ saved: TerminalWindowBounds, displays: [CGRect]) -> CGRect? {
        guard let rect = saved.profileRect, let primary = displays.first else { return nil }
        var screen = primary, area: CGFloat = 0
        for display in displays {
            let overlap = display.intersection(rect)
            if !overlap.isNull, overlap.width * overlap.height > area {
                screen = display
                area = overlap.width * overlap.height
            }
        }
        let width = min(rect.width, screen.width), height = min(rect.height, screen.height)
        return CGRect(x: min(max(rect.minX, screen.minX), screen.maxX - width),
                      y: min(max(rect.minY, screen.minY), screen.maxY - height),
                      width: width, height: height)
    }
}
