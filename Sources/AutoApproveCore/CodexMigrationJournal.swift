import Foundation
import CryptoKit
import Darwin

/// A duplicate of the journal's already-held kernel lock. Only the journal can
/// create it; descriptor transfer keeps the same open-file lock alive if its
/// original owner closes. This does not grant permission to migrate data.
final class CodexMigrationLockDescriptor:@unchecked Sendable {
    let home:String,homeIdentity:String,requestID:String,revision:Int,digest:String
    private let fd:Int32
    fileprivate init(fd:Int32,home:CodexMigrationJournalRecord.Home,record:CodexMigrationJournalRecord) {
        self.fd=fd;self.home=home.path;homeIdentity=home.identity
        requestID=record.id;revision=record.revision;digest=record.digest
    }
    deinit{Darwin.close(fd)}
    func withDescriptor<T>(_ body:(Int32)throws->T)rethrows->T {try body(fd)}
}

// Internal storage only: native effects must never run from a record unless
// the central authority and both private mirrors are consistent.
struct CodexMigrationJournalRecord:Codable,Equatable {
    struct Home:Codable,Equatable {let path:String,identity:String}
    let formatVersion:Int,id:String,revision:Int,homes:[Home],payload:Data
    let previousDigest:String?,terminal:Bool,digest:String
    let ownership:[CodexMigrationOwnerChange]?
    private struct Body:Codable {
        let formatVersion:Int,id:String,revision:Int,homes:[Home],payload:Data
        let previousDigest:String?,terminal:Bool
        let ownership:[CodexMigrationOwnerChange]?
    }
    private var body:Body {.init(formatVersion:formatVersion,id:id,revision:revision,homes:homes,payload:payload,previousDigest:previousDigest,terminal:terminal,ownership:ownership)}
    fileprivate static func serialized<T:Encodable>(_ value:T)throws->Data {let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return try e.encode(value)}
    private static func hash(_ body:Body)throws->String {SHA256.hash(data:try serialized(body)).map{String(format:"%02x",$0)}.joined()}
    fileprivate init(id:String,revision:Int,homes:[Home],payload:Data,previousDigest:String?,terminal:Bool,ownership:[CodexMigrationOwnerChange]?=nil)throws {
        formatVersion=ownership==nil ? 1:2;self.id=id;self.revision=revision;self.homes=homes;self.payload=payload;self.previousDigest=previousDigest;self.terminal=terminal;self.ownership=ownership
        digest=try Self.hash(Body(formatVersion:formatVersion,id:id,revision:revision,homes:homes,payload:payload,previousDigest:previousDigest,terminal:terminal,ownership:ownership))
    }
    fileprivate func validate() throws {
        guard formatVersion==(ownership==nil ? 1:2),UUID(uuidString:id)?.uuidString.lowercased()==id,revision>0,revision<Int.max,
              homes.count==2,homes.map(\.path)==homes.map(\.path).sorted(),Set(homes.map(\.identity)).count==2,
              homes.allSatisfy({$0.path.hasPrefix("/") && $0.path.utf8.count<=4096 && !$0.path.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) && !$0.identity.isEmpty && $0.identity.count<=128}),
              payload.count<=8*1024*1024,digest == (try Self.hash(body)),
              revision==1 ? previousDigest==nil:previousDigest?.count==64 else{throw CodexMigrationJournal.failure}
        if let ownership {
            guard terminal,!ownership.isEmpty,ownership.count<=512,Set(ownership.map(\.threadID)).count==ownership.count else{throw CodexMigrationJournal.failure}
            for change in ownership {
                guard UUID(uuidString:change.threadID)?.uuidString.lowercased()==change.threadID,homes.contains(change.destination) else{throw CodexMigrationJournal.failure}
                if let previous=change.previous {
                    try previous.validate()
                    guard previous.threadID==change.threadID,homes.contains(previous.home),previous.home != change.destination else{throw CodexMigrationJournal.failure}
                }
                if let retired=change.retirement {
                    try retired.validate()
                    let source=Home(path:retired.goal.sourceHome,identity:retired.goal.homeIdentity)
                    guard retired.goal.threadID==change.threadID,homes.contains(source),source != change.destination,
                          change.previous.map({$0.home==source}) ?? true else{throw CodexMigrationJournal.failure}
                }
            }
        }
    }
}

