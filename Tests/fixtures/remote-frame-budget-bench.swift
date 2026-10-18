import Foundation
import CoreFoundation
import CryptoKit
import AutoApproveCore

/// Actual frame construction/JSON encoding with synthetic bridge output only.
/// No listener, source process, native app, screen capture or input is used.
@main struct RemoteFrameBudgetBench {
    static func cpu() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw AppError.message(message) }
    }
    static func foreign(_ text: String) -> String {
        let units = Array(text.utf16)
        return unsafeBitCast(CFStringCreateWithCharacters(kCFAllocatorDefault, units, units.count)!, to: NSString.self) as String
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-frame-budget-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let unicode = String(repeating:"Synthetic output 한글 e\u{301} 👩🏽‍💻 /fixture/result\n", count:1_024) + "Working\nesc to interrupt"
        let oversized = String(repeating:"e\u{301} 👩🏽‍💻 한글\r\n", count:24_000) + "Working\nesc to interrupt"
        let values:[(String,String,Int)] = [
            ("native-ascii",String(repeating:"Synthetic output /fixture/result\n",count:2_048),128),
            ("native-under",unicode,128),
            ("cocoa-under",NSAppleEventDescriptor(string:unicode).stringValue!,128),
            ("foreign-under",foreign(unicode),128),
            ("cocoa-over",NSAppleEventDescriptor(string:oversized).stringValue!,8)
        ]
        var results:[[String:Any]]=[], digest=SHA256()
        for (name,raw,rounds) in values {
            if name.hasPrefix("cocoa") || name.hasPrefix("foreign") {try check(!raw.isContiguousUTF8,"Expected actual foreign storage")}
            let record=ProcessDiscovery.parse("82999 1 ttys082 82999 82999 Sun Oct 18 09:00:00 2026 codex")[0]
            var session=ProcessDiscovery.sessions([record])[0]
            session.terminal = .vscode; session.channel = .vscodeScreen; session.bridgeID="fixture";session.terminalID="fixture"
            let engine=try ApprovalEngine(paths:AppPaths(directory:root.appendingPathComponent(name)),claudeRegistryReader:{_ in []},processReader:{[record]},terminalInputAvailable:{false},terminalInputIdentity:{_ in nil})
            engine.updateDiscovery([session],records:[record]);engine.receiveScreen(sessionID:session.id,raw:raw,generation:"fixture-generation")
            let initial=try await engine.remoteTerminal(sessionID:session.id)
            let expected=String(raw.suffix(160_000)),encoder=JSONEncoder()
            try check(Data(initial.screen.utf8)==Data(expected.utf8),"Frame character budget changed")
            let decoded=try JSONDecoder().decode(RemoteTerminalFrame.self,from:encoder.encode(initial))
            try check(Data(decoded.screen.utf8)==Data(expected.utf8),"Encoded screen changed")
            digest.update(data:Data(expected.utf8))
            var trials:[[String:Double]]=[],checksum=0,last=initial
            for _ in 0..<3 {
                let startCPU=cpu(),startWall=ProcessInfo.processInfo.systemUptime
                for _ in 0..<rounds {
                    var frame=try await engine.remoteTerminal(sessionID:session.id)
                    // Fix only the synthetic timestamp width in encoded-size controls.
                    frame.observedAt=Date(timeIntervalSince1970:1_700_000_000)
                    checksum += try encoder.encode(frame).count;last=frame
                }
                trials.append(["cpuSeconds":cpu()-startCPU,"wallSeconds":ProcessInfo.processInfo.systemUptime-startWall])
            }
            try check(Data(last.screen.utf8)==Data(expected.utf8)&&last.revision==initial.revision&&last.streamID==initial.streamID,"Repeated screen or control identity changed")
            try check(engine.snapshot.events.isEmpty&&engine.managedPTY.inventory.isEmpty,"Fixture created input/audit/PTY work")
            results.append(["name":name,"rounds":rounds,"rawBytes":raw.utf8.count,"rawUTF16":raw.utf16.count,"foreign":!raw.isContiguousUTF8,"checksum":checksum,"trials":trials])
            engine.stop()
        }
        print(String(decoding:try JSONSerialization.data(withJSONObject:["workloads":results,"correctnessCases":values.count,"correctnessDigest":digest.finalize().map{String(format:"%02x",$0)}.joined(),"inputPosts":0,"captures":0,"scope":"Actual release Core frame construction plus JSON encoding of fixed synthetic bridge output. Exact legacy 160000-Character suffix and encoded screen verified. No native/system/network reads."],options:.sortedKeys),as:UTF8.self))
    }
}
