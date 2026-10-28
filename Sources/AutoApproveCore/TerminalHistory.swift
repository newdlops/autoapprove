import Foundation
import Darwin

public struct TerminalHistoryPage:Codable,Sendable {
    public let sessionID:String
    public let snapshot:String
    public let page:Int
    public let pageCount:Int
    public let totalBytes:Int
    public let totalLines:Int
    public let capturedAt:String
    public let text:String
}

private struct TerminalHistorySnapshot:Sendable {
    let id:String,sessionID:String,source:String,capturedAt:String
    let file:URL
    let offsets:[UInt64]
    let totalBytes:Int,totalLines:Int
}

/// Files contain only explicit snapshots, not a background terminal recorder.
private final class TerminalHistoryFiles:@unchecked Sendable {
    let directory:URL
    private let lock=NSLock()
    private var owned=Set<URL>()
    init(_ directory:URL) throws {
        self.directory=directory
        var info=stat()
        if lstat(directory.path,&info)==0 {
            guard info.st_mode&S_IFMT==S_IFDIR,info.st_uid==getuid() else {throw AppError.message("터미널 기록 캐시 폴더를 확인해주세요.")}
        } else {try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}
        // This dedicated cache is not a transcript archive. Remove only our own
        // UUID-named files left by an earlier app exit, without following links.
        for file in try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil) {
            if file.pathExtension=="utf8",UUID(uuidString:file.deletingPathExtension().lastPathComponent) != nil {try? FileManager.default.removeItem(at:file)}
        }
    }
    deinit {for file in owned {try? FileManager.default.removeItem(at:file)}}
    func remove(_ file:URL) {lock.lock();owned.remove(file);lock.unlock();try? FileManager.default.removeItem(at:file)}
    func store(_ text:String,source:String,sessionID:String,at:Date,limit:Int) throws -> TerminalHistorySnapshot {
        try Task.checkCancellation()
        let value=text as NSString
        guard value.length<=limit else {throw RemoteHTTPError(413,"기록이 너무 큽니다. Terminal의 보관 범위를 확인해주세요.")}
        let id=UUID().uuidString.lowercased(),file=directory.appendingPathComponent(id+".utf8")
        let fd=open(file.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
        guard fd>=0 else {throw AppError.message("터미널 기록을 임시로 저장하지 못했습니다.")}
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        lock.lock();owned.insert(file);lock.unlock()
        var succeeded=false
        defer {try? handle.close();if !succeeded {remove(file)}}
        var position=0,bytes=0,lines=0,last:UInt8?,offsets:[UInt64]=[]
        var buffer=[UniChar](repeating:0,count:16_384)
        while position<value.length {
            try Task.checkCancellation()
            var count=min(buffer.count,value.length-position)
            if position+count<value.length,(0xD800...0xDBFF).contains(value.character(at:position+count-1)) {count-=1}
            value.getCharacters(&buffer,range:NSRange(location:position,length:count))
            var breaks=0
            for index in 0..<count where buffer[index]==10 {
                breaks+=1
                if breaks==512 {count=index+1;break}
            }
            let data=Data(String(decoding:buffer.prefix(count),as:UTF16.self).utf8)
            guard bytes<=limit-data.count else {throw RemoteHTTPError(413,"기록이 너무 큽니다. Terminal의 보관 범위를 확인해주세요.")}
            offsets.append(UInt64(bytes));try handle.write(contentsOf:data)
            bytes+=data.count;lines+=data.reduce(0) {$0+($1==10 ? 1:0)};last=data.last;position+=count
        }
        if offsets.isEmpty {offsets=[0]}
        if bytes>0,last != 10 {lines+=1}
        succeeded=true
        return .init(id:id,sessionID:sessionID,source:source,capturedAt:ISO8601DateFormatter().string(from:at),file:file,offsets:offsets,totalBytes:bytes,totalLines:lines)
    }
    func read(_ snapshot:TerminalHistorySnapshot,page:Int) throws -> String {
        let start=snapshot.offsets[page],end=page+1<snapshot.offsets.count ? snapshot.offsets[page+1]:UInt64(snapshot.totalBytes)
        let fd=open(snapshot.file.path,O_RDONLY|O_NOFOLLOW)
        guard fd>=0 else {throw RemoteHTTPError(410,"기록 보관 시간이 지났습니다. 새로고침해 다시 불러와주세요.")}
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true);defer {try? handle.close()}
        try handle.seek(toOffset:start)
        let data=try handle.read(upToCount:Int(end-start)) ?? Data()
        guard data.count==Int(end-start),let text=String(data:data,encoding:.utf8) else {throw AppError.message("터미널 기록을 읽지 못했습니다. 다시 불러와주세요.")}
        return text
    }
}

