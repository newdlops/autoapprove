import Foundation
import Dispatch
import Darwin
import zlib
import AutoApproveCore

@main enum GzipScopedScratchCheck {
    enum Failure:Error{case invalid(String)}
    static func require(_ condition:Bool,_ message:String)throws{if !condition{throw Failure.invalid(message)}}
    static func emit(_ value:[String:Any])throws{print(String(decoding:try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),as:UTF8.self));fflush(stdout)}
    struct Reader{
        let data:Data;var offset=0
        mutating func bytes(_ count:Int)throws->Data{try require(count>=0 && count<=data.count-offset,"Invalid corpus span");defer{offset+=count};return data.subdata(in:offset..<(offset+count))}
        mutating func number()throws->Int{let value=try bytes(4);return value.enumerated().reduce(0){$0 | Int($1.element) << (8*$1.offset)}}
    }
    struct Group{let name:String,events:[(Bool,Data)]}
    static func load(_ path:String,_ magic:String)throws->[Group]{
        var reader=Reader(data:try Data(contentsOf:URL(fileURLWithPath:path)));try require(try reader.bytes(4)==Data(magic.utf8),"Wrong corpus magic")
        let count=try reader.number();try require(count>0 && count<=64,"Wrong group count");var groups:[Group]=[]
        for _ in 0..<count{
            let length=try reader.number();try require(length>0 && length<=128,"Invalid name length");let name=String(decoding:try reader.bytes(length),as:UTF8.self)
            let count=try reader.number();try require(count>0 && count<=256,"Invalid event count");var values:[(Bool,Data)]=[]
            for index in 0..<count{let final=try reader.number(),size=try reader.number();try require(final<=1 && size<=2_200_000 && (final==1)==(index+1==count),"Invalid event metadata");values.append((final==1,try reader.bytes(size)))}
            groups.append(Group(name:name,events:values))
        }
        try require(reader.offset==reader.data.count,"Trailing corpus data");return groups
    }
    static func put(_ value:Int,_ data:inout Data){var number=UInt32(value).littleEndian;withUnsafeBytes(of:&number){data.append(contentsOf:$0)}}
    static func saved(_ groups:[Group]) -> Data{
        var output=Data("AGZ2".utf8);put(groups.count,&output)
        for group in groups{let name=Data(group.name.utf8);put(name.count,&output);output.append(name);put(group.events.count,&output);for(final,data)in group.events{put(final ? 1:0,&output);put(data.count,&output);output.append(data)}}
        return output
    }
    static func pointersCleared(_ encoder:RemoteGzipEncoder)throws{
        guard let value=Mirror(reflecting:encoder).children.first(where:{$0.label=="stream"})?.value as? UnsafeMutablePointer<z_stream> else{throw Failure.invalid("Missing actual encoder C stream")}
        try require(value.pointee.next_in==nil && value.pointee.next_out==nil,"C buffers escaped an encode call")
    }
    static func expectHTTP<T>(_ status:Int,_ body:()throws->T)throws{
        do{_ = try body();throw Failure.invalid("Expected HTTP error")}catch let error as RemoteHTTPError{try require(error.status==status,"Wrong error status")}
    }
    static func guards()throws{
        for level in [Int32(-1),0,10,Int32.max]{try expectHTTP(500){try RemoteGzipEncoder(level:level)}}
        let first=try RemoteGzipEncoder(),second=try RemoteGzipEncoder(),prefix=Data("event: screen\ndata: fixture\n\n".utf8)
        try require(try first.encode(prefix)==second.encode(prefix),"Equal initial streams differ");try pointersCleared(first)
        try expectHTTP(502){try first.encode(Data(repeating:1,count:2_100_001))};try pointersCleared(first)
        try require(try first.encode(Data("next".utf8))==second.encode(Data("next".utf8)),"Oversized rejection changed stream state")
        _ = try first.encode(Data(),final:true);try pointersCleared(first);try expectHTTP(502){try first.encode(Data("late".utf8))};try pointersCleared(first)
    }
    static func bytes(_ corpusPath:String,_ referencePath:String,_ outputPath:String,_ level:Int32)throws{
        try guards();let corpus=try load(corpusPath,"AGZ1"),reference:[Group]?
        if referencePath=="-"{reference=nil}else{reference=try load(referencePath,"AGZ2")}
        if let reference{try require(reference.count==corpus.count,"Reference group count differs")}
        var compressedGroups:[Group]=[],events=0,total=0
        for(index,group)in corpus.enumerated(){
            let encoder=try RemoteGzipEncoder(level:level),decoder=try RemoteGzipDecoder();var originals=Data(),chunks:[(Bool,Data)]=[]
            if let reference{try require(reference[index].name==group.name && reference[index].events.count==group.events.count,"Reference metadata differs")}
            for(eventIndex,event)in group.events.enumerated(){
                let(final,data)=event,compressed=try encoder.encode(data,final:final);try pointersCleared(encoder)
                if let reference{try require(reference[index].events[eventIndex].0==final && reference[index].events[eventIndex].1==compressed,"Compressed event bytes changed")}
                var decoded=Data()
                for offset in stride(from:0,to:compressed.count,by:65_536){
                    try decoder.append(compressed.subdata(in:offset..<min(offset+65_536,compressed.count)))
                    while !decoder.needsInput && !decoder.ended{decoded.append(try decoder.read())}
                }
                try require(decoded==data,"Flush did not yield the exact original event");try require(decoder.ended==final,"Unexpected gzip footer state")
                originals.append(data);chunks.append((final,compressed));total+=compressed.count;events+=1
            }
            try decoder.finish();var complete=Data();for(_,chunk)in chunks{complete.append(chunk)}
            try require(try RemoteGzipDecoder.complete(complete)==originals,"Retained output changed or complete decode failed")
            if let reference{for event in chunks.indices{try require(chunks[event].1==reference[index].events[event].1,"Retained prior output bytes changed")}}
            compressedGroups.append(Group(name:group.name,events:chunks))
        }
        try saved(compressedGroups).write(to:URL(fileURLWithPath:outputPath),options:.atomic)
        try emit(["passed":true,"actualCompiledCore":true,"level":level,"groups":corpus.count,"events":events,"outputBytes":total,"exactReferenceCompared":reference != nil,"incrementalAndCompleteDecodeExact":true,"retainedChunksChecked":true,"pointerCleanupChecked":true,"guardRecoveryChecked":true])
    }
    final class ThreadResult:@unchecked Sendable{
        private let lock=NSLock();private var value:Result<[String:Int],Error>?
        func set(_ result:Result<[String:Int],Error>){lock.lock();value=result;lock.unlock()}
        func get()throws->[String:Int]{lock.lock();defer{lock.unlock()};guard let value else{throw Failure.invalid("Owned thread did not finish")};return try value.get()}
    }
    static func limitedStack()throws{
        let box=ThreadResult(),done=DispatchSemaphore(value:0)
        let thread=Thread{
            defer{done.signal()}
            do{
                let size=Int(pthread_get_stacksize_np(pthread_self()));try require(size<=256*1024,"Requested limited stack was not applied")
                let input=Data((0..<131072).map{UInt8(truncatingIfNeeded:$0 &* 17)}),encoder=try RemoteGzipEncoder();var compressed=try encoder.encode(input);try pointersCleared(encoder)
                compressed.append(try encoder.encode(Data(),final:true));try pointersCleared(encoder);try require(try RemoteGzipDecoder.complete(compressed)==input,"Limited stack output changed")
                box.set(.success(["requestedStackBytes":128*1024,"actualStackBytes":size,"inputBytes":input.count,"encodedBytes":compressed.count]))
            }catch{box.set(.failure(error))}
        }
        thread.stackSize=128*1024;thread.start();try require(done.wait(timeout:.now()+30) == .success,"Limited stack thread timed out")
        try emit(["passed":true,"actualCompiledCore":true,"limitedStack":try box.get(),"pointerCleanupChecked":true,"originalTerminalActions":0,"realPowerCommands":0])
    }
    static func heap()->Int{var value=malloc_statistics_t();malloc_zone_statistics(nil,&value);return Int(value.size_in_use)}
    static func resident()->UInt64{var value=rusage_info_v4();let result=withUnsafeMutablePointer(to:&value){$0.withMemoryRebound(to:rusage_info_t?.self,capacity:1){proc_pid_rusage(getpid(),RUSAGE_INFO_V4,$0)}};return result==0 ? value.ri_resident_size:0}
    static func memory(_ level:Int32,_ count:Int)throws{
        try require((0...64).contains(count),"Invalid live encoder count");let data=Data("event: alive\ndata: {\"streamID\":\"fixture\",\"revision\":\"fixed\"}\n\n".utf8)
        for _ in 0..<8{try autoreleasepool{let value=try RemoteGzipEncoder(level:level);_ = try value.encode(data);try pointersCleared(value);_ = try value.encode(Data(),final:true)}}
        var values:[RemoteGzipEncoder]=[];values.reserveCapacity(count);let before=heap(),rssBefore=resident();var bytes=0
        for _ in 0..<count{let value=try RemoteGzipEncoder(level:level);bytes+=try value.encode(data).count;values.append(value)}
        let live=withExtendedLifetime(values){heap()},rssLive=withExtendedLifetime(values){resident()}
        for value in values{try pointersCleared(value)}
        values.removeAll(keepingCapacity:false);let after=heap()
        try require(live>=before && (count==0 || live-before>count*200_000),"Live allocation metrics do not cover compressor state")
        try emit(["passed":true,"actualCompiledCore":true,"level":level,"count":count,"beforeHeap":before,"liveHeap":live,"retainedHeap":live-before,"afterReleaseHeap":after,"afterReleaseGrowth":after-before,"rssBefore":rssBefore,"rssLive":rssLive,"encodedBytes":bytes,"memoryScope":"Live malloc heap held after initial flush;RSS diagnostic only.","pointerCleanupChecked":true])
    }
    static func metrics()throws->[String:Any]{
        var usage=rusage(),info=rusage_info_v4();try require(getrusage(RUSAGE_SELF,&usage)==0,"Self rusage failed")
        let result=withUnsafeMutablePointer(to:&info){$0.withMemoryRebound(to:rusage_info_t?.self,capacity:1){proc_pid_rusage(getpid(),RUSAGE_INFO_V4,$0)}};try require(result==0,"Self instruction counter unavailable")
        return ["cpu":Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)+Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1e6,"instructions":info.ri_instructions,"cycles":info.ri_cycles,"rss":info.ri_resident_size,"heapBytes":heap()]
    }
    final class Workload{
        let encoder:RemoteGzipEncoder,frames:[Data];var index=0
        init(_ frames:[Data])throws{self.frames=frames;encoder=try RemoteGzipEncoder()}
    }
    static func workloads()throws->[String:Workload]{
        let heartbeat=Data(": keepalive\n\n".utf8),metadata=(0..<24).map{Data("event: alive\ndata: {\"streamID\":\"fixture-stream\",\"revision\":\"stable\",\"sequence\":\($0),\"observedAt\":\"2026-10-25T00:00:\(String(format:"%02d",$0))Z\"}\n\n".utf8)}
        let ansi=(0..<24).map{Data((String(repeating:"\u{1b}[32m한글🙂 /fixture/main.swift\u{1b}[0m\n",count:40)+"frame \($0)\n").utf8)},patch=(0..<24).map{Data("event: screen\ndata: {\"streamID\":\"fixture-stream\",\"screenPatch\":{\"baseRevision\":\"r\($0)\",\"offset\":1024,\"removed\":1,\"text\":\"fixture \($0)\"}}\n\n".utf8)}
        var seed:UInt32=0x19791025;let opaque=(0..<24).map{_ -> Data in Data((0..<32768).map{_ -> UInt8 in seed ^= seed << 13;seed ^= seed >> 17;seed ^= seed << 5;return UInt8(truncatingIfNeeded:seed)})}
        return ["heartbeat":try Workload([heartbeat]),"metadata":try Workload(metadata),"ansi":try Workload(ansi),"patch":try Workload(patch),"opaque32768":try Workload(opaque),"mixed":try Workload([heartbeat,metadata[0],ansi[0],patch[0],opaque[0],metadata[1]])]
    }
    @inline(never) static func measure(_ value:Workload,_ count:Int)throws->(UInt64,Int){
        var checksum:UInt64=0,bytes=0
        for _ in 0..<count{let data=try value.encoder.encode(value.frames[value.index%value.frames.count]);value.index+=1;bytes+=data.count;checksum=checksum &* 1099511628211 ^ UInt64(data.count) ^ UInt64(data.first ?? 0) ^ UInt64(data.last ?? 0)}
        try pointersCleared(value.encoder);return(checksum,bytes)
    }
    static func bench()throws{
        let values=try workloads();for value in values.values{_ = try measure(value,32)}
        try emit(["ready":true,"actualCompiledCore":true,"pointerCleanupChecked":true,"originalTerminalActions":0,"realPowerCommands":0])
        while let line=readLine(){let request=try JSONSerialization.jsonObject(with:Data(line.utf8)) as! [String:Any];if request["command"] as? String=="stop"{break}
            let mode=request["mode"] as! String,count=request["iterations"] as! Int;guard let value=values[mode]else{throw Failure.invalid("Unknown codec workload")}
            let before=try metrics(),start=ProcessInfo.processInfo.systemUptime,result=try autoreleasepool{try measure(value,count)},wall=ProcessInfo.processInfo.systemUptime-start,after=try metrics()
            try emit(["id":request["id"]!,"mode":mode,"iterations":count,"checksum":String(result.0),"encodedBytes":result.1,"before":before,"after":after,"wall":wall])
        }
    }
    static func main()throws{
        let args=CommandLine.arguments
        switch args[1]{
        case "bytes":try bytes(args[2],args[3],args[4],Int32(args[5])!)
        case "stack":try limitedStack()
        case "memory":try memory(Int32(args[2])!,Int(args[3])!)
        case "bench":try bench()
        default:throw Failure.invalid("Unknown gzip check mode")
        }
    }
}
