import Foundation
import Darwin

// File-resource evidence only. This does not identify the live AuthManager's
// backend, read a token, verify an account or authorize a migration. A native
// runtime binding is still required before treating this as credential isolation.
struct CodexCredentialFile:Codable,Equatable {
    struct Entry:Codable,Equatable {
        let identity:String,size:Int64
        let modifiedSeconds:Int64,modifiedNanoseconds:Int64
        let changedSeconds:Int64,changedNanoseconds:Int64
    }
    let formatVersion:Int
    let selectedHome:String,physicalHome:String,homeIdentity:String
    let entry:Entry?
    private static var failure:AppError {
        .message("Codex 인증 파일의 독립성 또는 신원이 바뀌었습니다. 기존 로그인과 세션을 유지했습니다.")
    }
    private static func identity(_ value:stat)->String {"\(value.st_dev):\(value.st_ino)"}
    private static func directory(_ value:stat)throws {
        guard value.st_mode&S_IFMT==S_IFDIR,value.st_uid==getuid(),value.st_mode&0o022==0 else{throw failure}
    }
    private static func file(_ value:stat)throws->Entry {
        guard value.st_mode&S_IFMT==S_IFREG,value.st_uid==getuid(),value.st_mode&0o077==0,
              value.st_nlink==1,value.st_size>=0 else{throw failure}
        return .init(identity:identity(value),size:Int64(value.st_size),
                     modifiedSeconds:Int64(value.st_mtimespec.tv_sec),modifiedNanoseconds:Int64(value.st_mtimespec.tv_nsec),
                     changedSeconds:Int64(value.st_ctimespec.tv_sec),changedNanoseconds:Int64(value.st_ctimespec.tv_nsec))
    }
    static func capture(home:String)throws->Self {
        _ = try CodexAccountTransitionTarget.canonicalHome(home)
        // Keep the caller's selected alias so later retargeting is observable.
        let selected=URL(fileURLWithPath:home).standardizedFileURL.path
        guard let pointer=realpath(selected,nil) else{throw failure};defer{free(pointer)}
        let physical=String(cString:pointer)
        let root=open(physical,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard root>=0 else{throw failure};defer{close(root)}
        var initial=stat();guard fstat(root,&initial)==0 else{throw failure};try directory(initial)
        // O_EVTONLY obtains metadata without opening the credential for reading.
        var pathInfo=stat()
        if fstatat(root,"auth.json",&pathInfo,AT_SYMLINK_NOFOLLOW)==0 {_ = try file(pathInfo)}
        else if errno != ENOENT {throw failure}
        let fd=openat(root,"auth.json",O_EVTONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC)
        let entry:Entry?
        if fd<0 {
            guard errno==ENOENT else{throw failure}
            var absent=stat()
            guard fstatat(root,"auth.json",&absent,AT_SYMLINK_NOFOLLOW)<0,errno==ENOENT else{throw failure}
            entry=nil
        }else{
            defer{close(fd)}
            var info=stat();guard fstat(fd,&info)==0 else{throw failure}
            let opened=try file(info)
            var current=stat()
            guard fstatat(root,"auth.json",&current,AT_SYMLINK_NOFOLLOW)==0,try file(current)==opened else{throw failure}
            entry=opened
        }
        var current=stat()
        guard lstat(physical,&current)==0,identity(current)==identity(initial) else{throw failure}
        try directory(current)
        // Recheck the selected alias as well as the opened physical directory.
        guard let fresh=realpath(selected,nil) else{throw failure};defer{free(fresh)}
        guard String(cString:fresh)==physical else{throw failure}
        return .init(formatVersion:1,selectedHome:selected,physicalHome:physical,homeIdentity:identity(initial),entry:entry)
    }
    func verifyCurrent()throws {
        guard formatVersion==1,try Self.capture(home:selectedHome)==self else{throw Self.failure}
    }
    static func requireIndependent(_ source:Self,_ destination:Self)throws {
        try source.verifyCurrent();try destination.verifyCurrent()
        guard source.physicalHome != destination.physicalHome,source.homeIdentity != destination.homeIdentity else{throw failure}
        if let a=source.entry,let b=destination.entry {guard a.identity != b.identity else{throw failure}}
        try source.verifyCurrent();try destination.verifyCurrent()
    }
    /// Called only by an explicit request to reuse this account in a newly
    /// created independent home. Credential bytes never leave this function.
    func copyForIndependentLogin(to home:String)throws {
        let destination=try Self.capture(home:home)
        try Self.requireIndependent(self,destination)
        guard let expected=entry,expected.size>0,expected.size<=1_048_576,destination.entry==nil else {
            throw AppError.message("복사할 파일 기반 로그인이나 비어 있는 독립 홈을 확인하지 못했습니다. 독립 홈에서 브라우저 로그인을 사용해주세요.")
        }
        let source=open(physicalHome+"/auth.json",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard source>=0 else{throw Self.failure};defer{close(source)}
        var before=stat(),after=stat()
        guard fstat(source,&before)==0,try Self.file(before)==expected else{throw Self.failure}
        let bytes=try FileHandle(fileDescriptor:source,closeOnDealloc:false).read(upToCount:1_048_577) ?? Data()
        guard bytes.count==expected.size,fstat(source,&after)==0,try Self.file(after)==expected,
              (try? JSONSerialization.jsonObject(with:bytes)) is [String:Any] else{throw Self.failure}
        try verifyCurrent();try destination.verifyCurrent()
        let root=open(destination.physicalHome,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard root>=0 else{throw Self.failure};defer{close(root)}
        var info=stat()
        guard fstat(root,&info)==0,Self.identity(info)==destination.homeIdentity else{throw Self.failure}
        let temporary=".auth-independent-"+UUID().uuidString.lowercased()
        let output=openat(root,temporary,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard output>=0 else{throw Self.failure}
        defer{close(output);unlinkat(root,temporary,0)}
        try FileHandle(fileDescriptor:output,closeOnDealloc:false).write(contentsOf:bytes)
        guard fsync(output)==0 else{throw Self.failure}
        try verifyCurrent();try destination.verifyCurrent()
        guard renameatx_np(root,temporary,root,"auth.json",UInt32(RENAME_EXCL))==0,fsync(root)==0 else{throw Self.failure}
        try Self.requireIndependent(self,Self.capture(home:home))
    }
    func copyConfigurationForIndependentLogin(to home:String)throws {
        let destination=try Self.capture(home:home)
        try Self.requireIndependent(self,destination)
        guard destination.entry==nil else{throw Self.failure}
        let input=open(physicalHome+"/config.toml",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        if input<0 {guard errno==ENOENT else{throw Self.failure};return}
        defer{close(input)}
        var before=stat(),after=stat()
        guard fstat(input,&before)==0,before.st_mode&S_IFMT==S_IFREG,before.st_uid==getuid(),
              before.st_nlink==1,(0...1_048_576).contains(before.st_size) else{throw Self.failure}
        let bytes=try FileHandle(fileDescriptor:input,closeOnDealloc:false).read(upToCount:1_048_577) ?? Data()
        guard bytes.count==before.st_size,fstat(input,&after)==0,
              before.st_ino==after.st_ino,before.st_dev==after.st_dev,before.st_size==after.st_size,
              before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec,before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec==after.st_ctimespec.tv_sec,before.st_ctimespec.tv_nsec==after.st_ctimespec.tv_nsec else{throw Self.failure}
        try verifyCurrent();try destination.verifyCurrent()
        let root=open(destination.physicalHome,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard root>=0 else{throw Self.failure};defer{close(root)}
        var info=stat()
        guard fstat(root,&info)==0,Self.identity(info)==destination.homeIdentity else{throw Self.failure}
        let temporary=".config-independent-"+UUID().uuidString.lowercased()
        let output=openat(root,temporary,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard output>=0 else{throw Self.failure};defer{close(output);unlinkat(root,temporary,0)}
        try FileHandle(fileDescriptor:output,closeOnDealloc:false).write(contentsOf:bytes)
        guard fsync(output)==0 else{throw Self.failure}
        try destination.verifyCurrent()
        guard renameat(root,temporary,root,"config.toml")==0,fsync(root)==0 else{throw Self.failure}
    }
}
