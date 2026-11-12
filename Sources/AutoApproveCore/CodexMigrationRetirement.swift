import Foundation
import CryptoKit
import Darwin

// Storage evidence only. The native producer still must prove the writer has
// closed and flushed; an archived path or a stable hash alone cannot prove it.
struct CodexMigrationRetirement:Codable,Equatable {
    let formatVersion:Int
    let goal:CodexGoalTransferSlot
    let rollout:CodexMigrationRolloutWitness
    static func capture(home:String,threadID:String,rolloutPath:String)throws->Self {
        let goal=try CodexGoalTransferStore.captureSlot(home:home,threadID:threadID)
        // Canonicalize the selected home once, while still rejecting links in
        // every rollout component. macOS's /var home alias is not a file link.
        let selected=try CodexAccountTransitionTarget.canonicalHome(home)
        let selectedPrefix=selected+"/"
        let physicalPrefix=goal.sourceHome+"/"
        let relative:String
        if rolloutPath.hasPrefix(physicalPrefix){relative=String(rolloutPath.dropFirst(physicalPrefix.count))}
        else if rolloutPath.hasPrefix(selectedPrefix){relative=String(rolloutPath.dropFirst(selectedPrefix.count))}
        else{throw retirementFailure}
        let prefix="archived_sessions/"
        guard relative.hasPrefix(prefix),relative.hasSuffix(".jsonl"),
              URL(fileURLWithPath:rolloutPath).lastPathComponent.contains(goal.threadID) else{throw retirementFailure}
        let witness=try CodexMigrationRolloutWitness.capture(home:goal.sourceHome,homeIdentity:goal.homeIdentity,relative:relative)
        try CodexGoalTransferStore.verifyCurrent(goal)
        return .init(formatVersion:1,goal:goal,rollout:witness)
    }
    func validate()throws {
        guard formatVersion==1,rollout.relativePath.hasPrefix("archived_sessions/"),
              rollout.relativePath.hasSuffix(".jsonl"),
              URL(fileURLWithPath:rollout.relativePath).lastPathComponent.contains(goal.threadID) else{throw retirementFailure}
        try rollout.validate()
    }
    func verifyCurrent()throws {
        try validate();try CodexGoalTransferStore.verifyCurrent(goal)
        guard try CodexMigrationRolloutWitness.capture(home:goal.sourceHome,homeIdentity:goal.homeIdentity,relative:rollout.relativePath)==rollout else{throw retirementFailure}
        try CodexGoalTransferStore.verifyCurrent(goal)
    }
}
private var retirementFailure:AppError {.message("보관한 원본의 Goal·이력·백업 신원을 확인하지 못했습니다. 기존 기록을 유지했습니다.")}

struct CodexMigrationRolloutWitness:Codable,Equatable {
    let relativePath:String,fileIdentity:String,size:Int64,modifiedSeconds:Int64,modifiedNanoseconds:Int64,sha256:String
    func validate()throws {
        guard size>0,size<=256*1024*1024,sha256.count==64,sha256.allSatisfy({$0.isHexDigit}),
              !fileIdentity.isEmpty,fileIdentity.count<=128 else{throw retirementFailure}
        _=try RetirementFiles.components(relativePath)
    }
    static func capture(home:String,homeIdentity:String,relative:String)throws->Self {
        let root=try RetirementFiles.home(home,identity:homeIdentity);defer{close(root)}
        let fd=try RetirementFiles.file(root,relative);defer{close(fd)}
        return try read(fd,relative:relative)
    }
    static func read(_ fd:Int32,relative:String,copyTo:Int32?=nil)throws->Self {
        var before=stat()
        guard fstat(fd,&before)==0,before.st_mode&S_IFMT==S_IFREG,before.st_uid==getuid(),before.st_mode&0o022==0,
              before.st_nlink==1,before.st_size>0,before.st_size<=256*1024*1024 else{throw retirementFailure}
        var hash=SHA256(),total:Int64=0,buffer=[UInt8](repeating:0,count:65536)
        while true {
            try Task.checkCancellation()
            let count=Darwin.read(fd,&buffer,buffer.count)
            if count<0,errno==EINTR{continue};guard count>=0 else{throw retirementFailure};if count==0{break}
            total+=Int64(count);guard total<=before.st_size else{throw retirementFailure}
            let data=Data(buffer.prefix(count));hash.update(data:data)
            if let target=copyTo{try RetirementFiles.write(target,data)}
        }
        var after=stat()
        guard total==before.st_size,fstat(fd,&after)==0,before.st_dev==after.st_dev,before.st_ino==after.st_ino,
              before.st_size==after.st_size,before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec==after.st_ctimespec.tv_sec,before.st_ctimespec.tv_nsec==after.st_ctimespec.tv_nsec else{throw retirementFailure}
        return .init(relativePath:relative,fileIdentity:"\(before.st_dev):\(before.st_ino)",size:total,
            modifiedSeconds:Int64(before.st_mtimespec.tv_sec),modifiedNanoseconds:Int64(before.st_mtimespec.tv_nsec),
            sha256:hash.finalize().map{String(format:"%02x",$0)}.joined())
    }
}

