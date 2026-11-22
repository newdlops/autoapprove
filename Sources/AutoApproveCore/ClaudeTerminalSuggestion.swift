import AppKit
import ApplicationServices
import ScreenCaptureKit

package enum ClaudeTerminalSuggestion {
    package static func matchesInk(marker: (background: Int, peak: Int), text: (background: Int, peak: Int), hint: (background: Int, peak: Int)) -> Bool {
        let contrast = marker.peak - marker.background
        guard abs(contrast) >= 90, abs(hint.background - text.background) <= 8,
              abs(hint.peak - text.peak) <= 12, abs(marker.background - text.background) <= 8 else { return false }
        return (0.4...0.78).contains(Double(text.peak - text.background) / Double(contrast))
    }

    private struct Geometry: Equatable {
        let marker: CGRect
        let hint: CGRect
        let body: CGRect
    }

    private static func geometry(_ screen: String, body: String, windowID: UInt32) -> Geometry? {
        var result: Geometry?, inspected = 0
        let snapshot = TerminalCursorReader.snapshot(screen: screen, windowID: windowID, title: nil) { element, value, cursor in
            inspected += 1
            let ns = value as NSString
            let marker = ns.range(of: "❯", options: .backwards)
            guard marker.location != NSNotFound else { return }
            let line = ns.lineRange(for: marker)
            let content = ns.range(of: body, options: .literal, range: line)
            guard content.location == cursor, content.location == marker.location + 2,
                  content.length > 1, ClaudeComposerReadiness.framedCandidate(String(value.suffix(4096))) == body else { return }
            func bounds(_ range: NSRange) -> CGRect? {
                var r = CFRange(location: range.location, length: range.length)
                var value: CFTypeRef?, rect = CGRect.zero
                guard let parameter = AXValueCreate(.cfRange, &r),
                      AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
                      let value, CFGetTypeID(value) == AXValueGetTypeID(),
                      AXValueGetValue(value as! AXValue, .cgRect, &rect), !rect.isEmpty else { return nil }
                return rect
            }
            let first = ns.rangeOfComposedCharacterSequence(at: cursor)
            let rest = NSRange(location: NSMaxRange(first), length: NSMaxRange(content) - NSMaxRange(first))
            guard rest.length > 0, let mark = bounds(marker), let text = bounds(rest),
                  abs(mark.minY - text.minY) < 1, abs(mark.height - text.height) < 1,
                  text.minX > mark.maxX else { return }
            let footer = NSRange(location: NSMaxRange(line), length: ns.length - NSMaxRange(line))
            for hint in ["shift+tab to cycle", "? for shortcuts"] {
                let reference = ns.range(of: hint, options: .backwards, range: footer)
                if reference.location != NSNotFound, let rect = bounds(reference), rect.minY > text.minY {
                    result = Geometry(marker: mark, hint: rect, body: text)
                    break
                }
            }
        }
        guard inspected == 1, let snapshot, ClaudeComposerReadiness.framedCandidate(snapshot.screen) == body else { return nil }
        return result
    }

    static func matches(screen: String, tty: String) async -> Bool {
        guard let body = ClaudeComposerReadiness.framedCandidate(screen),
              AXIsProcessTrusted(), CGPreflightScreenCaptureAccess(),
              let metadata = try? TerminalAppleEvents.profileWindowMetadata(tty: tty), metadata.selected, !metadata.minimized,
              let before = geometry(screen, body: body, windowID: metadata.windowID),
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.windowID == metadata.windowID && $0.owningApplication?.processID == metadata.ownerPID }),
              window.frame.contains(before.body), window.frame.contains(before.marker), window.frame.contains(before.hint) else { return false }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int((window.frame.width * scale).rounded())
        config.height = Int((window.frame.height * scale).rounded())
        guard (1...8192).contains(config.width), (1...8192).contains(config.height),
              config.width * config.height <= 16_777_216 else { return false }
        config.ignoreShadowsSingleWindow = true
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return false }
        func ink(_ rect: CGRect) -> (background: Int, peak: Int)? {
            let pixels = rect.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
                .applying(CGAffineTransform(scaleX: scale, y: scale)).integral
            guard let crop = image.cropping(to: pixels), crop.width * crop.height <= 500_000 else { return nil }
            let w = crop.width, h = crop.height
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let data = ctx.data else { return nil }
            let rgba = data.assumingMemoryBound(to: UInt8.self)
            var values = [Int](repeating: 0, count: 256)
            for i in stride(from: 0, to: w * h * 4, by: 4) {
                values[(Int(rgba[i]) + Int(rgba[i + 1]) + Int(rgba[i + 2])) / 3] += 1
            }
            guard let bg = values.indices.max(by: { values[$0] < values[$1] }) else { return nil }
            let bright = values.lastIndex(where: { $0 > 0 }) ?? bg
            let dark = values.firstIndex(where: { $0 > 0 }) ?? bg
            return (bg, bright - bg >= bg - dark ? bright : dark)
        }
        guard let marker = ink(before.marker), let text = ink(before.body), let hint = ink(before.hint),
              matchesInk(marker: marker, text: text, hint: hint),
              geometry(screen, body: body, windowID: metadata.windowID) == before,
              (try? TerminalAppleEvents.profileWindowMetadata(tty: tty)) == metadata else { return false }
        return true
    }
}