// These are journal-backed storage facts, not native ownership observations.
// Only a future verified native completion path may publish these in production.
struct CodexMigrationOwner:Codable,Equatable {
    let threadID:String,revision:Int,home:CodexMigrationJournalRecord.Home,journalID:String,journalDigest:String
    fileprivate func validate()throws {
        guard UUID(uuidString:threadID)?.uuidString.lowercased()==threadID,revision>0,revision<Int.max,
              UUID(uuidString:journalID)?.uuidString.lowercased()==journalID,journalDigest.count==64,
              home.path.hasPrefix("/"),home.path.utf8.count<=4096,!home.identity.isEmpty,home.identity.count<=128 else{throw CodexMigrationJournal.failure}
    }
    fileprivate static func after(_ change:CodexMigrationOwnerChange,_ record:CodexMigrationJournalRecord)throws->Self {
        let previous=change.previous?.revision ?? 0
        guard previous<Int.max-1 else{throw CodexMigrationJournal.failure}
        return .init(threadID:change.threadID,revision:previous+1,home:change.destination,journalID:record.id,journalDigest:record.digest)
    }
}
struct CodexMigrationOwnerChange:Codable,Equatable {
    let threadID:String,previous:CodexMigrationOwner?,destination:CodexMigrationJournalRecord.Home
    var retirement:CodexMigrationRetirement?=nil
}