/// Cold, on-demand work runs away from the UI and live terminal producer.
/// At most one source capture, four snapshots and 512 MiB of completed files.
public actor TerminalHistoryStore {
    private struct Entry {let snapshot:TerminalHistorySnapshot;var touched:Date}
    private let directory:URL
    private let lifetime:TimeInterval
    private let maximumBytes:Int
    private let clock:@Sendable ()->Date
    private var files:TerminalHistoryFiles?
    private var entries:[String:Entry]=[:],latest:[String:String]=[:]
    private var pending:(source:String,id:UUID,task:Task<TerminalHistorySnapshot,Error>)?
    private var stopped=false
    public init(directory:URL,lifetime:TimeInterval=600,maximumBytes:Int=512*1024*1024,clock:@escaping @Sendable ()->Date={Date()}) {
        self.directory=directory;self.lifetime=lifetime;self.maximumBytes=maximumBytes;self.clock=clock
    }
    private func discard(_ id:String) {
        guard let entry=entries.removeValue(forKey:id) else {return}
        if latest[entry.snapshot.source]==id {latest.removeValue(forKey:entry.snapshot.source)}
        files?.remove(entry.snapshot.file)
    }
    public func page(sessionID:String,source:String,snapshot id:String?=nil,page requested:Int?=nil,refresh:Bool=false,
                     capture:@escaping @Sendable () throws -> String) async throws -> TerminalHistoryPage {
        guard !stopped else {throw RemoteHTTPError(410,"터미널 기록 연결이 종료됐습니다.")}
        let now=clock()
        for (key,entry) in entries where now.timeIntervalSince(entry.touched)>lifetime {discard(key)}
        let value:TerminalHistorySnapshot
        if let id {
            guard UUID(uuidString:id) != nil,let entry=entries[id],entry.snapshot.source==source,entry.snapshot.sessionID==sessionID else {throw RemoteHTTPError(410,"기록 연결이 바뀌었거나 보관 시간이 지났습니다. 새로고침해주세요.")}
            value=entry.snapshot
        } else if !refresh,let id=latest[source],let cached=entries[id] {value=cached.snapshot}
        else {
            let task:Task<TerminalHistorySnapshot,Error>,ticket:UUID
            if let pending {
                guard pending.source==source else {throw RemoteHTTPError(503,"다른 터미널의 기록을 읽고 있습니다. 잠시 후 다시 시도해주세요.")}
                task=pending.task;ticket=pending.id
            } else {
                if files==nil {files=try TerminalHistoryFiles(directory)}
                let files=files!,limit=maximumBytes
                ticket=UUID()
                task=Task.detached(priority:.utility) {try files.store(capture(),source:source,sessionID:sessionID,at:now,limit:limit)}
                pending=(source,ticket,task)
            }
            do {value=try await task.value}
            catch {if pending?.id==ticket {pending=nil};throw error}
            guard !stopped else {files?.remove(value.file);throw CancellationError()}
            // Only the first resumed waiter publishes. A late coalesced waiter
            // cannot replace a newer refresh with its preceding snapshot.
            if pending?.id==ticket {
                pending=nil;entries[value.id]=Entry(snapshot:value,touched:now);latest[source]=value.id
                while entries.count>4 || entries.values.reduce(0,{$0+$1.snapshot.totalBytes})>maximumBytes {
                    guard let oldest=entries.filter({$0.key != value.id}).min(by:{$0.value.touched<$1.value.touched})?.key else {break}
                    discard(oldest)
                }
            }
            guard entries[value.id] != nil else {throw RemoteHTTPError(410,"기록 보관 시간이 지났습니다. 다시 불러와주세요.")}
        }
        let page=requested ?? value.offsets.count-1
        guard page>=0,page<value.offsets.count else {throw RemoteHTTPError(400,"터미널 기록의 구간을 확인해주세요.")}
        entries[value.id]?.touched=clock()
        guard let files else {throw CancellationError()}
        let text=try files.read(value,page:page)
        return .init(sessionID:sessionID,snapshot:value.id,page:page,pageCount:value.offsets.count,totalBytes:value.totalBytes,totalLines:value.totalLines,capturedAt:value.capturedAt,text:text)
    }
    public func stop() {
        stopped=true;pending?.task.cancel();pending=nil
        for id in Array(entries.keys) {discard(id)}
        files=nil
    }
}
