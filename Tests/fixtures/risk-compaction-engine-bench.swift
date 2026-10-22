import Foundation
import Combine
import Darwin
import AutoApproveCore

/// Uses production discovery/screen handling with synthetic screens. Never reads or types in a user terminal.
@main struct PollingPerformanceCheck {
    static func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        guard condition else { throw AppError.message(message()) }
    }
    final class Frames: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: TerminalScreen] = [:]
        private var calls = 0, requested = 0
        func resetMetrics() { lock.lock(); defer { lock.unlock() }; calls = 0; requested = 0 }
        func metrics() -> [String:Any] { lock.lock(); defer { lock.unlock() }; return ["calls":calls,"requested":requested] }
        func replace(_ screens: [TerminalScreen]) {
            lock.lock(); defer { lock.unlock() }
            values = Dictionary(uniqueKeysWithValues: screens.map { ($0.tty, $0) })
        }
        func read(_ targets: [ScreenTarget]) -> TerminalSnapshot {
            lock.lock(); defer { lock.unlock() }
            calls += 1; requested += targets.count
            return TerminalSnapshot(screens: targets.compactMap { values[$0.tty] })
        }
    }

    static func screen(index: Int, variant: Int, kind: String) -> TerminalScreen {
        let agent: AgentKind = index.isMultiple(of: 2) ? .codex : .claude
        let detail = kind.hasPrefix("mixed") ? "합성 출력 e\u{301} 👩🏽‍💻" : "ASCII output"
        let historyRows = CommandLine.arguments.count > 4 ? Int(CommandLine.arguments[4])! : 160
        let history = (0..<historyRows).map { "Completed synthetic step \($0): checked \(detail) local output and retained the original session." }.joined(separator: "\n")
        let heading = agent == .codex ? "Would you like to run the following command?" : "Do you want to proceed?"
        let glyph = agent == .codex ? "›" : "❯"
        let body: String
        switch index / 4 {
        case 0: body = "Checking synthetic result \(variant)\n• Working (esc to interrupt)"
        case 1: body = "\(glyph)\n? for shortcuts"
        case 2: body = "\(heading)\n  $ fixture-test-\(variant)\n\(glyph) 1. Yes\n  2. No\nEsc to cancel"
        default: body = "Which synthetic result \(variant) should we inspect?\n\(glyph) 1. First\n  2. Second\nEnter to select"
        }
        let text = history + "\nIgnored body revision \(variant)\n" + String(repeating: "Unchanged visible context\n", count: 20) + body
        let contents = kind.hasSuffix("cocoa") ? NSAppleEventDescriptor(string: text).stringValue! : text
        return TerminalScreen(tty: "/dev/fixture-perf-\(index)", contents: contents, title: "Synthetic terminal \(index)")
    }

    static func cpu(_ who: Int32 = RUSAGE_SELF) -> Double {
        var usage = rusage(); getrusage(who, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }


    @MainActor final class Context {
        let root: URL
        let kind: String
        let frames: Frames
        let engine: ApprovalEngine
        let variants: [[TerminalScreen]]
        var publications = 0
        var tracker = AttentionTracker()
        var subscription: AnyCancellable?
        let phases = ["working":4,"approval":4,"input":4,"idle":4]

        init(root:URL,kind:String) throws {
            self.root=root;self.kind=kind
            let frames=Frames();self.frames=frames
            let adapter=ScreenHostAdapter(screens:{frames.read($0)},approve:{_,_,_ in fatalError("Probe must never send input")},reveal:{_ in nil})
            engine=try ApprovalEngine(paths:AppPaths(directory:root.appendingPathComponent("state")),claudeRegistryReader:{_ in []},processReader:{[]},screenAdapters:[.terminal:adapter])
            variants=(0...1).map{variant in (0..<16).map{PollingPerformanceCheck.screen(index:$0,variant:variant,kind:kind)}}
        }
        func prepare() async throws -> [String:Any] {
            let sessions=(0..<16).map{index in AgentSession(id:"process:\(900_000+index):perf",agent:index.isMultiple(of:2) ? .codex:.claude,pid:Int32(900_000+index),started:"perf",tty:"/dev/fixture-perf-\(index)",cwd:root.path,terminal:.terminal)}
            engine.updateDiscovery(sessions,records:[]);frames.replace(variants[0]);await engine.connectScreenHost(.terminal)
            subscription=engine.$snapshot.dropFirst().sink{[weak self] snapshot in
                guard let self else{return};self.publications += 1
                _=self.tracker.update(snapshot)+AttentionRequest.completions(snapshot)
            }
            let foreign=variants.flatMap{$0}.filter{!$0.contents.isContiguousUTF8}.count
            try PollingPerformanceCheck.check(foreign==(kind.hasSuffix("cocoa") ? 32:0),"Wrong input storage")
            try await Task.sleep(for:.milliseconds(2200))
            let started=ProcessInfo.processInfo.systemUptime;var streak=0
            while streak<2 {
                let before=publications;await engine.refreshScreenHost(.terminal)
                let current=Dictionary(grouping:engine.snapshot.sessions,by:{$0.phase.rawValue}).mapValues(\.count)
                streak=current==phases && (streak==0 || publications==before) ? streak+1:0
                try PollingPerformanceCheck.check(ProcessInfo.processInfo.systemUptime-started<15,"Idle readiness did not settle")
                if streak<2 {try await Task.sleep(for:.milliseconds(50))}
            }
            let owners=variants.map{bank -> Int in
                var keys=Set<String>()
                for (index,screen) in bank.enumerated(){
                    _=screen.contents.utf8.withContiguousStorageIfAvailable{bytes in
                        if let pointer=bytes.baseAddress {keys.insert("\(UInt(bitPattern:pointer)):\(index%2)")}
                    }
                }
                return keys.count
            }
            return ["kind":kind,"foreignFrames":foreign,"nativeOwnerKeys":owners,"phaseCounts":phases]
        }
        func measure(changed:Bool,rounds:Int) async throws -> [String:Any] {
            try PollingPerformanceCheck.check(rounds>0 && rounds<=128 && rounds.isMultiple(of:2),"Use a positive even block")
            try PollingPerformanceCheck.check(Dictionary(grouping:engine.snapshot.sessions,by:{$0.phase.rawValue}).mapValues(\.count)==phases,"Wrong starting phases")
            publications=0;frames.resetMetrics()
            let startCPU=PollingPerformanceCheck.cpu(),start=Date()
            for round in 0..<rounds {
                if changed {frames.replace(variants[(round+1)%2])}
                await engine.refreshScreenHost(.terminal)
            }
            let wall=Date().timeIntervalSince(start),cpu=PollingPerformanceCheck.cpu()-startCPU
            let counts=Dictionary(grouping:engine.snapshot.sessions,by:{$0.phase.rawValue}).mapValues(\.count)
            let reads=frames.metrics()
            try PollingPerformanceCheck.check(counts==phases,"Changed phase counts")
            try PollingPerformanceCheck.check(publications==(changed ? rounds:0),"Changed publication count")
            try PollingPerformanceCheck.check(reads["calls"] as? Int==rounds && reads["requested"] as? Int==rounds*16,"Changed reader workload")
            try PollingPerformanceCheck.check(engine.snapshot.sessions.allSatisfy{!$0.automatic} && engine.snapshot.events.isEmpty && engine.managedPTY.inventory.isEmpty,"Unexpected input policy or PTY")
            var usage=rusage();getrusage(RUSAGE_SELF,&usage)
            return ["kind":kind,"name":changed ? "changing-screens":"unchanged-screens","rounds":rounds,"sessions":16,"cpuSeconds":cpu,"wallSeconds":wall,"publications":publications,"phaseCounts":counts,"reads":reads,"peakResidentBytes":usage.ru_maxrss]
        }
        func stop(){subscription?.cancel();subscription=nil;engine.stop()}
    }
    @MainActor static func emit(_ value:[String:Any]) throws {
        let bytes=try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])
        FileHandle.standardOutput.write(bytes+Data([10]))
    }
    @MainActor static func main() async {
        var context:Context?
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                guard let data=line.data(using:.utf8),let input=try JSONSerialization.jsonObject(with:data) as? [String:Any],let op=input["op"] as? String else {throw AppError.message("Invalid owned control command")}
                if op=="setup" {
                    context?.stop();context=nil
                    guard let kind=input["kind"] as? String,["ascii-native","mixed-native","ascii-cocoa","mixed-cocoa"].contains(kind),let directory=input["state"] as? String else {throw AppError.message("Invalid fixture setup")}
                    let next=try Context(root:URL(fileURLWithPath:directory),kind:kind);context=next
                    try emit(["op":"ready","result":try await next.prepare()])
                }else if op=="measure" {
                    guard let context,let changed=input["changed"] as? Bool,let rounds=input["rounds"] as? Int else {throw AppError.message("Missing prepared context")}
                    try emit(["op":"measured","result":try await context.measure(changed:changed,rounds:rounds)])
                }else if op=="quit" {context?.stop();context=nil;try emit(["op":"closed"]);return}
                else {throw AppError.message("Unknown fixture operation")}
            }
            context?.stop()
        }catch{
            context?.stop();FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8));exit(1)
        }
    }
}
