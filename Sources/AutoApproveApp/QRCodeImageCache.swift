import AppKit
import CoreImage.CIFilterBuiltins

/// View-owned memoization, deliberately not observable: computing an image
/// during body evaluation must not publish another view update.
@MainActor final class QRCodeImageCache {
    private var cached: (text: String, image: NSImage)?
    private let render: (String) -> NSImage?
    init(render: ((String) -> NSImage?)? = nil) { self.render = render ?? Self.generate }

    func image(for text: String) -> NSImage? {
        if let cached, cached.text == text { return cached.image }
        cached = nil
        guard let image = render(text) else { return nil }
        cached = (text,image)
        return image
    }
    private static func generate(_ text: String) -> NSImage? {
        autoreleasepool {
            let filter = CIFilter.qrCodeGenerator(); filter.message = Data(text.utf8)
            // This tiny static bitmap needs no GPU context or retained graph.
            let context = CIContext(options: [.useSoftwareRenderer:true,.cacheIntermediates:false])
            guard let output = filter.outputImage, let cg = context.createCGImage(output,from:output.extent) else { return nil }
            return NSImage(cgImage:cg,size:NSSize(width:cg.width,height:cg.height))
        }
    }
}
