import Foundation
import CryptoKit
import Darwin

/// Copies the source server's exact archived rollout files into a destination
/// that already has a durable Incoming reservation. The marker makes an
/// interrupted copy resumable, while path and file identity checks prevent an
/// existing destination slot from being silently replaced or adopted.
struct CodexNativeSelectedArchiveImport:Codable,Equatable,Sendable {
    struct Marker:Codable,Equatable {
        let formatVersion:Int,requestID:String,sourceHomeIdentity:String,destinationHomeIdentity:String
        let files:[CodexNativeArchivedFile]
        let goalSlots:[CodexGoalTransferSlotReference]
    }
    let marker:Marker
    let importedFiles:[CodexNativeArchivedFile]

    private static var failure:AppError {.message("Codex 대화 이력 파일을 안전하게 가져오지 못했습니다. 가져오기 예약과 원본 데이터를 유지했습니다.")}
    private static func components(_ path:String,staging:Bool=false)throws->[String] {
        let parts=path.split(separator:"/",omittingEmptySubsequences:false).map(String.init)
        guard path.utf8.count<=4096,!path.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains),
              parts.count>=2,parts.count<=64,parts.allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".."}),
              parts[0]==(staging ? "files":"archived_sessions") else{throw failure}
        return parts
    }
    private static func identity(_ home:String)throws->String {
        _=try CodexAccountTransitionTarget.canonicalHome(home)
        guard let ptr=realpath(home,nil) else{throw failure};defer{free(ptr)}
        var info=stat();guard String(cString:ptr)==home,lstat(home,&info)==0,info.st_mode&S_IFMT==S_IFDIR,
            info.st_uid==getuid() else{throw failure}
        return "\(info.st_dev):\(info.st_ino)"
    }
    private static func openDirectory(_ parent:Int32,_ name:String,create:Bool)throws->Int32 {
        var created=false
        if create {
            if mkdirat(parent,name,0o700)==0 {created=true}
            else if errno != EEXIST {throw failure}
        }
        if created && fsync(parent) != 0 {throw failure}
        let fd=openat(parent,name,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW)
        guard fd>=0 else{throw failure}
        var info=stat()
        guard fstat(fd,&info)==0,info.st_uid==getuid(),info.st_mode&S_IFMT==S_IFDIR,info.st_mode&0o022==0 else{close(fd);throw failure}
        if created && fsync(fd) != 0 {close(fd);throw failure}
        return fd
    }
    private static func openPrivateDirectory(_ parent:Int32,_ name:String,create:Bool)throws->Int32 {
        let fd=try openDirectory(parent,name,create:create);var info=stat()
        guard fstat(fd,&info)==0,info.st_mode&0o077==0 else{close(fd);throw failure}
        return fd
    }
    private static func openParent(_ root:Int32,_ path:String,create:Bool,staging:Bool=false)throws->(Int32,String) {
        let parts=try components(path,staging:staging);var fd=dup(root);guard fd>=0 else{throw failure}
        do {
            for name in parts.dropLast() {
                let next=try openDirectory(fd,name,create:create);close(fd);fd=next
            }
            return(fd,parts.last!)
        }catch{close(fd);throw error}
    }
    private static func exists(_ parent:Int32,_ name:String)throws->Bool {
        let fd=openat(parent,name,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK)
        if fd>=0 {close(fd);return true}
        if errno==ENOENT {return false}
        throw failure
    }
    private static func pathAbsent(_ root:Int32,_ path:String)throws->Bool {
        let parts=try components(path);var directory=dup(root);guard directory>=0 else{throw failure}
        defer{close(directory)}
        for name in parts.dropLast() {
            let next=openat(directory,name,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW)
            if next<0 {if errno==ENOENT{return true};throw failure}
            close(directory);directory=next
        }
        let fd=openat(directory,parts.last!,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK)
        if fd>=0 {close(fd);return false}
        if errno==ENOENT{return true}
        throw failure
    }
    private static func readMarker(_ directory:Int32)throws->Marker? {
        let fd=openat(directory,"manifest.json",O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK)
        if fd<0 {if errno==ENOENT{return nil};throw failure};defer{close(fd)}
        var info=stat();guard fstat(fd,&info)==0,info.st_mode&S_IFMT==S_IFREG,info.st_uid==getuid(),
              info.st_mode&0o077==0,info.st_nlink==1,info.st_size>0,info.st_size<=768*1024 else{throw failure}
        var data=Data(count:Int(info.st_size));let length=data.count;var offset=0
        while offset<length {
            let count=data.withUnsafeMutableBytes{buffer in Darwin.read(fd,buffer.baseAddress!.advanced(by:offset),length-offset)}
            if count<0,errno==EINTR{continue};guard count>0 else{throw failure};offset+=count
        }
        return try JSONDecoder().decode(Marker.self,from:data)
    }
    private static func targetWitness(_ home:String,_ relative:String,_ id:String,checkpoint:()throws->Void)throws->CodexNativeArchivedFile {
        let witness=try CodexMigrationRolloutWitness.capture(home:home,homeIdentity:try identity(home),relative:relative,checkpoint:checkpoint)
        return .init(threadId:id,relativePath:witness.relativePath,fileIdentity:witness.fileIdentity,sha256:witness.sha256,
            size:witness.size,modifiedSeconds:witness.modifiedSeconds,modifiedNanoseconds:witness.modifiedNanoseconds)
    }
    private static func verifySource(_ file:CodexNativeArchivedFile,home:String,homeIdentity:String,scope:Set<String>,checkpoint:()throws->Void)throws {
        try file.validate(scope:scope)
        guard try CodexMigrationRolloutWitness.capture(home:home,homeIdentity:homeIdentity,relative:file.relativePath,checkpoint:checkpoint)==file.witness else{throw failure}
    }
    private static func copyOne(_ file:CodexNativeArchivedFile,sourceHome:String,sourceIdentity:String,
                                stageRoot:Int32,stageName:String,checkpoint:()throws->Void)throws {
        try checkpoint()
        try verifySource(file,home:sourceHome,homeIdentity:sourceIdentity,scope:[file.threadId],checkpoint:checkpoint)
        let (stages,stageFile)=try openParent(stageRoot,"files/\(stageName)",create:true,staging:true);defer{close(stages)}
        let existingStage=openat(stages,stageFile,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK)
        if existingStage>=0 {
            defer{close(existingStage)}
            var opened=stat(),named=stat()
            guard fstat(existingStage,&opened)==0,opened.st_mode&S_IFMT==S_IFREG,opened.st_uid==getuid(),
                  opened.st_nlink==1,opened.st_mode&0o077==0,opened.st_size>=0 else{throw failure}
            if opened.st_size<file.size {
                guard fstatat(stages,stageFile,&named,AT_SYMLINK_NOFOLLOW)==0,
                      named.st_dev==opened.st_dev,named.st_ino==opened.st_ino,
                      unlinkat(stages,stageFile,0)==0,fsync(stages)==0 else{throw failure}
            }else {
                let copied=try CodexMigrationRolloutWitness.read(existingStage,relative:file.relativePath,checkpoint:checkpoint)
                guard copied.sha256==file.sha256,copied.size==file.size else{throw failure}
                return
            }
        }else {
            guard errno==ENOENT else{throw failure}
        }
        let output=openat(stages,stageFile,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,0o600)
        guard output>=0 else{throw failure};defer{close(output)}
        let sourceRoot=try RetirementFiles.home(sourceHome,identity:sourceIdentity);defer{close(sourceRoot)}
        let input=try RetirementFiles.file(sourceRoot,file.relativePath);defer{close(input)}
        guard try CodexMigrationRolloutWitness.read(input,relative:file.relativePath,copyTo:output,checkpoint:checkpoint)==file.witness,
              fsync(output)==0 else{throw failure}
        try verifySource(file,home:sourceHome,homeIdentity:sourceIdentity,scope:[file.threadId],checkpoint:checkpoint)
    }
    private static func installOne(_ file:CodexNativeArchivedFile,destinationHome:String,destinationIdentity:String,
                                   destinationRoot:Int32,stageRoot:Int32,stageName:String,resume:Bool,checkpoint:()throws->Void)throws {
        let (parent,name)=try openParent(destinationRoot,file.relativePath,create:true);defer{close(parent)}
        let (stages,stageFile)=try openParent(stageRoot,"files/\(stageName)",create:false,staging:true);defer{close(stages)}
        if try exists(parent,name) {
            guard resume else{throw failure}
            let actual=try targetWitness(destinationHome,file.relativePath,file.threadId,checkpoint:checkpoint)
            guard actual.sha256==file.sha256,actual.size==file.size else{throw failure}
            let stagedFD=openat(stages,stageFile,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK)
            guard stagedFD>=0 else{throw failure};defer{close(stagedFD)}
            let staged=try CodexMigrationRolloutWitness.read(stagedFD,relative:file.relativePath,checkpoint:checkpoint)
            guard staged.sha256==file.sha256,staged.size==file.size,
                  unlinkat(stages,stageFile,0)==0,fsync(stages)==0 else{throw failure}
            return
        }
        guard renameatx_np(stages,stageFile,parent,name,UInt32(RENAME_EXCL))==0 else{throw failure}
        guard fsync(stages)==0,fsync(parent)==0 else{throw failure}
        let actual=try targetWitness(destinationHome,file.relativePath,file.threadId,checkpoint:checkpoint)
        guard actual.sha256==file.sha256,actual.size==file.size,
              try identity(destinationHome)==destinationIdentity else{throw failure}
    }
    static func install(requestID:String,sourceHome:String,sourceHomeIdentity:String,
                        destinationHome:String,destinationHomeIdentity:String,
                        files:[CodexNativeArchivedFile],goalSlots:[CodexGoalTransferSlotReference],
                        threadIDs:[String],checkpoint:()throws->Void={})throws->Self {
        guard UUID(uuidString:requestID)?.uuidString.lowercased()==requestID,
              try identity(sourceHome)==sourceHomeIdentity,try identity(destinationHome)==destinationHomeIdentity,
              sourceHome != destinationHome,sourceHomeIdentity != destinationHomeIdentity,
              (1...4096).contains(files.count),Set(threadIDs).count==threadIDs.count,
              Set(files.map(\.relativePath)).count==files.count,Set(files.map(\.threadId))==Set(threadIDs) else{throw failure}
        let scope=Set(threadIDs);var total:Int64=0
        for file in files {
            try checkpoint()
            try file.validate(scope:scope)
            let next=total.addingReportingOverflow(file.size)
            guard !next.overflow,next.partialValue<=1_073_741_824 else{throw failure};total=next.partialValue
            try verifySource(file,home:sourceHome,homeIdentity:sourceHomeIdentity,scope:scope,checkpoint:checkpoint)
        }
        guard goalSlots.count==scope.count,Set(goalSlots.map(\.threadID))==scope,
              goalSlots.map(\.threadID)==goalSlots.map(\.threadID).sorted() else{throw failure}
        var goalBytes=0
        var slots:[CodexGoalTransferSlot]=[]
        for reference in goalSlots {
            try reference.validate(requestID:requestID,sourceHome:sourceHome,threadIDs:scope)
            let slot=try CodexGoalTransferSlotStore.load(reference,home:sourceHome,homeIdentity:sourceHomeIdentity,
                requestID:requestID,threadIDs:scope)
            let (sum,overflow)=goalBytes.addingReportingOverflow(reference.size)
            guard !overflow,sum<=536_870_912 else{throw failure};goalBytes=sum
            slots.append(slot)
        }
        let sourceRoot=try RetirementFiles.home(sourceHome,identity:sourceHomeIdentity);defer{close(sourceRoot)}
        let destinationRoot=try RetirementFiles.home(destinationHome,identity:destinationHomeIdentity);defer{close(destinationRoot)}
        let migration=try openPrivateDirectory(destinationRoot,".autoapprove-migrations",create:true);defer{close(migration)}
        let imports=try openPrivateDirectory(migration,"imports",create:true);defer{close(imports)}
        let request=try openPrivateDirectory(imports,requestID,create:true);defer{close(request)}
        let stage=try openPrivateDirectory(request,"files",create:true);defer{close(stage)}
        let expected=Marker(formatVersion:1,requestID:requestID,sourceHomeIdentity:sourceHomeIdentity,
            destinationHomeIdentity:destinationHomeIdentity,files:files,goalSlots:goalSlots)
        let existing=try readMarker(request)
        let resume=existing != nil
        if let existing {guard existing==expected else{throw failure}}
        else {
            // An existing path without this exact request marker is prior data,
            // including a retired destination slot; never adopt or overwrite it.
            for file in files {guard try pathAbsent(destinationRoot,file.relativePath) else{throw failure}}
            for slot in slots {
                let target=try CodexGoalTransferStore.captureSlot(home:destinationHome,threadID:slot.threadID)
                guard target.row==nil,!target.continuationDeferred,
                      target.schemaFingerprint==slot.schemaFingerprint else{throw failure}
            }
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
            let data=try encoder.encode(expected)
            guard data.count<=768*1024 else{throw failure}
            let fd=openat(request,"manifest.json",O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,0o600)
            guard fd>=0 else{throw failure};defer{close(fd)}
            try data.withUnsafeBytes { buffer in
                var offset=0
                while offset<buffer.count {
                    let written=Darwin.write(fd,buffer.baseAddress!.advanced(by:offset),buffer.count-offset)
                    if written<0,errno==EINTR{continue};guard written>0 else{throw failure};offset+=written
                }
            }
            guard fsync(fd)==0,fsync(request)==0,fsync(imports)==0,fsync(migration)==0 else{throw failure}
        }
        for (index,file) in files.enumerated() {
            let name=String(format:"%08d.stage",index)
            try copyOne(file,sourceHome:sourceHome,sourceIdentity:sourceHomeIdentity,
                stageRoot:request,stageName:name,checkpoint:checkpoint)
        }
        for (index,file) in files.enumerated() {
            try checkpoint()
            try installOne(file,destinationHome:destinationHome,destinationIdentity:destinationHomeIdentity,
                destinationRoot:destinationRoot,stageRoot:request,stageName:String(format:"%08d.stage",index),resume:resume,checkpoint:checkpoint)
        }
        for slot in slots {
            try checkpoint()
            try CodexGoalTransferStore.restore(slot,toHome:destinationHome,allowExactExisting:resume)
            let target=try CodexGoalTransferStore.captureSlot(home:destinationHome,threadID:slot.threadID)
            guard target.row==slot.row,target.continuationDeferred==slot.continuationDeferred,
                  target.schemaFingerprint==slot.schemaFingerprint else{throw failure}
            try CodexGoalTransferStore.verifyCurrent(slot)
        }
        var imported:[CodexNativeArchivedFile]=[]
        for file in files {
            let actual=try targetWitness(destinationHome,file.relativePath,file.threadId,checkpoint:checkpoint)
            guard actual.sha256==file.sha256,actual.size==file.size else{throw failure}
            imported.append(actual)
            try verifySource(file,home:sourceHome,homeIdentity:sourceHomeIdentity,scope:scope,checkpoint:checkpoint)
        }
        return .init(marker:expected,importedFiles:imported)
    }
}
