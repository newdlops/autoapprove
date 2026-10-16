import AppKit
import CoreImage.CIFilterBuiltins
import Darwin

private struct FixtureFailure: Error { let message: String }

@main @MainActor struct QRResourceBench {
    static func metrics() throws -> [String: Any] {
        var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to:&info) { pointer in
            pointer.withMemoryRebound(to:integer_t.self,capacity:capacity) {
                task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)
            }
        }
        guard result == KERN_SUCCESS else { throw FixtureFailure(message:"Own memory counter unavailable") }
        return ["cpuSeconds":Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)+Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1e6,
                "footprintBytes":info.phys_footprint,"peakResidentBytes":usage.ru_maxrss]
    }
    // Exact former RemoteAccessSettings.qrCode implementation (v0.2.108).
    static func legacy(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator();filter.message = Data(text.utf8)
        guard let output = filter.outputImage,let cg = CIContext().createCGImage(output,from:output.extent) else { return nil }
        return NSImage(cgImage:cg,size:NSSize(width:cg.width,height:cg.height))
    }
    static func cgImage(_ image: NSImage?) throws -> CGImage {
        guard let image,let cg = image.cgImage(forProposedRect:nil,context:nil,hints:nil) else { throw FixtureFailure(message:"Missing QR image") }
        return cg
    }
    static func pixels(_ image: CGImage) throws -> Data {
        var bytes = [UInt8](repeating:0,count:image.width*image.height*4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data:buffer.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height));return true
        }
        guard drawn else { throw FixtureFailure(message:"Pixel normalization failed") }
        return Data(bytes)
    }
    static func verify() throws -> [String: Any] {
        let urls = ["http://192.0.2.1:8765","http://[2001:db8::2]:8765"]
        let cache = QRCodeImageCache()
        let context = CIContext(options:[.useSoftwareRenderer:true,.cacheIntermediates:false])
        guard let detector = CIDetector(ofType:CIDetectorTypeQRCode,context:context,options:[CIDetectorAccuracy:CIDetectorAccuracyHigh]) else {
            throw FixtureFailure(message:"QR decoder unavailable")
        }
        var previous: Data?
        for url in urls {
            let actual = try cgImage(cache.image(for:url)),expected = try cgImage(legacy(url))
            let bytes = try pixels(actual)
            guard actual.width == expected.width,actual.height == expected.height,bytes == (try pixels(expected)) else {
                throw FixtureFailure(message:"Software QR differs from the existing pixels")
            }
            if let previous,previous == bytes { throw FixtureFailure(message:"Changed URL retained previous QR") }
            previous = bytes
            let code = CIImage(cgImage:actual).transformed(by:CGAffineTransform(scaleX:8,y:8))
            let white = CIImage(color:CIColor.white).cropped(to:code.extent.insetBy(dx:-32,dy:-32))
            let framed = code.composited(over:white)
            let values = detector.features(in:framed).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            guard values == [url] else { throw FixtureFailure(message:"QR decoded URL differs") }
        }
        var generations = 0
        let counted = QRCodeImageCache { text in generations += 1;return text == "failure" ? nil : NSImage(size:NSSize(width:1,height:1)) }
        weak var old: NSImage?
        autoreleasepool {
            let image = counted.image(for:"first");old = image
            for _ in 0..<100 { precondition(counted.image(for:"first") === image) }
        }
        precondition(generations == 1 && old != nil)
        autoreleasepool { _ = counted.image(for:"second") }
        precondition(generations == 2 && old == nil,"Only one current bitmap may be retained")
        precondition(counted.image(for:"failure") == nil)
        _ = counted.image(for:"second")
        precondition(generations == 4,"Failure must clear an obsolete image and permit retry")
        return ["pixelParity":true,"decodedURLs":urls.count,"changedURL":true,"singleImageRetention":true,"sameURLGenerationsFor101Requests":1,"failedGenerationClearsOldImage":true]
    }
    static func main() throws {
        let old = CommandLine.arguments.contains("--legacy"),url = "http://192.0.2.1:8765",cache = QRCodeImageCache()
        func image() -> NSImage? { old ? legacy(url) : cache.image(for:url) }
        let before = try metrics(),began = ProcessInfo.processInfo.systemUptime
        let first = autoreleasepool { image() }
        guard first != nil else { throw FixtureFailure(message:"First QR generation failed") }
        let firstWall = ProcessInfo.processInfo.systemUptime-began,firstMetrics = try metrics()
        let repeatStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100 {
            try autoreleasepool {
                guard let next = image() else { throw FixtureFailure(message:"Repeated generation failed") }
                if !old { precondition(next === first) }
            }
        }
        let repeatWall = ProcessInfo.processInfo.systemUptime-repeatStart
        var result = try withExtendedLifetime((cache,first)) { try metrics() }
        result["firstCPUSeconds"] = (firstMetrics["cpuSeconds"] as! Double)-(before["cpuSeconds"] as! Double)
        result["repeatCPUSeconds"] = (result["cpuSeconds"] as! Double)-(firstMetrics["cpuSeconds"] as! Double)
        result["firstWallSeconds"] = firstWall;result["repeatWallSeconds"] = repeatWall
        result["footprintDeltaBytes"] = Int64(result["footprintBytes"] as! UInt64)-Int64(before["footprintBytes"] as! UInt64)
        result["repeatedRenders"] = 100;result["legacy"] = old
        // Decoder/reference rendering runs after the measurement, so its own
        // GPU/framework initialization is not attributed to the candidate.
        result["verificationAfterMeasurement"] = try verify()
        print(String(decoding:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),as:UTF8.self))
    }
}
