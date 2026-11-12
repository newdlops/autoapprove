import Foundation
import CryptoKit
import Darwin

/// Durable per-session Goal snapshots referenced by the bounded migration
/// journal. The SQLite row and continuation deferral are stored byte-for-byte
/// as a validated Codable slot; the journal records only their exact hashes.
struct CodexGoalTransferSlotReference:Codable,Equatable,Sendable {
    let threadID:String,relativePath:String,sha256:String
    let size:Int
    private static var failure:AppError {.message("세션 Goal의 저널 참조를 검증하지 못했습니다.")}
    func validate(requestID:String,sourceHome:String,threadIDs:Set<String>)throws {
        guard threadIDs.contains(threadID),relativePath==".autoapprove-migrations/goals/\(requestID)/\(threadID).json",
              (1...1_048_576).contains(size),sha256.count==64,
              sha256.allSatisfy({$0.isHexDigit}) else{throw Self.failure}
        _=sourceHome
    }
}

enum CodexGoalTransferSlotStore {
    private static var failure:AppError {.message("세션 Goal의 원본 스냅샷을 저널과 일치시키지 못했습니다. 기존 세션을 유지했습니다.")}
    private static func hash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    private static func encode(_ slot:CodexGoalTransferSlot)throws->Data {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        return try encoder.encode(slot)
    }
    private static func homeFD(_ path:String,_ identity:String)throws->Int32 {
        guard let physical=realpath(path,nil) else{throw failure};defer{free(physical)}
        guard String(cString:physical)==path else{throw failure}
        let fd=open(path,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);var info=stat()
        guard fd>=0,fstat(fd,&info)==0,info.st_uid==getuid(),"\(info.st_dev):\(info.st_ino)"==identity else{if fd>=0{close(fd)};throw failure}
        return fd
    }
    private static func directory(_ parent:Int32,_ name:String,create:Bool)throws->Int32 {
        if create {
            if mkdirat(parent,name,0o700)==0 {guard fsync(parent)==0 else{throw failure}}
            else if errno != EEXIST {throw failure}
        }
        let fd=openat(parent,name,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);var info=stat()
        guard fd>=0,fstat(fd,&info)==0,info.st_uid==getuid(),info.st_mode&S_IFMT==S_IFDIR,
              info.st_mode&0o077==0 else{if fd>=0{close(fd)};throw failure}
        return fd
    }
    private static func read(_ directory:Int32,_ name:String)throws->Data? {
        let fd=openat(directory,name,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK)
        if fd<0 {if errno==ENOENT{return nil};throw failure};defer{close(fd)}
        var info=stat();guard fstat(fd,&info)==0,info.st_mode&S_IFMT==S_IFREG,info.st_uid==getuid(),
              info.st_mode&0o077==0,info.st_nlink==1,info.st_size>0,info.st_size<=1_048_576 else{throw failure}
        var data=Data(count:Int(info.st_size)),offset=0;let length=data.count
        while offset<length {
            let n=data.withUnsafeMutableBytes{Darwin.read(fd,$0.baseAddress!.advanced(by:offset),length-offset)}
            if n<0,errno==EINTR{continue};guard n>0 else{throw failure};offset+=n
        }
        var after=stat();guard fstat(fd,&after)==0,info.st_dev==after.st_dev,info.st_ino==after.st_ino,
              info.st_size==after.st_size,info.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec,
              info.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec else{throw failure}
        return data
    }
    private static func write(_ data:Data,_ directory:Int32,_ name:String)throws {
        let fd=openat(directory,name,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,0o600)
        if fd<0 {
            guard errno==EEXIST,try read(directory,name)==data else{throw failure}
            return
        }
        defer{close(fd)}
        try data.withUnsafeBytes { buffer in
            var offset=0
            while offset<buffer.count {
                let n=Darwin.write(fd,buffer.baseAddress!.advanced(by:offset),buffer.count-offset)
                if n<0,errno==EINTR{continue};guard n>0 else{throw failure};offset+=n
            }
        }
        guard fsync(fd)==0,fsync(directory)==0 else{throw failure}
    }
    static func capture(home:String,homeIdentity:String,requestID:String,threadIDs:[String])throws->[CodexGoalTransferSlotReference] {
        guard UUID(uuidString:requestID)?.uuidString.lowercased()==requestID,
              !threadIDs.isEmpty,Set(threadIDs).count==threadIDs.count,
              threadIDs.allSatisfy({UUID(uuidString:$0)?.uuidString.lowercased()==$0}) else{throw failure}
        let root=try homeFD(home,homeIdentity);defer{close(root)}
        let migration=try directory(root,".autoapprove-migrations",create:false);defer{close(migration)}
        let goals=try directory(migration,"goals",create:true);defer{close(goals)}
        let request=try directory(goals,requestID,create:true);defer{close(request)}
        var refs:[CodexGoalTransferSlotReference]=[]
        for id in threadIDs.sorted() {
            let slot=try CodexGoalTransferStore.captureSlot(home:home,threadID:id)
            guard slot.sourceHome==home,slot.homeIdentity==homeIdentity,slot.threadID==id else{throw failure}
            let data=try encode(slot);guard (1...1_048_576).contains(data.count) else{throw failure}
            let digest=hash(data);try write(data,request,id+".json")
            guard try read(request,id+".json")==data else{throw failure}
            try CodexGoalTransferStore.verifyCurrent(slot)
            refs.append(.init(threadID:id,relativePath:".autoapprove-migrations/goals/\(requestID)/\(id).json",
                sha256:digest,size:data.count))
        }
        guard fsync(request)==0,fsync(goals)==0,fsync(migration)==0 else{throw failure}
        return refs
    }
    static func load(_ reference:CodexGoalTransferSlotReference,home:String,homeIdentity:String,
                     requestID:String,threadIDs:Set<String>)throws->CodexGoalTransferSlot {
        try reference.validate(requestID:requestID,sourceHome:home,threadIDs:threadIDs)
        let root=try homeFD(home,homeIdentity);defer{close(root)}
        let migration=try directory(root,".autoapprove-migrations",create:false);defer{close(migration)}
        let goals=try directory(migration,"goals",create:false);defer{close(goals)}
        let request=try directory(goals,requestID,create:false);defer{close(request)}
        guard let data=try read(request,reference.threadID+".json"),data.count==reference.size,hash(data)==reference.sha256 else{throw failure}
        let slot=try JSONDecoder().decode(CodexGoalTransferSlot.self,from:data)
        guard slot.threadID==reference.threadID,slot.sourceHome==home,slot.homeIdentity==homeIdentity,
              slot.digest.count==64 else{throw failure}
        try CodexGoalTransferStore.verifyCurrent(slot)
        return slot
    }
}