struct CodexMigrationRetiredBackup:Codable,Equatable {
    struct Manifest:Codable,Equatable {
        let retirement:CodexMigrationRetirement
        let requestID:String,requestDigest:String,currentOwner:CodexMigrationOwner
    }
    let retirement:CodexMigrationRetirement
    let requestID:String,requestDigest:String,currentOwner:CodexMigrationOwner
    let relativeDirectory:String,rolloutIdentity:String,recordDigest:String
    var rolloutPath:String {retirement.goal.sourceHome+"/"+relativeDirectory+"/rollout.jsonl"}
    var recordPath:String {retirement.goal.sourceHome+"/"+relativeDirectory+"/retired.json"}
    func verify()throws {
        guard UUID(uuidString:requestID)?.uuidString.lowercased()==requestID,requestDigest.count==64,
              currentOwner.threadID==retirement.goal.threadID,
              relativeDirectory==".autoapprove-migrations/backups/"+requestID+"-"+retirement.goal.threadID else{throw retirementFailure}
        let home=retirement.goal.sourceHome,identity=retirement.goal.homeIdentity
        let root=try RetirementFiles.home(home,identity:identity);defer{close(root)}
        let fd=try RetirementFiles.file(root,relativeDirectory+"/retired.json");defer{close(fd)}
        var info=stat();guard fstat(fd,&info)==0,info.st_size>0,info.st_size<=512*1024,info.st_mode&0o077==0 else{throw retirementFailure}
        let data=try RetirementFiles.small(fd,Int(info.st_size))
        let manifest=Manifest(retirement:retirement,requestID:requestID,requestDigest:requestDigest,currentOwner:currentOwner)
        guard try JSONDecoder().decode(Manifest.self,from:data)==manifest,
              RetirementFiles.digest(data)==recordDigest else{throw retirementFailure}
        let copy=try CodexMigrationRolloutWitness.capture(home:home,homeIdentity:identity,relative:relativeDirectory+"/rollout.jsonl")
        guard copy.fileIdentity==rolloutIdentity,copy.sha256==retirement.rollout.sha256,copy.size==retirement.rollout.size else{throw retirementFailure}
    }
    static func create(_ retirement:CodexMigrationRetirement,owner:CodexMigrationOwner,request:CodexMigrationJournalRecord,directoryFD:Int32)throws->Self {
        try retirement.verifyCurrent()
        if mkdirat(directoryFD,"backups",0o700) != 0,errno != EEXIST{throw retirementFailure}
        let backups=openat(directoryFD,"backups",O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW)
        guard backups>=0 else{throw retirementFailure};defer{close(backups)}
        var info=stat();guard fstat(backups,&info)==0,info.st_uid==getuid(),info.st_mode&0o077==0 else{throw retirementFailure}
        let name=request.id+"-"+retirement.goal.threadID
        // Never adopt or overwrite an incomplete or previously delivered backup.
        guard mkdirat(backups,name,0o700)==0 else{throw retirementFailure}
        let folder=openat(backups,name,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW)
        guard folder>=0 else{throw retirementFailure};defer{close(folder)}
        let copy=openat(folder,"rollout.jsonl",O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,0o600)
        guard copy>=0 else{throw retirementFailure};defer{close(copy)}
        let root=try RetirementFiles.home(retirement.goal.sourceHome,identity:retirement.goal.homeIdentity);defer{close(root)}
        let original=try RetirementFiles.file(root,retirement.rollout.relativePath);defer{close(original)}
        guard try CodexMigrationRolloutWitness.read(original,relative:retirement.rollout.relativePath,copyTo:copy)==retirement.rollout else{throw retirementFailure}
        try RetirementFiles.sync(copy)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        let data=try encoder.encode(Manifest(retirement:retirement,requestID:request.id,requestDigest:request.digest,currentOwner:owner))
        let record=openat(folder,"retired.json",O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,0o600)
        guard record>=0 else{throw retirementFailure};defer{close(record)}
        try RetirementFiles.write(record,data);try RetirementFiles.sync(record)
        guard fsync(folder)==0,fsync(backups)==0,fsync(directoryFD)==0 else{throw retirementFailure}
        try retirement.verifyCurrent()
        let relative=".autoapprove-migrations/backups/"+name
        let witness=try CodexMigrationRolloutWitness.capture(home:retirement.goal.sourceHome,homeIdentity:retirement.goal.homeIdentity,relative:relative+"/rollout.jsonl")
        let result=Self(retirement:retirement,requestID:request.id,requestDigest:request.digest,currentOwner:owner,relativeDirectory:relative,rolloutIdentity:witness.fileIdentity,recordDigest:RetirementFiles.digest(data))
        try result.verify();return result
    }
}

