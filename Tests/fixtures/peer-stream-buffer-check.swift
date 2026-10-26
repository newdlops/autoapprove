import Foundation
import Network
import CryptoKit
import Darwin
import AutoApproveCore

// Observer only. The retained production Core supplies every upstream byte and
// event. Match pumpStream's queue callback and asynchronous sink completion;
// there is no MainActor continuation for each event and no downstream NW send.
private final class QueueDrain: @unchecked Sendable {
    private let stream: any RemoteHTTPBodyStream
    private let initial: Data
    private let check: Bool, candidate: Bool, pause: Bool, cancel: Bool
    private let wireVersion: Int?
    private let queue=DispatchQueue(label:"owned.synthetic.http-consumer")
    private let sourceQueue: DispatchQueue?
    private let completion: @Sendable (Result<[String:Any],Error>)->Void
    // Queue confined. Only one production next() is outstanding.
    private var pending=false,finished=false,events=0,chunks=0,maxChunk=0,bytes=0,checksum:UInt64=0
    private var trace=SHA256(),outputs=[Data](),previous:PeerTailWorker.BufferState?
    private var aliases=0,compactions=0,maxPrefix=0,maxBuffered=0
    init(stream:any RemoteHTTPBodyStream,initial:Data,check:Bool,candidate:Bool,pause:Bool,cancel:Bool,wireVersion:Int? = nil,
         completion:@escaping @Sendable (Result<[String:Any],Error>)->Void) {
        self.stream=stream;self.initial=initial;self.check=check;self.candidate=candidate;self.pause=pause;self.cancel=cancel;self.wireVersion=wireVersion;self.completion=completion
        sourceQueue=check ? PeerTailWorker.owned(stream,"queue",DispatchQueue.self):nil
    }
    func start() {
        queue.async {
            do {
                if !self.initial.isEmpty {try self.consume(self.initial)}
                if self.pause {
                    let before=PeerTailWorker.state(self.stream,self.sourceQueue!)
                    try PeerTailWorker.require(!before.receiving,"Backpressure continued receiving")
                    self.queue.asyncAfter(deadline:.now()+0.15) {
                        do {
                            let after=PeerTailWorker.state(self.stream,self.sourceQueue!)
                            try PeerTailWorker.require(before.count==after.count && before.start==after.start && !after.receiving,"Backpressure changed the Core byte queue")
                            self.beginReads()
                        } catch {self.finish(.failure(error))}
                    }
                } else {self.beginReads()}
            } catch {self.finish(.failure(error))}
        }
    }
    private func beginReads() {if cancel {stream.cancel()};pump()}
    private func pump() {
        guard !finished else{return}
        guard !pending else{finish(.failure(PeerTailWorker.Failure.invalid("Duplicate observer next")));return}
        pending=true
        stream.next { result in
            self.queue.async {
                guard !self.finished else{return};self.pending=false
                do {
                    switch result {
                    case .success(let data):
                        guard let data else {try self.complete(nil);return}
                        try self.consume(data)
                        // Production resumes pumping after asynchronous sink
                        // completion. This observer acknowledges on its queue.
                        self.queue.async {self.pump()}
                    case .failure(let error):
                        if let value=error as? RemoteHTTPError {try self.complete(value)}
                        else {self.finish(.failure(error))}
                    }
                } catch {self.finish(.failure(error))}
            }
        }
    }
    private func records(_ data:Data) throws -> [Range<Int>] {
        try PeerTailWorker.require(data.startIndex==0,"Returned chunk index changed")
        return try data.withUnsafeBytes { (raw:UnsafeRawBufferPointer) in
            var ranges=[Range<Int>](),start=0,index=0
            if let wireVersion {
                while index<raw.count {
                    start=index
                    try PeerTailWorker.require(raw.count-index>=5 && raw[index]==65 && raw[index+1]==65 && raw[index+2]==wireVersion,"Partial binary header")
                    index+=4;var size=0,shift=0
                    while true {
                        try PeerTailWorker.require(index<raw.count && shift<=21,"Partial binary length")
                        let byte=raw[index];index+=1;size |= Int(byte&127)<<shift
                        if byte&128==0 {break};shift+=7
                    }
                    try PeerTailWorker.require(size<=2_000_000 && size<=raw.count-index,"Partial binary body")
                    index+=size;ranges.append(start..<index)
                }
                try PeerTailWorker.require(!ranges.isEmpty && (data.count<=65536 || ranges.count==1),"Invalid binary batch")
                return ranges
            }
            while index+1<raw.count {
                if raw[index]==10 && raw[index+1]==10 {let end=index+2;ranges.append(start..<end);start=end;index=end}
                else {index+=1}
            }
            try PeerTailWorker.require(start==raw.count && !ranges.isEmpty,"Partial/empty forwarded chunk")
            try PeerTailWorker.require(ranges.allSatisfy{$0.count<=2_000_128},"Individual event limit changed")
            try PeerTailWorker.require(data.count<=65536 || ranges.count==1,"A batch over64KiB contained multiple events")
            return ranges
        }
    }
    private func consume(_ data:Data) throws {
        let ranges=try records(data)
        if check {
            for range in ranges {var length=Int64(range.count);withUnsafeBytes(of:&length){trace.update(bufferPointer:$0)};trace.update(data:data.subdata(in:range))}
            outputs.append(data)
            let current=PeerTailWorker.state(stream,sourceQueue!);maxPrefix=max(maxPrefix,current.start);maxBuffered=max(maxBuffered,current.count)
            if candidate {try PeerTailWorker.require(current.count==0 ? current.start==0 : current.start<65536 || current.start<current.count,"Consumed prefix was not bounded")}
            if let before=previous,current.count>0,before.count-data.count==current.count {
                if current.address==before.address+UInt(data.count) && current.start==before.start+data.count {aliases+=1}
                if current.start==0 && before.start+data.count>=65536 {compactions+=1}
            }
            previous=current
        }
        chunks+=1;maxChunk=max(maxChunk,data.count);events+=ranges.count;bytes+=data.count
        for range in ranges {checksum &+= UInt64(range.count)+UInt64(data[range.lowerBound])+UInt64(data[range.upperBound-1])}
    }
    private func complete(_ error:RemoteHTTPError?) throws {
        var result:[String:Any]=["status":200,"events":events,"chunks":chunks,"maxChunk":maxChunk,"bytes":bytes,"checksum":checksum]
        if let error {result["error"]=["status":error.status,"message":error.message,"diagnostics":error.diagnostics ?? [:]]}
        if check {
            let before=trace.finalize().map {String(format:"%02x",$0)}.joined();var after=SHA256()
            for data in outputs {for range in try records(data) {var length=Int64(range.count);withUnsafeBytes(of:&length){after.update(bufferPointer:$0)};after.update(data:data.subdata(in:range))}}
            try PeerTailWorker.require(after.finalize().map {String(format:"%02x",$0)}.joined()==before,"Retained event bytes changed after later reads")
            result["trace"]=before;result["aliases"]=aliases;result["compactions"]=compactions;result["maxPrefix"]=maxPrefix;result["maxBuffered"]=maxBuffered
            result["initialBytes"]=initial.count;result["callerOutputsRetainedExactly"]=true
        }
        finish(.success(result))
    }
    private func finish(_ result:Result<[String:Any],Error>) {guard !finished else{return};finished=true;completion(result)}
}

