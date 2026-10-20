import Foundation
import Darwin
import AutoApproveCore

private final class FileCalls: @unchecked Sendable {
    private let lock=NSLock();private var value=0
    func record() { lock.lock();value+=1;lock.unlock() }
    var count: Int { lock.lock();defer { lock.unlock() };return value }
}
@main struct CodexMetadataBench {
    static func cpu() -> Double {
        var value=rusage();getrusage(RUSAGE_SELF,&value)
        return Double(value.ru_utime.tv_sec+value.ru_stime.tv_sec)+Double(value.ru_utime.tv_usec+value.ru_stime.tv_usec)/1e6
    }
    static func header(_ id: String, large: Bool, generation: Int=0, scale: Int=1) throws -> Data {
        let padding=large ? String(repeating:"합성 작업 지침 e\u{301} 🧪 ordinary context.\n",count:2048*scale) : ""
        let row:JSONObject=["type":"session_meta","payload":["source":"cli","id":id,
            "context":["instructions":[["message":padding]]],"generation":generation]]
        var data=try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]);data.append(10);return data
    }
    static func cacheChecks() -> JSONObject {
        var cache=CodexRolloutMetadataCache(),decodes=0
        func decode(_ data: Data) -> String? { decodes+=1;return String(data:data,encoding:.utf8) }
        let a=Data("é".utf8),b=Data("e\u{301}".utf8),invalid=Data([0xff])
        for _ in 0..<32 { precondition(cache.rootThreadID(path:"a",data:a,decode:decode)=="é") }
        precondition(decodes==1)
        _=cache.rootThreadID(path:"a",data:b,decode:decode);precondition(decodes==2,"Canonical equality is not byte equality")
        for _ in 0..<32 { precondition(cache.rootThreadID(path:"a",data:invalid,decode:decode)==nil) }
        precondition(decodes==3)
        _=cache.rootThreadID(path:"a",data:a,decode:decode);precondition(decodes==4)
        for index in 0..<80 {
            _=cache.rootThreadID(path:"path-\(index)",data:Data([1]),decode:{ _ in "id" })
            precondition(cache.entries.count<=64 && cache.bytes<=cache.byteLimit)
        }
        cache.retain(paths:[]);precondition(cache.entries.isEmpty && cache.bytes==0)
        for index in 0..<8 {
            _=cache.rootThreadID(path:"large-\(index)",data:Data(repeating:65,count:1_048_575),decode:{ _ in "id" })
            precondition(cache.bytes<=cache.byteLimit && cache.entries.count<=3)
        }
        let retained=Set(cache.entries.keys.prefix(1));cache.retain(paths:retained)
        precondition(cache.entries.count==1 && cache.bytes==cache.entries.values.reduce(0){$0+$1.cost})
        let oldCount=cache.entries.count
        _=cache.rootThreadID(path:"over-budget",data:Data(repeating:65,count:5*1_048_576),decode:{ _ in "id" })
        precondition(cache.entries.count==oldCount && cache.entries["over-budget"]==nil)
        cache.retain(paths:[]);precondition(cache.bytes==0)
        return ["byteExactReuse":true,"negativeResultsReused":true,"changedBytesReparsed":true,
            "capacity":64,"byteLimit":4*1_048_576,"evictionAndPruning":true,"oversizedEntrySkipped":true]
    }
    static func main() async throws {
        if CommandLine.arguments.contains("--check-cache") {
            print(String(decoding:try JSONSerialization.data(withJSONObject:cacheChecks(),options:[.sortedKeys]),as:UTF8.self));return
        }
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),count=16
        let day=root.appendingPathComponent("sessions/2026/10/20")
        let files=(0..<count).map { day.appendingPathComponent("rollout-\($0).jsonl") }
        let sessions=(0..<count).map { AgentSession(id:"fixture-\($0)",agent:.codex,pid:Int32(900_000+$0),started:"synthetic",
            tty:"/dev/fixture-\($0)",cwd:root.path,terminal:.terminal) }
        let paths=Dictionary(uniqueKeysWithValues:zip(sessions.map(\.id),files.map(\.path)))
        var phases:[[String:Any]]=[]
        let modes=["small-steady","large-steady","large-append","large-change","large-over-capacity","cold"]
        let requested=CommandLine.arguments.first(where:{$0.hasPrefix("--mode=")}).map{String($0.dropFirst(7))}
        if let requested { precondition(modes.contains(requested),"Unknown synthetic workload") }
        for mode in modes where requested == nil || requested == mode {
            let large=mode != "small-steady",rounds=mode=="cold" ? 12 : ["large-change","large-over-capacity"].contains(mode) ? 30 : 60
            for index in files.indices { try header("root-\(index)",large:large,scale:mode=="large-over-capacity" ? 4 : 1).write(to:files[index]) }
            let firstHeaderBytes=try Data(contentsOf:files[0]).count-1
            let calls=FileCalls()
            func makeCollector() -> CodexQuestionCollector {
                CodexQuestionCollector(fileReader:{ session,_ in calls.record();return paths[session.id].map{[$0]} ?? [] })
            }
            let collector=mode=="cold" ? nil : makeCollector()
            func verify(_ updates: [CodexQuestionUpdate]) throws {
                guard updates.count==count else { throw AppError.message("Synthetic session count changed") }
                for (index,update) in updates.enumerated() {
                    guard update.sessionID==sessions[index].id,update.threadID=="root-\(index)",update.error==nil,
                          update.completionError==nil,update.questions?.count==1,
                          update.questions?.first?.title=="Synthetic question \(index)" else { throw AppError.message("Synthetic collector projection changed") }
                }
            }
            for _ in 0..<2 { try verify(await (collector ?? makeCollector()).collect(sessions)) }
            var elapsed=0.0,consumed=0.0
            for generation in 0..<rounds {
                try autoreleasepool {
                    if mode=="large-change" {
                        for index in files.indices { try header("root-\(index)",large:true,generation:generation+1).write(to:files[index]) }
                    } else if mode=="large-append" {
                        for file in files {
                            let handle=try FileHandle(forWritingTo:file);try handle.seekToEnd()
                            try handle.write(contentsOf:Data("{\"type\":\"synthetic-body\"}\n".utf8));try handle.close()
                        }
                    }
                }
                let active=collector ?? makeCollector()
                let before=cpu(),began=ProcessInfo.processInfo.systemUptime
                let updates=await active.collect(sessions)
                consumed+=cpu()-before;elapsed+=ProcessInfo.processInfo.systemUptime-began
                try verify(updates)
            }
            precondition(calls.count==(rounds+2)*count,"Every collection still resolves current open files")
            phases.append(["name":mode,"rounds":rounds,"sessions":count,"headerBytes":firstHeaderBytes,
                "cpuSeconds":consumed,"wallSeconds":elapsed,"openFileResolutions":calls.count,"verifiedUpdates":rounds*count])
        }
        var usage=rusage();getrusage(RUSAGE_SELF,&usage)
        let report:JSONObject=["phases":phases,"peakResidentBytes":usage.ru_maxrss,"terminalInputs":0,
            "scope":"Actual Release CodexQuestionCollector, synthetic open-file results and isolated JSONL/SQLite files; mutation/verification/setup time excluded."]
        print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),as:UTF8.self))
    }
}