final class CodexMigrationJournal {
    struct Loaded {let record:CodexMigrationJournalRecord,consistent:Bool}
    fileprivate static var failure:AppError {.message("이관 저널의 소유권·순서·사본을 확인하지 못했습니다. 기존 명령을 반복하지 않습니다.")}
    private let store:AuditStore
    private var leases:[String:[HomeHandle]]=[:]
    private static let folder=".autoapprove-migrations"
    init(store:AuditStore)throws {self.store=store;try store.prepareMigrationJournal()}
    private static func id(_ value:String)throws->String {guard let id=UUID(uuidString:value) else{throw failure};return id.uuidString.lowercased()}
    private static func identity(_ info:stat)->String {"\(info.st_dev):\(info.st_ino)"}
    private static func home(_ path:String)throws->CodexMigrationJournalRecord.Home {
        let validated=try CodexAccountTransitionTarget.canonicalHome(path)
        guard let pointer=realpath(validated,nil) else{throw failure};defer{free(pointer)}
        let physical=String(cString:pointer);var info=stat()
        guard lstat(physical,&info)==0,info.st_mode&S_IFMT==S_IFDIR,info.st_uid==getuid() else{throw failure}
        return .init(path:physical,identity:identity(info))
    }
    private final class HomeHandle {
        let ref:CodexMigrationJournalRecord.Home
        var homeFD:Int32 = -1,dirFD:Int32 = -1,lockFD:Int32 = -1
        private var closed=false
        init(_ ref:CodexMigrationJournalRecord.Home,create:Bool,lock:Bool)throws {
            self.ref=ref
            do {
                homeFD=open(ref.path,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW)
                var info=stat();guard homeFD>=0,fstat(homeFD,&info)==0,CodexMigrationJournal.identity(info)==ref.identity,info.st_uid==getuid() else{throw failure}
                if create,mkdirat(homeFD,folder,0o700) != 0,errno != EEXIST{throw failure}
                dirFD=openat(homeFD,folder,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW)
                guard dirFD>=0,fstat(dirFD,&info)==0,info.st_uid==getuid(),info.st_mode&0o077==0 else{throw failure}
                if lock {
                    lockFD=openat(dirFD,"lock",O_RDWR|O_CREAT|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK,0o600)
                    guard lockFD>=0,fstat(lockFD,&info)==0,info.st_mode&S_IFMT==S_IFREG,info.st_uid==getuid(),info.st_mode&0o077==0,
                          flock(lockFD,LOCK_EX|LOCK_NB)==0 else{throw failure}
                }
                try check()
            }catch{closeAll();throw error}
        }
        deinit{closeAll()}
        private func closeAll(){guard !closed else{return};closed=true;for fd in [lockFD,dirFD,homeFD] where fd>=0{Darwin.close(fd)}}
        func check()throws {
            guard try CodexMigrationJournal.home(ref.path)==ref else{throw failure}
            var pathInfo=stat(),fdInfo=stat()
            guard fstatat(homeFD,folder,&pathInfo,AT_SYMLINK_NOFOLLOW)==0,fstat(dirFD,&fdInfo)==0,
                  pathInfo.st_mode&S_IFMT==S_IFDIR,CodexMigrationJournal.identity(pathInfo)==CodexMigrationJournal.identity(fdInfo) else{throw failure}
            if lockFD>=0 {
                guard fstatat(dirFD,"lock",&pathInfo,AT_SYMLINK_NOFOLLOW)==0,fstat(lockFD,&fdInfo)==0,
                      pathInfo.st_mode&S_IFMT==S_IFREG,CodexMigrationJournal.identity(pathInfo)==CodexMigrationJournal.identity(fdInfo) else{throw failure}
            }
        }
        func read(_ name:String)throws->CodexMigrationJournalRecord? {
            try check()
            let fd=openat(dirFD,name,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK)
            if fd<0{if errno==ENOENT{return nil};throw failure};defer{Darwin.close(fd)}
            var before=stat();guard fstat(fd,&before)==0,before.st_mode&S_IFMT==S_IFREG,before.st_uid==getuid(),before.st_mode&0o077==0,
                  before.st_size>0,before.st_size<=12*1024*1024 else{throw failure}
            var data=Data(count:Int(before.st_size)),offset=0
            try data.withUnsafeMutableBytes{buffer in
                while offset<buffer.count {
                    let count=Darwin.read(fd,buffer.baseAddress!.advanced(by:offset),buffer.count-offset)
                    if count<0,errno==EINTR{continue};guard count>0 else{throw failure};offset+=count
                }
            }
            var after=stat();guard fstat(fd,&after)==0,before.st_size==after.st_size,
                  before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec,before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec else{throw failure}
            try check();let record=try JSONDecoder().decode(CodexMigrationJournalRecord.self,from:data);try record.validate();return record
        }
        func write(_ record:CodexMigrationJournalRecord,to name:String)throws {
            try check();let data=try CodexMigrationJournalRecord.serialized(record)
            guard data.count<=12*1024*1024 else{throw failure}
            let temporary="."+UUID().uuidString+".tmp",fd=openat(dirFD,temporary,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,0o600)
            guard fd>=0 else{throw failure};defer{Darwin.close(fd);unlinkat(dirFD,temporary,0)}
            var offset=0
            try data.withUnsafeBytes{buffer in
                while offset<buffer.count {
                    let count=Darwin.write(fd,buffer.baseAddress!.advanced(by:offset),buffer.count-offset)
                    if count<0,errno==EINTR{continue};guard count>0 else{throw failure};offset+=count
                }
            }
            guard fsync(fd)==0 else{throw failure}
            if fcntl(fd,F_FULLFSYNC) != 0,errno != EINVAL,errno != ENOTSUP{throw failure}
            try check();guard renameat(dirFD,temporary,dirFD,name)==0,fsync(dirFD)==0 else{throw failure};try check()
        }
        func removeActive()throws {try check();if unlinkat(dirFD,"active.json",0) != 0,errno != ENOENT{throw failure};guard fsync(dirFD)==0 else{throw failure}}
    }
    private func central(_ id:String)throws->CodexMigrationJournalRecord? {
        guard let row=try store.migrationRows(id:id).first else{return nil}
        let record=try JSONDecoder().decode(CodexMigrationJournalRecord.self,from:row.data);try record.validate()
        guard record.id==row.id,record.revision==row.revision,record.terminal==row.terminal else{throw Self.failure};return record
    }
    private func acquire(_ id:String,_ refs:[CodexMigrationJournalRecord.Home],create:Bool)throws->[HomeHandle] {
        if let handles=leases[id]{guard handles.map(\.ref).sorted(by:{$0.path<$1.path})==refs else{throw Self.failure};return handles}
        var handles:[HomeHandle]=[]
        // File IDs keep the ordering identical even for case-insensitive aliases.
        for ref in refs.sorted(by:{$0.identity<$1.identity}) {
            let handle=try HomeHandle(ref,create:create,lock:true)
            if let active=try handle.read("active.json"){guard active.id==id else{throw Self.failure}}
            handles.append(handle)
        }
        leases[id]=handles;return handles
    }
    func create(id value:String,homes:[String],payload:Data)throws->CodexMigrationJournalRecord {
        let id=try Self.id(value);guard try central(id)==nil,payload.count<=8*1024*1024 else{throw Self.failure}
        let refs=try homes.map(Self.home).sorted(by:{$0.path<$1.path})
        guard refs.count==2,Set(refs.map(\.identity)).count==2 else{throw Self.failure}
        let handles=try acquire(id,refs,create:true)
        do{for h in handles{guard try h.read(id+".json")==nil,try h.read("active.json")==nil else{throw Self.failure}}}
        catch{leases.removeValue(forKey:id);throw error}
        let record=try CodexMigrationJournalRecord(id:id,revision:1,homes:refs,payload:payload,previousDigest:nil,terminal:false)
        do{try persist(record,expectedRevision:0,handles:handles);return record}
        catch{
            // A failed read is not proof that the central write was absent.
            do{if try central(id)==nil{leases.removeValue(forKey:id)}}catch{}
            throw error
        }
    }
    private func persist(_ record:CodexMigrationJournalRecord,expectedRevision:Int,handles:[HomeHandle])throws {
        try record.validate()
        let row=AuditStore.MigrationRow(id:record.id,revision:record.revision,terminal:record.terminal,data:try CodexMigrationJournalRecord.serialized(record))
        if let ownership=record.ownership {
            let updates=try ownership.map {change in
                let owner=try CodexMigrationOwner.after(change,record)
                let previous=try change.previous.map {value in AuditStore.MigrationOwnerRow(id:value.threadID,revision:value.revision,data:try CodexMigrationJournalRecord.serialized(value))}
                return AuditStore.MigrationOwnerUpdate(previous:previous,next:.init(id:owner.threadID,revision:owner.revision,data:try CodexMigrationJournalRecord.serialized(owner)))
            }
            try store.saveMigrationCompletion(row,expectedRevision:expectedRevision,ownership:updates)
        }else{try store.saveMigrationRow(row,expectedRevision:expectedRevision)}
        try mirror(record,handles)
    }
    private func mirror(_ record:CodexMigrationJournalRecord,_ handles:[HomeHandle])throws {
        for h in handles {
            try h.write(record,to:record.id+".json")
            if record.terminal{try h.removeActive()}else{try h.write(record,to:"active.json")}
        }
    }
    private func acceptable(_ copy:CodexMigrationJournalRecord?,for record:CodexMigrationJournalRecord,missing:Bool)throws->Bool {
        guard let copy else{guard missing else{throw Self.failure};return false}
        guard copy.id==record.id,copy.homes==record.homes else{throw Self.failure}
        if copy==record{return true}
        guard !copy.terminal,copy.revision==record.revision-1,copy.digest==record.previousDigest else{throw Self.failure};return false
    }
    func load(id value:String)throws->Loaded? {
        let id=try Self.id(value);guard let record=try central(id) else{return nil}
        var consistent=true
        for ref in record.homes {
            let handle=try HomeHandle(ref,create:false,lock:false)
            let history=try handle.read(id+".json"),active=try handle.read("active.json")
            let historyOK=try acceptable(history,for:record,missing:record.revision==1)
            if record.terminal {
                if let active {
                    if active.id==record.id{_=try acceptable(active,for:record,missing:false);consistent=false}
                    else{guard !active.terminal,active.homes.contains(ref) else{throw Self.failure}}
                }
            }else{
                if try !acceptable(active,for:record,missing:record.revision==1){consistent=false}
            }
            if !historyOK{consistent=false}
        }
        guard try central(id)==record else{throw Self.failure};return .init(record:record,consistent:consistent)
    }
    func save(id value:String,payload:Data,expectedRevision:Int,terminal:Bool=false)throws->CodexMigrationJournalRecord {
        let id=try Self.id(value)
        guard payload.count<=8*1024*1024,let loaded=try load(id:id),loaded.consistent,!loaded.record.terminal,
              loaded.record.revision==expectedRevision,let handles=leases[id] else{throw Self.failure}
        for h in handles{try h.check()}
        let record=try CodexMigrationJournalRecord(id:id,revision:expectedRevision+1,homes:loaded.record.homes,payload:payload,previousDigest:loaded.record.digest,terminal:terminal)
        try persist(record,expectedRevision:expectedRevision,handles:handles);return record
    }
    func owner(threadID:String)throws->CodexMigrationOwner? {
        let threadID=try Self.id(threadID)
        guard let row=try store.migrationOwner(threadID:threadID) else{
            guard try !store.migrationOwnershipExists(threadID:threadID) else{throw Self.failure}
            return nil
        }
        let owner=try JSONDecoder().decode(CodexMigrationOwner.self,from:row.data);try owner.validate()
        guard owner.threadID==threadID,row.id==threadID,row.revision==owner.revision,
              let loaded=try load(id:owner.journalID),loaded.consistent,loaded.record.terminal,
              loaded.record.digest==owner.journalDigest,
              let change=loaded.record.ownership?.first(where:{$0.threadID==threadID}),
              try CodexMigrationOwner.after(change,loaded.record)==owner else{throw Self.failure}
        return owner
    }
    func complete(id value:String,payload:Data,expectedRevision:Int,ownership:[CodexMigrationOwnerChange])throws->CodexMigrationJournalRecord {
        let id=try Self.id(value)
        guard payload.count<=8*1024*1024,let loaded=try load(id:id),loaded.consistent,!loaded.record.terminal,
              loaded.record.revision==expectedRevision,let handles=leases[id] else{throw Self.failure}
        let record=try CodexMigrationJournalRecord(id:id,revision:expectedRevision+1,homes:loaded.record.homes,payload:payload,previousDigest:loaded.record.digest,terminal:true,ownership:ownership)
        try record.validate()
        for change in ownership {
            guard try owner(threadID:change.threadID)==change.previous else{throw Self.failure}
            try change.retirement?.verifyCurrent()
        }
        for h in handles{try h.check()}
        try persist(record,expectedRevision:expectedRevision,handles:handles)
        return record
    }
    func retired(threadID:String,toHome:String,expectedOwner:CodexMigrationOwner)throws->CodexMigrationRetirement {
        guard try owner(threadID:threadID)==expectedOwner else{throw Self.failure}
        let destination=try Self.home(toHome)
        guard destination != expectedOwner.home else{throw Self.failure}
        var cursor:CodexMigrationOwner?=expectedOwner,seen=Set<String>()
        while let current=cursor {
            try current.validate()
            guard seen.count<512,seen.insert(current.journalID).inserted,
                  let loaded=try load(id:current.journalID),loaded.consistent,loaded.record.terminal,
                  loaded.record.digest==current.journalDigest,
                  let change=loaded.record.ownership?.first(where:{$0.threadID==threadID}),
                  try CodexMigrationOwner.after(change,loaded.record)==current else{throw Self.failure}
            if let retired=change.retirement,retired.goal.sourceHome==destination.path {
                guard retired.goal.homeIdentity==destination.identity else{throw Self.failure}
                try retired.verifyCurrent()
                guard try owner(threadID:threadID)==expectedOwner else{throw Self.failure}
                return retired
            }
            // Missing native retirement evidence is a gap, not permission to
            // adopt an even older retired copy after a later untracked reuse.
            guard change.retirement != nil else{throw Self.failure}
            cursor=change.previous
        }
        throw Self.failure
    }
    func backupRetired(_ retirement:CodexMigrationRetirement,expectedOwner:CodexMigrationOwner,requestID:String,expectedRevision:Int)throws->CodexMigrationRetiredBackup {
        let id=try Self.id(requestID)
        guard let loaded=try load(id:id),loaded.consistent,!loaded.record.terminal,loaded.record.revision==expectedRevision,
              let handles=leases[id],loaded.record.homes.contains(expectedOwner.home),
              let destination=loaded.record.homes.first(where:{$0.path==retirement.goal.sourceHome}),
              destination.identity==retirement.goal.homeIdentity,
              try retired(threadID:retirement.goal.threadID,toHome:retirement.goal.sourceHome,expectedOwner:expectedOwner)==retirement,
              let handle=handles.first(where:{$0.ref==destination}) else{throw Self.failure}
        for h in handles{try h.check()}
        let backup=try CodexMigrationRetiredBackup.create(retirement,owner:expectedOwner,request:loaded.record,directoryFD:handle.dirFD)
        try verifyBackup(backup,expectedRevision:expectedRevision)
        for h in handles{try h.check()}
        return backup
    }
    func verifyBackup(_ backup:CodexMigrationRetiredBackup,expectedRevision:Int)throws {
        let id=try Self.id(backup.requestID)
        guard let loaded=try load(id:id),loaded.consistent,!loaded.record.terminal,loaded.record.revision==expectedRevision,
              loaded.record.digest==backup.requestDigest,let handles=leases[id],
              loaded.record.homes.contains(backup.currentOwner.home),
              loaded.record.homes.contains(.init(path:backup.retirement.goal.sourceHome,identity:backup.retirement.goal.homeIdentity)),
              try retired(threadID:backup.retirement.goal.threadID,toHome:backup.retirement.goal.sourceHome,expectedOwner:backup.currentOwner)==backup.retirement else{throw Self.failure}
        for h in handles{try h.check()}
        try backup.verify()
        guard let fresh=try load(id:id),fresh.consistent,fresh.record==loaded.record,
              try owner(threadID:backup.retirement.goal.threadID)==backup.currentOwner else{throw Self.failure}
    }
    func validateReservation(_ expected:CodexMigrationJournalRecord)throws {
        guard let loaded=try load(id:expected.id),loaded.consistent,loaded.record==expected,!expected.terminal,
              let handles=leases[expected.id] else{throw Self.failure}
        for handle in handles{try handle.check()}
    }
    func duplicateLockDescriptor(id:String,home:String,expectedRevision:Int)throws->CodexMigrationLockDescriptor {
        guard let loaded=try load(id:id),loaded.consistent,loaded.record.revision==expectedRevision else{throw Self.failure}
        try validateReservation(loaded.record)
        let ref=try Self.home(home)
        guard let handle=leases[loaded.record.id]?.first(where:{$0.ref==ref}),handle.lockFD>=0 else{throw Self.failure}
        try handle.check()
        let fd=fcntl(handle.lockFD,F_DUPFD_CLOEXEC,0)
        guard fd>=0 else{throw Self.failure}
        do {
            var info=stat()
            guard fstat(fd,&info)==0,info.st_mode&S_IFMT==S_IFREG,info.st_uid==getuid(),
                  info.st_mode&0o077==0,info.st_nlink==1 else{throw Self.failure}
            try handle.check()
            return .init(fd:fd,home:ref,record:loaded.record)
        } catch {Darwin.close(fd);throw error}
    }
    func repair(id value:String)throws->CodexMigrationJournalRecord {
        let id=try Self.id(value);guard let initial=try load(id:id) else{throw Self.failure}
        if initial.record.terminal,initial.consistent{return initial.record}
        let record=initial.record
        let handles=try acquire(id,record.homes,create:false)
        guard let loaded=try load(id:id),loaded.record==record else{throw Self.failure}
        if !loaded.consistent{try mirror(record,handles)}
        guard try load(id:id)?.consistent==true else{throw Self.failure};return record
    }
    func release(id value:String)throws {
        let id=try Self.id(value);guard let loaded=try load(id:id),loaded.consistent,loaded.record.terminal else{throw Self.failure}
        leases.removeValue(forKey:id)
    }
    func activeRecords()throws->[CodexMigrationJournalRecord] {
        try store.migrationRows(activeOnly:true).map {row in
            let value=try JSONDecoder().decode(CodexMigrationJournalRecord.self,from:row.data);try value.validate()
            guard value.id==row.id,value.revision==row.revision,!value.terminal else{throw Self.failure};return value
        }
    }
}