@main struct PeerTailWorker {
    enum Failure: Error { case invalid(String) }
    static let owner="11111111-1111-4111-8111-111111111111"
    static func require(_ value:Bool,_ reason:String) throws {if !value {throw Failure.invalid(reason)}}
    static func emit(_ value:[String:Any]) throws {print(String(decoding:try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),as:UTF8.self));fflush(stdout)}
    static func owned<T>(_ object:Any,_ label:String,_ type:T.Type)->T? {
        guard let raw=Mirror(reflecting:object).children.first(where:{$0.label==label})?.value else{return nil}
        return (raw as? T) ?? Mirror(reflecting:raw).children.first?.value as? T
    }
    struct BufferState {let count:Int,start:Int,address:UInt,receiving:Bool}
    static func state(_ stream:Any,_ queue:DispatchQueue)->BufferState {
        queue.sync {
            let data=owned(stream,"buffer",Data.self)!
            let address=data.withUnsafeBytes {bytes in bytes.baseAddress.map {UInt(bitPattern:$0)} ?? 0}
            return BufferState(count:data.count,start:data.startIndex,address:address,receiving:owned(stream,"receiving",Bool.self) ?? false)
        }
    }
    @MainActor static func main() async throws {
        let args=CommandLine.arguments,url=args[1],home=URL(fileURLWithPath:args[2]),candidate=args[3]=="candidate"
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:[["id":owner,"name":"Synthetic upstream","address":url]]).write(to:home.appendingPathComponent("web-peers.json"))
        let power=PowerControl(read:{PowerReading()},ruleInstalled:{false},ruleFile:{false},installRule:{throw Failure.invalid("Power mutation forbidden")},removeRule:{throw Failure.invalid("Power mutation forbidden")},setSleepDisabled:{_ in throw Failure.invalid("Power mutation forbidden")},startGuard:{_,_ in throw Failure.invalid("Power guard forbidden")})
        let engine=try ApprovalEngine(paths:AppPaths(directory:home),processReader:{[]},screenAdapters:[:],powerControl:power)
        let service=RemoteNetworkService(engine:engine,nodeID:"22222222-2222-4222-8222-222222222222",name:"Synthetic gateway",bonjourEnabled:false,discoveryAddresses:{[]},discoveryHints:{[]},onStatus:{_ in})
        try service.start(port:0)
        guard let acceptor=owned(service,"listener",NWListener.self) else{throw Failure.invalid("Owned acceptor missing")}
        acceptor.cancel();owned(service,"discoveryTask",Task<Void,Never>.self)?.cancel();owned(service,"pathMonitor",NWPathMonitor.self)?.cancel()
        for monitor in owned(service,"interfaceMonitors",[NWPathMonitor].self) ?? [] {monitor.cancel()}
        defer {service.stop();withExtendedLifetime(engine){}}

        func run(_ mode:String,check:Bool=false,pause:Bool=false,cancel:Bool=false,wireVersion:Int? = nil) async throws -> [String:Any] {
            let wire=wireVersion.map { "&wire=\($0)" } ?? ""
            let request=try RemoteHTTPRequest.parse(Data(("GET /api/terminal/stream?node="+owner+"&session=synthetic&mode="+mode+wire+" HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n").utf8))!
            let response=await service.handle(request)
            guard response.status==200,let stream=response.stream else{return ["status":response.status,"events":0,"bytes":0,"checksum":0]}
            defer {stream.cancel()}
            return try await withCheckedThrowingContinuation { continuation in
                QueueDrain(stream:stream,initial:response.body,check:check,candidate:candidate,pause:pause,cancel:cancel,
                    wireVersion:response.contentType.hasSuffix("terminal-v3") ? 3 : response.contentType.hasSuffix("terminal-v2") ? 2:nil) {
                    continuation.resume(with:$0)
                }.start()
            }
        }
        try emit(["ready":true,"actualCorePublicHandler":true,"ownedAcceptorCancelled":true])
        while let line=readLine() {
            let input=try JSONSerialization.jsonObject(with:Data(line.utf8)) as! [String:Any],id=input["id"] as! String,mode=input["mode"] as! String
            if input["check"] as? Bool==true {
                var result=try await run(mode,check:true,pause:input["pause"] as? Bool ?? false,cancel:input["cancel"] as? Bool ?? false,wireVersion:input["wireVersion"] as? Int);result["id"]=id;result["mode"]=mode;try emit(result);continue
            }
            throw Failure.invalid("Only functional check requests are accepted")
        }
    }
}