enum CodexMigrationRolloutStaging {
    static func relative(_ backup:CodexMigrationRetiredBackup)->String {backup.relativeDirectory+"/replacement.jsonl"}
    static func inspect(backup:CodexMigrationRetiredBackup)throws->CodexMigrationRolloutWitness {
        try backup.verify()
        return try .capture(home:backup.retirement.goal.sourceHome,homeIdentity:backup.retirement.goal.homeIdentity,relative:relative(backup))
    }
    static func create(source:CodexMigrationRetirement,backup:CodexMigrationRetiredBackup)throws->CodexMigrationRolloutWitness {
        try backup.verify();try source.verifyCurrent()
        let old=backup.retirement.goal
        let root=try RetirementFiles.home(old.sourceHome,identity:old.homeIdentity);defer{close(root)}
        let folder=try RetirementFiles.directory(root,backup.relativeDirectory);defer{close(folder)}
        let output=openat(folder,"replacement.jsonl",O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,0o600)
        guard output>=0 else{throw retirementFailure};defer{close(output)}
        let sourceRoot=try RetirementFiles.home(source.goal.sourceHome,identity:source.goal.homeIdentity);defer{close(sourceRoot)}
        let input=try RetirementFiles.file(sourceRoot,source.rollout.relativePath);defer{close(input)}
        guard try CodexMigrationRolloutWitness.read(input,relative:source.rollout.relativePath,copyTo:output)==source.rollout else{throw retirementFailure}
        try RetirementFiles.sync(output);guard fsync(folder)==0 else{throw retirementFailure}
        try source.verifyCurrent();try backup.verify()
        let staged=try inspect(backup:backup)
        guard staged.sha256==source.rollout.sha256,staged.size==source.rollout.size else{throw retirementFailure}
        return staged
    }
    static func install(source:CodexMigrationRetirement,backup:CodexMigrationRetiredBackup,staged:CodexMigrationRolloutWitness,verifyAuthority:()throws->Void)throws {
        try Task.checkCancellation();try source.verifyCurrent();try backup.verify()
        guard staged.relativePath==relative(backup),try inspect(backup:backup)==staged,
              staged.sha256==source.rollout.sha256,staged.size==source.rollout.size else{throw retirementFailure}
        let retired=backup.retirement,old=retired.rollout
        guard try CodexMigrationRolloutWitness.capture(home:retired.goal.sourceHome,homeIdentity:retired.goal.homeIdentity,relative:old.relativePath)==old else{throw retirementFailure}
        let root=try RetirementFiles.home(retired.goal.sourceHome,identity:retired.goal.homeIdentity);defer{close(root)}
        let parts=try RetirementFiles.components(old.relativePath),parent=parts.dropLast().joined(separator:"/"),name=parts.last!
        let destination=try RetirementFiles.directory(root,parent);defer{close(destination)}
        let staging=try RetirementFiles.directory(root,backup.relativeDirectory);defer{close(staging)}
        try verifyAuthority();try source.verifyCurrent();try backup.verify()
        guard try inspect(backup:backup)==staged,
              try CodexMigrationRolloutWitness.capture(home:retired.goal.sourceHome,homeIdentity:retired.goal.homeIdentity,relative:old.relativePath)==old else{throw retirementFailure}
        // Reopen both directory paths and compare descriptors so a moved parent
        // cannot redirect the final rename away from the verified slot.
        let currentRoot=try RetirementFiles.home(retired.goal.sourceHome,identity:retired.goal.homeIdentity);defer{close(currentRoot)}
        let currentDestination=try RetirementFiles.directory(currentRoot,parent);defer{close(currentDestination)}
        let currentStaging=try RetirementFiles.directory(currentRoot,backup.relativeDirectory);defer{close(currentStaging)}
        var a=stat(),b=stat()
        for (first,second) in [(destination,currentDestination),(staging,currentStaging)] {
            guard fstat(first,&a)==0,fstat(second,&b)==0,a.st_dev==b.st_dev,a.st_ino==b.st_ino else{throw retirementFailure}
        }
        try Task.checkCancellation()
        // Native writer quiescence is required by the caller. This is an atomic
        // same-filesystem rename after exact identity/content checks, not an OS
        // compare-and-swap against an adversarial concurrent writer.
        guard renameat(staging,"replacement.jsonl",destination,name)==0 else{throw retirementFailure}
        guard fsync(destination)==0,fsync(staging)==0 else{throw retirementFailure}
        let after=try CodexMigrationRolloutWitness.capture(home:retired.goal.sourceHome,homeIdentity:retired.goal.homeIdentity,relative:old.relativePath)
        guard after.fileIdentity==staged.fileIdentity,after.sha256==staged.sha256,after.size==staged.size else{throw retirementFailure}
    }
}

