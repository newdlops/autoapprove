import Foundation
import CoreFoundation
import Combine
import Darwin
import AutoApproveCore

@main enum ScreenSessionCompareWorker {
    enum Failure:Error { case invalid(String) }
    static func require(_ value:Bool,_ message:String)throws{if !value{throw Failure.invalid(message)}}
    static func emit(_ value:[String:Any])throws{print(String(decoding:try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),as:UTF8.self));fflush(stdout)}
    static func foreign(_ text:String)->String{
        let units=Array(text.utf16)
        return units.withUnsafeBufferPointer{unsafeBitCast(CFStringCreateWithCharacters(kCFAllocatorDefault,$0.baseAddress!,$0.count)!,to:NSString.self) as String}
    }
    static let power=PowerControl(read:{PowerReading()},ruleInstalled:{false},ruleFile:{false},installRule:{throw Failure.invalid("Forbidden power operation")},removeRule:{throw Failure.invalid("Forbidden power operation")},setSleepDisabled:{_ in throw Failure.invalid("Forbidden power operation")},startGuard:{_,_ in throw Failure.invalid("Forbidden helper")})
    @MainActor final class Counter{var value=0}
    struct Workload{
        let root:URL,engine:ApprovalEngine,ids:[String],frames:[[String]],changing:Bool,guarded:Bool,expectedEntries:Int,expectedBytes:Int,counter:Counter,subscription:AnyCancellable
    }
    @MainActor static func cache(_ engine:ApprovalEngine)->(Int,Int){
        let fields=Mirror(reflecting:engine).children
        return (Mirror(reflecting:fields.first{$0.label=="screenAnalyses"}!.value).children.count,fields.first{$0.label=="screenAnalysisCacheBytes"}!.value as! Int)
    }
    static func metrics()throws->[String:Any]{
        var usage=rusage(),info=rusage_info_v4(),heap=malloc_statistics_t();try require(getrusage(RUSAGE_SELF,&usage)==0,"self rusage failed")
        let result=withUnsafeMutablePointer(to:&info){pointer in pointer.withMemoryRebound(to:rusage_info_t?.self,capacity:1){proc_pid_rusage(getpid(),RUSAGE_INFO_V4,$0)}};try require(result==0,"self proc rusage failed");malloc_zone_statistics(nil,&heap)
        return ["cpu":Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)+Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1e6,"instructions":info.ri_instructions,"cycles":info.ri_cycles,"rss":info.ri_resident_size,"heapBytes":heap.size_in_use]
    }
    static let now=Date(timeIntervalSince1970:1_800_000_000)
    @MainActor static func make(_ mode:String)throws->Workload{
        let count:Int,foreignStorage:Bool,changing:Bool,lineCount:Int,guarded:Bool
        switch mode{
        case "cached-native19":(count,foreignStorage,changing,lineCount,guarded)=(19,false,false,160,false)
        case "cached-cocoa19":(count,foreignStorage,changing,lineCount,guarded)=(19,true,false,640,false)
        case "cached-native32":(count,foreignStorage,changing,lineCount,guarded)=(32,false,false,32,false)
        case "single-native":(count,foreignStorage,changing,lineCount,guarded)=(1,false,false,8,false)
        case "changing-native19":(count,foreignStorage,changing,lineCount,guarded)=(19,false,true,160,false)
        case "missing":(count,foreignStorage,changing,lineCount,guarded)=(0,false,false,8,true)
        case "ended":(count,foreignStorage,changing,lineCount,guarded)=(1,false,false,8,true)
        default:throw Failure.invalid("Unknown screen workload")
        }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-screen-session-worker-"+UUID().uuidString)
        let records=ProcessDiscovery.parse((0..<count).map{index in "\(990001+index) 1 ttys\(900+index) \(990001+index) \(990001+index) Mon Oct 12 09:00:00 2026 /fixture/codex"}.joined(separator:"\n"))
        let engine=try ApprovalEngine(paths:AppPaths(directory:root),terminalReader:{_ in throw Failure.invalid("Forbidden original terminal read")},claudeRegistryReader:{_ in []},processReader:{records},powerControl:power,terminalInputAvailable:{false},terminalInputIdentity:{_ in nil})
        let sessions=records.enumerated().map{index,record->AgentSession in
            var value=AgentSession(id:record.key,agent:.codex,pid:record.pid,started:record.started,tty:"/dev/"+record.tty,cwd:"/fixture/project\(index)",terminal:.iterm)
            value.channel = .itermScreen;value.lastActivity=now;return value
        }
        engine.updateDiscovery(sessions,records:records)
        if mode=="ended"{engine.updateDiscovery([],records:[])}
        let ids=sessions.isEmpty ? ["missing-original"]:sessions.map(\.id)
        let history=String(repeating:"Synthetic output /fixture/main.swift e\u{301} 한글 row\n",count:lineCount)
        let frames=ids.indices.map{index in (0..<(changing ? 8:1)).map{variant in
            let text=history+"frame \(index) variant \(variant)\n• Working (esc to interrupt)\n›\n? for shortcuts"
            return foreignStorage ? foreign(text):text
        }}
        for _ in 0..<8{for index in ids.indices{engine.receiveScreen(sessionID:ids[index],raw:frames[index][0],generation:"fixture",at:now)}}
        if mode == "missing" {
            try require(engine.snapshot.sessions.isEmpty, "Missing original must stay absent")
        } else if mode == "ended" {
            try require(engine.snapshot.sessions.count == 1 && engine.snapshot.sessions[0].phase == .ended, "Guarded original must stay ended")
        } else {
            try require(engine.snapshot.sessions.count == count && engine.snapshot.sessions.allSatisfy { $0.phase == .working }, "Synthetic active originals must stay working")
        }
        let state=cache(engine),counter=Counter(),subscription=engine.$snapshot.sink{_ in counter.value+=1};counter.value=0
        try require(state.0==(guarded ? 0:count),"Unexpected initial cache entries")
        try require(state.1>=0 && state.1<=8*1024*1024,"Initial cache budget exceeded")
        try require(engine.snapshot.events.isEmpty && engine.managedPTY.inventory.isEmpty,"Unexpected fixture activity")
        return Workload(root:root,engine:engine,ids:ids,frames:frames,changing:changing,guarded:guarded,expectedEntries:state.0,expectedBytes:state.1,counter:counter,subscription:subscription)
    }
    @MainActor @inline(never) static func measure(_ value:Workload,_ iterations:Int)throws->UInt64{
        for frame in 0..<iterations{
            let index=frame%value.ids.count,variant=value.changing ? (frame/value.ids.count)%8:0
            value.engine.receiveScreen(sessionID:value.ids[index],raw:value.frames[index][variant],generation:"fixture",at:now)
        }
        let state=cache(value.engine)
        try require(state.0==value.expectedEntries && state.1==value.expectedBytes,"Cache count/bytes changed unexpectedly")
        try require(value.counter.value==0,"Repeated working/guard frames needlessly published snapshot")
        try require(value.engine.snapshot.events.isEmpty && value.engine.managedPTY.inventory.isEmpty && value.engine.snapshot.sessions.allSatisfy{!$0.automatic},"Unexpected automation or PTY activity")
        var digest=UInt64(iterations)^UInt64(state.0)^UInt64(state.1)
        for row in value.engine.snapshot.sessions{digest=digest &* 1099511628211 ^ UInt64(row.pid);for byte in row.phase.rawValue.utf8{digest=digest &* 1099511628211 ^ UInt64(byte)}}
        return digest
    }
    @MainActor static func main()throws{
        let modes=["cached-native19","cached-cocoa19","cached-native32","single-native","changing-native19","missing","ended"]
        var workloads:[String:Workload]=[:]
        defer{for value in workloads.values{value.subscription.cancel();value.engine.stop();try? FileManager.default.removeItem(at:value.root)}}
        for mode in modes{workloads[mode]=try make(mode);_ = try measure(workloads[mode]!,128)}
        try emit(["ready":true,"actualCompiledCore":true,"allRepeatedSnapshotsQuiet":true,"cacheBudgetsPreserved":true,"originalTerminalActions":0,"realPowerCommands":0,"engineStarted":false,"listenerStarted":false])
        while let line=readLine(){
            let request=try JSONSerialization.jsonObject(with:Data(line.utf8)) as! [String:Any];if request["command"] as? String=="stop"{break}
            let mode=request["mode"] as! String,iterations=request["iterations"] as! Int
            guard let value=workloads[mode]else{throw Failure.invalid("Unknown requested screen workload")}
            let before=try metrics(),start=ProcessInfo.processInfo.systemUptime
            let digest=try autoreleasepool{try measure(value,iterations)},wall=ProcessInfo.processInfo.systemUptime-start,after=try metrics()
            try emit(["id":request["id"]!,"mode":mode,"iterations":iterations,"checksum":String(digest),"wall":wall,"before":before,"after":after])
        }
    }
}
