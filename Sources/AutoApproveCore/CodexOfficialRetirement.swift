import Foundation
import Darwin

/// A storage operation inside an existing migration reservation. Neither this
/// intent nor a writer lock grants complete TUI ownership or input admission.
struct CodexOfficialRetirementIntent:Codable,Equatable {
    let formatVersion:Int,requestID:String,requestDigest:String
    let source:CodexMigrationRetirement
    var relativeDirectory:String {".autoapprove-migrations/official-retired/"+requestID+"-"+source.goal.threadID}
    var savedRelativePath:String {relativeDirectory+"/rollout.jsonl"}
}

/// Native archive removal is durable even when our process and its locks exit.
/// The original inode is retained privately, never deleted or overwritten.
/// This primitive is not yet bound to the complete selected-client coordinator.
final class CodexOfficialRetirement {
    enum Observation:String,Codable {case reserved,withheld,returned,review}
    private let journal:CodexMigrationJournal
    init(journal:CodexMigrationJournal){self.journal=journal}
    private static var failure:AppError {.message("공식 Codex 원본 보관 기록·이력·Goal을 확인하지 못했습니다. 파일 이동을 반복하지 않았습니다.")}
    private static let marker=Data("1\n".utf8)

    private static func validate(_ intent:CodexOfficialRetirementIntent)throws {
        guard intent.formatVersion==1,UUID(uuidString:intent.requestID)?.uuidString.lowercased()==intent.requestID,
              intent.requestDigest.count==64,intent.requestDigest.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) else{throw failure}
        try intent.source.validate()
        guard intent.source.formatVersion==1,intent.source.goal.row?.status != "active" else{throw failure}
    }
    private func authorize(_ intent:CodexOfficialRetirementIntent,record:CodexMigrationJournalRecord,
                           lease:CodexOfficialWriterLease,checkpoint:()throws->Void)throws {
        try Self.validate(intent)
        guard record.id==intent.requestID,record.digest==intent.requestDigest,
              record.homes.contains(.init(path:intent.source.goal.sourceHome,identity:intent.source.goal.homeIdentity)) else{throw Self.failure}
        try journal.validateReservation(record)
        try lease.verifyScope(home:intent.source.goal.sourceHome,threadIDs:[intent.source.goal.threadID])
        try Task.checkCancellation();try checkpoint()
        try journal.validateReservation(record)
        try lease.verifyScope(home:intent.source.goal.sourceHome,threadIDs:[intent.source.goal.threadID])
        try CodexGoalTransferStore.verifyCurrent(intent.source.goal)
    }
    func prepare(record:CodexMigrationJournalRecord,source:CodexMigrationRetirement,
                 lease:CodexOfficialWriterLease,checkpoint:()throws->Void)throws->CodexOfficialRetirementIntent {
        let intent=CodexOfficialRetirementIntent(formatVersion:1,requestID:record.id,requestDigest:record.digest,source:source)
        try authorize(intent,record:record,lease:lease,checkpoint:checkpoint);try source.verifyCurrent()
        let root=try RetirementFiles.home(source.goal.sourceHome,identity:source.goal.homeIdentity);defer{Darwin.close(root)}
        let migration=try RetirementFiles.directory(root,".autoapprove-migrations");defer{Darwin.close(migration)}
        try Self.privateDirectory(migration)
        if mkdirat(migration,"official-retired",0o700) != 0,errno != EEXIST{throw Self.failure}
        let parent=try RetirementFiles.directory(migration,"official-retired");defer{Darwin.close(parent)}
        try Self.privateDirectory(parent)
        let name=record.id+"-"+source.goal.threadID
        // An incomplete or previous intent is inspected, never adopted by prepare.
        guard mkdirat(parent,name,0o700)==0 else{throw Self.failure}
        let folder=try RetirementFiles.directory(parent,name);defer{Darwin.close(folder)}
        try Self.privateDirectory(folder)
        let data=try JSONEncoder().encode(intent)
        try Self.writeExclusive(folder,name:"intent.json",data:data)
        guard fsync(folder)==0,fsync(parent)==0,fsync(migration)==0 else{throw Self.failure}
        try authorize(intent,record:record,lease:lease,checkpoint:checkpoint)
        guard try observe(intent) == .reserved else{throw Self.failure}
        return intent
    }

    /// Recover the immutable intent even if the caller died before saving the
    /// return value of prepare. The journal and selected source identify its
    /// exact location; directory scans or a file's self-declared home do not.
    func load(record:CodexMigrationJournalRecord,sourceHome:String,threadID:String)throws->CodexOfficialRetirementIntent {
        try journal.validateReservation(record)
        guard UUID(uuidString:threadID)?.uuidString.lowercased()==threadID,
              let home=record.homes.first(where:{$0.path==sourceHome}) else{throw Self.failure}
        let root=try RetirementFiles.home(home.path,identity:home.identity);defer{Darwin.close(root)}
        let relative=".autoapprove-migrations/official-retired/"+record.id+"-"+threadID
        let folder=try RetirementFiles.directory(root,relative);defer{Darwin.close(folder)}
        try Self.privateDirectory(folder)
        let intent=try JSONDecoder().decode(CodexOfficialRetirementIntent.self,from:Self.readPrivate(folder,"intent.json",limit:1_048_576))
        try Self.validate(intent)
        guard intent.requestID==record.id,intent.requestDigest==record.digest,
              intent.source.goal.threadID==threadID,intent.source.goal.sourceHome==home.path,
              intent.source.goal.homeIdentity==home.identity,intent.relativeDirectory==relative else{throw Self.failure}
        _=try observe(intent);try journal.validateReservation(record)
        return intent
    }

    /// Once attempted, the same operation only observes. In particular, an
    /// attempt whose rename never happened is review, not permission to retry.
    func withdraw(_ intent:CodexOfficialRetirementIntent,record:CodexMigrationJournalRecord,
                  lease:CodexOfficialWriterLease,checkpoint:()throws->Void,
                  afterAttempt:()throws->Void={},afterRename:()throws->Void={})throws->Observation {
        try authorize(intent,record:record,lease:lease,checkpoint:checkpoint)
        let initial=try observe(intent)
        guard initial == .reserved else{return initial}
        let handles=try Handles(intent);defer{handles.close()}
        try handles.check()
        try Self.writeExclusive(handles.folder,name:"withdraw.attempted",data:Self.marker)
        try afterAttempt()
        try authorize(intent,record:record,lease:lease,checkpoint:checkpoint);try handles.check()
        try intent.source.verifyCurrent()
        guard !Self.exists(handles.folder,"rollout.jsonl") else{throw Self.failure}
        guard renameatx_np(handles.originalParent,handles.originalName,handles.folder,"rollout.jsonl",UInt32(RENAME_EXCL))==0 else{throw Self.failure}
        try handles.syncSaved("rollout.jsonl",directory:handles.folder)
        try handles.check();try Self.verifySaved(intent,handles)
        try CodexGoalTransferStore.verifyCurrent(intent.source.goal)
        try afterRename()
        try Self.writeExclusive(handles.folder,name:"withdraw.applied",data:Self.marker)
        return try observe(intent)
    }

    /// Abort compensation only. The coordinator must prove through checkpoint
    /// that no destination activation occurred. A later account move back must
    /// transfer its newer history instead of reopening this old snapshot.
    func returnOriginal(_ intent:CodexOfficialRetirementIntent,record:CodexMigrationJournalRecord,
                        lease:CodexOfficialWriterLease,checkpoint:()throws->Void,
                        afterAttempt:()throws->Void={},afterRename:()throws->Void={})throws->Observation {
        try authorize(intent,record:record,lease:lease,checkpoint:checkpoint)
        let initial=try observe(intent)
        guard initial == .withheld else{return initial}
        let handles=try Handles(intent);defer{handles.close()}
        try handles.check();try Self.verifySaved(intent,handles)
        try Self.writeExclusive(handles.folder,name:"return.attempted",data:Self.marker)
        try afterAttempt()
        try authorize(intent,record:record,lease:lease,checkpoint:checkpoint);try handles.check()
        try Self.verifySaved(intent,handles)
        guard !Self.exists(handles.originalParent,handles.originalName) else{throw Self.failure}
        guard renameatx_np(handles.folder,"rollout.jsonl",handles.originalParent,handles.originalName,UInt32(RENAME_EXCL))==0 else{throw Self.failure}
        try handles.syncSaved(handles.originalName,directory:handles.originalParent)
        try handles.check();try intent.source.verifyCurrent()
        try afterRename()
        try Self.writeExclusive(handles.folder,name:"return.applied",data:Self.marker)
        return try observe(intent)
    }

    /// No file creation, rename, retry or repair. The physical files and exact
    /// Goal snapshot must agree with the immutable intent, even after restart.
    func observe(_ intent:CodexOfficialRetirementIntent)throws->Observation {
        try Self.observation(intent)
    }
    private static func observation(_ intent:CodexOfficialRetirementIntent)throws->Observation {
        try Self.validate(intent)
        let handles=try Handles(intent);defer{handles.close()}
        try handles.check()
        let bytes=try Self.readPrivate(handles.folder,"intent.json",limit:1_048_576)
        guard try JSONDecoder().decode(CodexOfficialRetirementIntent.self,from:bytes)==intent else{throw Self.failure}
        try CodexGoalTransferStore.verifyCurrent(intent.source.goal)
        let attempted=try Self.hasMarker(handles.folder,"withdraw.attempted"),applied=try Self.hasMarker(handles.folder,"withdraw.applied")
        let returning=try Self.hasMarker(handles.folder,"return.attempted"),returned=try Self.hasMarker(handles.folder,"return.applied")
        guard !applied || attempted,!returning || attempted,!returned || returning else{throw Self.failure}
        let original=Self.exists(handles.originalParent,handles.originalName),saved=Self.exists(handles.folder,"rollout.jsonl")
        var result:Observation = .review
        if original && !saved {
            try intent.source.verifyCurrent()
            if returning{result = .returned}
            else if !attempted{result = .reserved}
        }else if !original && saved {
            try Self.verifySaved(intent,handles)
            if attempted && !returning{result = .withheld}
        }
        try handles.check();try CodexGoalTransferStore.verifyCurrent(intent.source.goal)
        return result
    }
    /// Journal-compatible storage evidence. It preserves the original native
    /// archive location separately from the retained inode's current location.
    func storageFact(_ intent:CodexOfficialRetirementIntent)throws->CodexMigrationRetirement {
        guard try observe(intent) == .withheld else{throw Self.failure}
        let handles=try Handles(intent);defer{handles.close()}
        let bytes=try Self.readPrivate(handles.folder,"intent.json",limit:1_048_576)
        let witness=try CodexMigrationRolloutWitness.capture(home:intent.source.goal.sourceHome,
            homeIdentity:intent.source.goal.homeIdentity,relative:intent.savedRelativePath)
        let fact=CodexMigrationRetirement(formatVersion:2,goal:intent.source.goal,rollout:witness,
            official:.init(requestID:intent.requestID,intentDigest:RetirementFiles.digest(bytes),originalArchivePath:intent.source.rollout.relativePath))
        try Self.verifyStorageFact(fact);return fact
    }
    static func verifyStorageFact(_ fact:CodexMigrationRetirement)throws {
        try fact.validate()
        guard let reference=fact.official else{throw failure}
        let root=try RetirementFiles.home(fact.goal.sourceHome,identity:fact.goal.homeIdentity);defer{Darwin.close(root)}
        let relative=".autoapprove-migrations/official-retired/"+reference.requestID+"-"+fact.goal.threadID
        let folder=try RetirementFiles.directory(root,relative);defer{Darwin.close(folder)}
        try privateDirectory(folder)
        let bytes=try readPrivate(folder,"intent.json",limit:1_048_576)
        guard RetirementFiles.digest(bytes)==reference.intentDigest else{throw failure}
        let intent=try JSONDecoder().decode(CodexOfficialRetirementIntent.self,from:bytes);try validate(intent)
        var expected=intent.source.rollout
        expected=CodexMigrationRolloutWitness(relativePath:intent.savedRelativePath,fileIdentity:expected.fileIdentity,size:expected.size,
            modifiedSeconds:expected.modifiedSeconds,modifiedNanoseconds:expected.modifiedNanoseconds,sha256:expected.sha256)
        guard intent.requestID==reference.requestID,intent.source.goal==fact.goal,
              reference.originalArchivePath==intent.source.rollout.relativePath,fact.rollout==expected,
              try observation(intent) == .withheld else{throw failure}
    }
    private static func exists(_ directory:Int32,_ name:String)->Bool {
        var info=stat()
        // An inaccessible or invalid entry is treated as present; callers then
        // refuse to rename over it or require a verified regular file.
        return fstatat(directory,name,&info,AT_SYMLINK_NOFOLLOW)==0 || errno != ENOENT
    }
    private static func privateDirectory(_ fd:Int32)throws {
        var info=stat()
        guard fstat(fd,&info)==0,info.st_mode&S_IFMT==S_IFDIR,info.st_uid==getuid(),info.st_mode&0o077==0 else{throw failure}
    }
    private static func readPrivate(_ directory:Int32,_ name:String,limit:Int)throws->Data {
        let fd=openat(directory,name,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK);guard fd>=0 else{throw failure};defer{Darwin.close(fd)}
        var before=stat(),after=stat()
        guard fstat(fd,&before)==0,before.st_mode&S_IFMT==S_IFREG,before.st_uid==getuid(),before.st_mode&0o077==0,
              before.st_nlink==1,before.st_size>0,before.st_size<=limit else{throw failure}
        let bytes=try RetirementFiles.small(fd,Int(before.st_size))
        guard fstat(fd,&after)==0,before.st_size==after.st_size,before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec else{throw failure}
        return bytes
    }
    private static func hasMarker(_ folder:Int32,_ name:String)throws->Bool {
        guard exists(folder,name) else{return false}
        guard try readPrivate(folder,name,limit:marker.count)==marker else{throw failure};return true
    }
    private static func writeExclusive(_ folder:Int32,name:String,data:Data)throws {
        let fd=openat(folder,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600);guard fd>=0 else{throw failure};defer{Darwin.close(fd)}
        try RetirementFiles.write(fd,data);try RetirementFiles.sync(fd)
        guard fsync(folder)==0 else{throw failure}
    }
    private static func verifySaved(_ intent:CodexOfficialRetirementIntent,_ handles:Handles)throws {
        let expected=intent.source.rollout
        let file=try RetirementFiles.file(handles.folder,"rollout.jsonl");defer{Darwin.close(file)}
        let actual=try CodexMigrationRolloutWitness.read(file,relative:expected.relativePath)
        guard actual==expected else{throw failure}
    }
    private final class Handles {
        let intent:CodexOfficialRetirementIntent
        var root:Int32 = -1,folder:Int32 = -1,originalParent:Int32 = -1
        let originalName:String,originalDirectory:String
        init(_ intent:CodexOfficialRetirementIntent)throws {
            self.intent=intent
            let parts=try RetirementFiles.components(intent.source.rollout.relativePath)
            originalName=parts.last!;originalDirectory=parts.dropLast().joined(separator:"/")
            do {
                root=try RetirementFiles.home(intent.source.goal.sourceHome,identity:intent.source.goal.homeIdentity)
                folder=try RetirementFiles.directory(root,intent.relativeDirectory);try CodexOfficialRetirement.privateDirectory(folder)
                originalParent=try RetirementFiles.directory(root,originalDirectory)
                try check()
            }catch{close();throw error}
        }
        func close(){for fd in [originalParent,folder,root] where fd>=0{Darwin.close(fd)};originalParent = -1;folder = -1;root = -1}
        func check()throws {
            let home=try RetirementFiles.home(intent.source.goal.sourceHome,identity:intent.source.goal.homeIdentity);defer{Darwin.close(home)}
            let current=try RetirementFiles.directory(home,intent.relativeDirectory);defer{Darwin.close(current)}
            let archive=try RetirementFiles.directory(home,originalDirectory);defer{Darwin.close(archive)}
            for (a,b) in [(root,home),(folder,current),(originalParent,archive)] {
                var first=stat(),second=stat()
                guard a>=0,fstat(a,&first)==0,fstat(b,&second)==0,first.st_dev==second.st_dev,first.st_ino==second.st_ino else{throw CodexOfficialRetirement.failure}
            }
            try CodexOfficialRetirement.privateDirectory(current)
        }
        func syncSaved(_ name:String,directory:Int32)throws {
            let file=try RetirementFiles.file(directory,name);defer{Darwin.close(file)}
            try RetirementFiles.sync(file)
            guard fsync(folder)==0,fsync(originalParent)==0 else{throw CodexOfficialRetirement.failure}
        }
    }
}