enum RetirementFiles {
    static func components(_ value:String)throws->[String] {
        let parts=value.split(separator:"/",omittingEmptySubsequences:false).map(String.init)
        guard value.utf8.count<=4096,!value.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains),
              !parts.isEmpty,parts.count<=64,parts.allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".."}) else{throw retirementFailure}
        return parts
    }
    static func home(_ path:String,identity:String)throws->Int32 {
        guard let physical=realpath(path,nil) else{throw retirementFailure};defer{free(physical)}
        guard String(cString:physical)==path else{throw retirementFailure}
        let fd=open(path,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW)
        var info=stat()
        guard fd>=0 else{throw retirementFailure}
        guard fstat(fd,&info)==0,info.st_uid==getuid(),"\(info.st_dev):\(info.st_ino)"==identity else{close(fd);throw retirementFailure}
        return fd
    }
    static func file(_ root:Int32,_ relative:String)throws->Int32 {
        let parts=try components(relative)
        var directory=dup(root);guard directory>=0 else{throw retirementFailure};defer{close(directory)}
        for part in parts.dropLast() {
            let next=openat(directory,part,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW)
            guard next>=0 else{throw retirementFailure}
            var info=stat()
            guard fstat(next,&info)==0,info.st_uid==getuid(),info.st_mode&0o022==0 else{close(next);throw retirementFailure}
            close(directory);directory=next
        }
        let fd=openat(directory,parts.last!,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK)
        guard fd>=0 else{throw retirementFailure}
        var info=stat()
        guard fstat(fd,&info)==0,info.st_mode&S_IFMT==S_IFREG,info.st_uid==getuid(),info.st_mode&0o022==0,info.st_nlink==1 else{close(fd);throw retirementFailure}
        return fd
    }
    static func directory(_ root:Int32,_ relative:String)throws->Int32 {
        var fd=dup(root);guard fd>=0 else{throw retirementFailure}
        do {
            for part in try components(relative) {
                let next=openat(fd,part,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW)
                guard next>=0 else{throw retirementFailure}
                var info=stat()
                guard fstat(next,&info)==0,info.st_uid==getuid(),info.st_mode&0o022==0 else{close(next);throw retirementFailure}
                close(fd);fd=next
            }
            return fd
        }catch{close(fd);throw error}
    }
    static func small(_ fd:Int32,_ size:Int)throws->Data {
        var data=Data(count:size),offset=0
        try data.withUnsafeMutableBytes{buffer in while offset<size {
            let count=Darwin.read(fd,buffer.baseAddress!.advanced(by:offset),size-offset)
            if count<0,errno==EINTR{continue};guard count>0 else{throw retirementFailure};offset+=count
        }}
        return data
    }
    static func write(_ fd:Int32,_ data:Data)throws {
        try data.withUnsafeBytes{buffer in var offset=0;while offset<buffer.count {
            let count=Darwin.write(fd,buffer.baseAddress!.advanced(by:offset),buffer.count-offset)
            if count<0,errno==EINTR{continue};guard count>0 else{throw retirementFailure};offset+=count
        }}
    }
    static func sync(_ fd:Int32)throws {
        guard fsync(fd)==0 else{throw retirementFailure}
        if fcntl(fd,F_FULLFSYNC) != 0,errno != EINVAL,errno != ENOTSUP{throw retirementFailure}
    }
    static func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
}
