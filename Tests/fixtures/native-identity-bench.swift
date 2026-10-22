// Actual Core and fresh kernel identity for one owned inert PTY process.
// Screens, window metadata, pixels and permission callbacks are synthetic.
import Foundation
import Darwin
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import AutoApproveCore

private final class IdentityBenchSource: @unchecked Sendable {
    private let lock = NSLock()
    private var screens = 0, images = 0, reveals = 0, inputs = 0, requests = 0
    func count(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        switch name { case "screens": screens += 1; case "images": images += 1; case "reveals": reveals += 1;
        case "inputs": inputs += 1; default: requests += 1 }
    }
    var counts: [String:Int] {
        lock.lock(); defer { lock.unlock() }
        return ["screens":screens,"images":images,"reveals":reveals,"inputs":inputs,"permissionRequests":requests]
    }
}

@main struct NativeIdentityBench {
    static let text = "Synthetic original\nREADY> "
    static func cpu(_ who: Int32) -> Double {
        var value = rusage(); precondition(getrusage(who,&value) == 0)
        return Double(value.ru_utime.tv_sec+value.ru_stime.tv_sec)+Double(value.ru_utime.tv_usec+value.ru_stime.tv_usec)/1e6
    }
    static var now: Double { ProcessInfo.processInfo.systemUptime }
    static func jpeg() throws -> TerminalNativeImage {
        let pixels = Data(repeating:127,count:64), provider = CGDataProvider(data:pixels as CFData)!
        let image = CGImage(width:4,height:4,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:16,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipLast.rawValue),
            provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let bytes = NSMutableData(), destination = CGImageDestinationCreateWithData(bytes,UTType.jpeg.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(destination,image,nil);precondition(CGImageDestinationFinalize(destination))
        let result = TerminalNativeImage(data:(bytes as Data).base64EncodedString(),width:4,height:4)
        try result.validate();return result
    }
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count >= 2 else { throw AppError.message("Pass the compiled owned pty-holder fixture") }
        let root = URL(fileURLWithPath:"/private/tmp/aa-native-identity-bench-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let executable = root.appendingPathComponent("codex")
        try FileManager.default.copyItem(at:URL(fileURLWithPath:CommandLine.arguments[1]),to:executable)
        let holder = Process();holder.executableURL = URL(fileURLWithPath:CommandLine.arguments[1]);holder.arguments = [executable.path]
        holder.standardInput = FileHandle.nullDevice;holder.standardOutput = FileHandle.nullDevice;holder.standardError = FileHandle.nullDevice
        try holder.run()
        defer { if holder.isRunning { holder.terminate() };holder.waitUntilExit() }
        var record: ProcessRecord?
        for _ in 0..<100 {
            record = try ProcessDiscovery.read().first { $0.parent == holder.processIdentifier && $0.agent == .codex && $0.isForeground }
            if record != nil { break };try await Task.sleep(for:.milliseconds(10))
        }
        guard let record else { throw AppError.message("Owned inert foreground PTY was not found") }
        let owned = try ProcessDiscovery.read(pid:record.pid)
        precondition(owned.count == 1 && owned[0] == record)
        let session = AgentSession(id:record.key,agent:.codex,pid:record.pid,started:record.started,
            tty:"/dev/"+record.tty,cwd:root.path,terminal:.terminal)
        let source = IdentityBenchSource(), image = try jpeg()
        let capture = TerminalWindowCapture(permissions:{TerminalWindowPermissions(screen:true,keyboard:false,automation:true)},
            requestPermissions:{source.count("requests")},metadata:{tty in
                precondition(tty == session.tty)
                return TerminalWindowMetadata(tty:tty,windowID:91,ownerPID:900,ownerBundleID:"com.apple.Terminal",selected:true,minimized:false)
            },capture:{_ in source.count("images");return image})
        let adapter = ScreenHostAdapter(screens:{targets in
            precondition(targets.allSatisfy{$0.tty == session.tty});source.count("screens")
            return TerminalSnapshot(screens:targets.map{TerminalScreen(tty:$0.tty,contents:text)})
        },approve:{_,_,_ in source.count("inputs");throw AppError.message("Read-only benchmark cannot send input")},
          reveal:{target in precondition(target.tty == session.tty);source.count("reveals");return nil})
        let engine = try ApprovalEngine(paths:AppPaths(directory:root.appendingPathComponent("state")),
            claudeRegistryReader:{_ in []},screenAdapters:[.terminal:adapter],terminalWindowCapture:capture,
            terminalInputAvailable:{false})
        defer { engine.stop() }
        engine.updateDiscovery([session],records:[record]);await engine.connectTerminal()
        var phases:[[String:Any]] = []
        let modes = ["connect","fresh-preview","cached-preview","plain-control","full-table-control","discovery-control"]
        let order = CommandLine.arguments.contains("--reverse") ? Array(modes.reversed()) : modes
        for mode in order {
            let iterations = mode == "plain-control" ? 256 : mode.hasSuffix("table-control") || mode == "discovery-control" ? 12 : 24
            var wall = 0.0, ownCPU = 0.0, childCPU = 0.0, units = 0, samples:[Double] = []
            for _ in 0..<iterations {
                if mode == "cached-preview" {
                    capture.invalidate()
                    let primed = try await engine.remoteTerminal(sessionID:session.id,realtime:true,renderWindow:true)
                    precondition(primed.nativeDisplay?.image == image)
                }
                let captures = source.counts["images"]!, selfBegin = cpu(RUSAGE_SELF), childBegin = cpu(RUSAGE_CHILDREN), begin = now
                if mode == "full-table-control" || mode == "discovery-control" {
                    let rows = try mode == "full-table-control" ? ProcessDiscovery.read() : ProcessDiscovery.readSessions()
                    precondition(rows.contains{$0.pid == record.pid && $0.started == record.started && $0.tty == record.tty && $0.agent == .codex && $0.isForeground})
                    units += rows.count
                } else {
                    let frame: RemoteTerminalFrame
                    if mode == "connect" { frame = try await engine.connectRemoteTerminal(["sessionID":session.id]) }
                    else {
                        if mode == "fresh-preview" { capture.invalidate() }
                        frame = try await engine.remoteTerminal(sessionID:session.id,realtime:true,renderWindow:mode != "plain-control")
                    }
                    precondition(frame.sessionID == session.id && frame.screen == text)
                    if mode == "fresh-preview" || mode == "cached-preview" {
                        precondition(frame.nativeDisplay?.state == .live && frame.nativeDisplay?.image == image)
                        precondition(source.counts["images"]! == captures+(mode == "fresh-preview" ? 1 : 0))
                    } else { precondition(frame.nativeDisplay == nil) }
                    units += 1
                }
                let elapsed = now-begin
                wall += elapsed;ownCPU += cpu(RUSAGE_SELF)-selfBegin;childCPU += cpu(RUSAGE_CHILDREN)-childBegin
                samples.append(elapsed*1000)
            }
            samples.sort()
            phases.append(["mode":mode,"iterations":iterations,"workUnits":units,"wallSeconds":wall,
                "selfCPUSeconds":ownCPU,"childCPUSeconds":childCPU,"combinedCPUSeconds":ownCPU+childCPU,
                "medianMS":samples[samples.count/2],"p95MS":samples[max(0,Int(ceil(Double(samples.count)*0.95))-1)]])
        }
        let final = try ProcessDiscovery.read(pid:record.pid)
        precondition(final.count == 1 && final[0] == record)
        let active = engine.snapshot.sessions.filter{$0.phase != .ended}
        precondition(active.count == 1 && active[0].pid == session.pid && active[0].started == session.started && active[0].tty == session.tty)
        let counts = source.counts
        precondition(counts["inputs"] == 0 && counts["permissionRequests"] == 0 && counts["images"] == 48 && counts["reveals"] == 24)
        var usage = rusage();getrusage(RUSAGE_SELF,&usage)
        let semantics = modes.map{mode in mode+":"+String(mode == "plain-control" ? 256 : mode.hasSuffix("table-control") || mode == "discovery-control" ? 12 : 24)}.joined(separator:"|")+"|exact-original|exact-pixels|no-input|no-permission-request"
        let digest = SHA256.hash(data:Data(semantics.utf8)).map{String(format:"%02x",$0)}.joined()
        let report:[String:Any] = ["phases":phases,"source":counts,"semanticDigest":digest,"peakResidentBytes":usage.ru_maxrss,
            "scope":"Actual Core connection and fresh/cached preview checks with a fresh kernel identity for one owned inert PTY. Synthetic text/pixels/permissions/reveal only. Other process metadata is read only in baseline identity scans and explicit controls, and never emitted. No user terminal IO, live capture, listener, power command or permission changes. Not installed-app or phone/VPN latency."]
        print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),as:UTF8.self))
    }
}
