import Foundation
import Darwin

public struct CodexLoginGroup:Codable,Equatable,Identifiable,Sendable {
    public let id:UUID,name:String,home:String,homeIdentity:String,createdAt:Date
}

/// Named destinations only. Creation never starts a CLI/server or copies auth.
public struct CodexLoginGroupStore:Sendable {
    public let directory:URL
    public init(directory:URL){self.directory=directory}
    private struct Document:Codable,Equatable {
        var version=1
        let root:String,identity:String
        var groups:[CodexLoginGroup]=[]
    }
    private static var failure:AppError {.message("로그인 그룹 저장소나 홈이 바뀌었습니다. 기존 그룹을 유지했습니다. 경로와 접근 권한을 확인해주세요.")}
    private static func identity(_ info:stat)->String {"\(info.st_dev):\(info.st_ino)"}
    private final class Root {
        let path:String,identity:String,fd:Int32
        var lockFD:Int32 = -1
        init(_ directory:URL,create:Bool,lock:Bool)throws {
            if create {try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}
            var selected=stat()
            guard lstat(directory.path,&selected)==0,selected.st_mode&S_IFMT==S_IFDIR,selected.st_uid==getuid(),selected.st_mode&0o077==0,
                  let pointer=realpath(directory.path,nil) else{throw failure}
            path=String(cString:pointer);free(pointer)
            fd=open(path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
            var info=stat()
            guard fd>=0,fstat(fd,&info)==0,info.st_dev==selected.st_dev,info.st_ino==selected.st_ino else {
                if fd>=0{close(fd)};throw failure
            }
            identity=CodexLoginGroupStore.identity(info)
            if lock {
                lockFD=openat(fd,"lock",O_RDWR|O_CREAT|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC,0o600)
                guard lockFD>=0,fstat(lockFD,&info)==0,info.st_mode&S_IFMT==S_IFREG,info.st_uid==getuid(),
                      info.st_mode&0o077==0,info.st_nlink==1,flock(lockFD,LOCK_EX|LOCK_NB)==0 else {
                    if lockFD>=0{close(lockFD)};close(fd);throw failure
                }
            }
        }
        deinit{if lockFD>=0{close(lockFD)};close(fd)}
        func verify()throws {
            var info=stat()
            guard lstat(path,&info)==0,info.st_mode&S_IFMT==S_IFDIR,info.st_uid==getuid(),info.st_mode&0o077==0,
                  CodexLoginGroupStore.identity(info)==identity else{throw failure}
        }
    }
    private static func name(_ raw:String)throws->String {
        let value=raw.trimmingCharacters(in:.whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !value.isEmpty,value.count<=80,!value.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else{
            throw AppError.message("그룹 이름은 줄바꿈 없이 1~80자로 입력해주세요.")
        };return value
    }
    private static func nameKey(_ value:String)->String {value.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"en_US_POSIX"))}
    private static func home(_ group:CodexLoginGroup,_ root:Root)throws {
        guard group.home==root.path+"/homes/"+group.id.uuidString.lowercased(),try name(group.name)==group.name,
              group.createdAt.timeIntervalSince1970.isFinite else{throw failure}
        var parent=stat(),info=stat()
        guard lstat(root.path+"/homes",&parent)==0,parent.st_mode&S_IFMT==S_IFDIR,parent.st_uid==getuid(),parent.st_mode&0o077==0,
              lstat(group.home,&info)==0,info.st_mode&S_IFMT==S_IFDIR,info.st_uid==getuid(),info.st_mode&0o077==0,
              identity(info)==group.homeIdentity else{throw failure}
    }
    private static func load(_ root:Root)throws->Document {
        let fd=openat(root.fd,"groups.json",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        if fd<0 {
            guard errno==ENOENT else{throw failure}
            // An empty initial directory is recoverable. Missing metadata with
            // any homes/data is unknown; never reset it to an empty registry.
            let names=try FileManager.default.contentsOfDirectory(atPath:root.path)
            guard Set(names).isSubset(of:["lock"]) else{throw failure}
            try root.verify();return .init(root:root.path,identity:root.identity)
        }
        defer{close(fd)}
        var info=stat()
        guard fstat(fd,&info)==0,info.st_mode&S_IFMT==S_IFREG,info.st_uid==getuid(),info.st_mode&0o077==0,
              info.st_nlink==1,info.st_size>0,info.st_size<=65536 else{throw failure}
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:false)
        let data=try handle.read(upToCount:65537) ?? Data()
        guard data.count==info.st_size else{throw failure}
        let document:Document
        do{document=try JSONDecoder().decode(Document.self,from:data)}catch{throw failure}
        guard document.version==1,document.root==root.path,document.identity==root.identity,document.groups.count<=32,
              Set(document.groups.map(\.id)).count==document.groups.count,
              Set(document.groups.map{ nameKey($0.name) }).count==document.groups.count else{throw failure}
        for group in document.groups {try home(group,root)}
        try root.verify();return document
    }
    private static func save(_ document:Document,_ root:Root)throws {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let data=try encoder.encode(document);guard data.count<=65536 else{throw failure}
        let temporary=".groups-"+UUID().uuidString.lowercased()
        let fd=openat(root.fd,temporary,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd>=0 else{throw failure}
        defer{close(fd);unlinkat(root.fd,temporary,0)}
        try FileHandle(fileDescriptor:fd,closeOnDealloc:false).write(contentsOf:data)
        guard fsync(fd)==0 else{throw failure};try root.verify()
        guard renameat(root.fd,temporary,root.fd,"groups.json")==0,fsync(root.fd)==0 else{throw failure}
        try root.verify()
    }
    public func list()throws->[CodexLoginGroup] {
        var info=stat()
        if lstat(directory.path,&info)<0 {guard errno==ENOENT else{throw Self.failure};return []}
        return try Self.load(Root(directory,create:false,lock:false)).groups
    }
    public func validate(home:String)throws {
        // Other detected user homes retain their existing behavior. An app-owned
        // group path must still be registered with the same directory identity.
        let logical=directory.standardizedFileURL.path+"/homes/"
        let canonical=try CodexAccountTransitionTarget.canonicalHome(home)
        let rootCanonical=try CodexAccountTransitionTarget.canonicalHome(directory.path)+"/homes/"
        guard home.hasPrefix(directory.path+"/homes/") || home.hasPrefix(logical) || canonical.hasPrefix(rootCanonical) else{return}
        guard try list().contains(where:{$0.home==canonical || (try? CodexAccountTransitionTarget.canonicalHome($0.home))==canonical}) else{throw Self.failure}
    }
    @discardableResult public func rename(id:UUID,name raw:String)throws->CodexLoginGroup {
        let name=try Self.name(raw),root=try Root(directory,create:false,lock:true)
        var document=try Self.load(root)
        guard let index=document.groups.firstIndex(where:{$0.id==id}) else{throw AppError.message("이 로그인 그룹을 찾지 못했습니다. 그룹을 다시 확인해주세요.")}
        guard !document.groups.contains(where:{$0.id != id && Self.nameKey($0.name)==Self.nameKey(name)}) else{throw AppError.message("같은 이름의 로그인 그룹이 있습니다. 다른 이름을 입력해주세요.")}
        let old=document.groups[index]
        if old.name==name{return old}
        let updated=CodexLoginGroup(id:old.id,name:name,home:old.home,homeIdentity:old.homeIdentity,createdAt:old.createdAt)
        document.groups[index]=updated;try Self.save(document,root)
        return updated
    }
    @discardableResult public func create(name raw:String,daemonAutoStart:Bool?=nil)throws->CodexLoginGroup {
        let name=try Self.name(raw),root=try Root(directory,create:true,lock:true)
        var document=try Self.load(root)
        guard document.groups.count<32 else{throw AppError.message("로그인 그룹은 최대 32개까지 만들 수 있습니다.")}
        guard !document.groups.contains(where:{Self.nameKey($0.name)==Self.nameKey(name)}) else{throw AppError.message("같은 이름의 로그인 그룹이 있습니다. 다른 이름을 입력해주세요.")}
        // Persist the empty index before creating a home. A later partial create
        // never causes existing groups to disappear or become newly adopted.
        try Self.save(document,root)
        if mkdirat(root.fd,"homes",0o700) != 0,errno != EEXIST{throw Self.failure}
        let homes=openat(root.fd,"homes",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard homes>=0 else{throw Self.failure};defer{close(homes)}
        var info=stat();guard fstat(homes,&info)==0,info.st_uid==getuid(),info.st_mode&0o077==0 else{throw Self.failure}
        let id=UUID(),folder=id.uuidString.lowercased(),path=root.path+"/homes/"+folder
        guard mkdirat(homes,folder,0o700)==0 else{throw Self.failure}
        let home=openat(homes,folder,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard home>=0 else{throw Self.failure};defer{close(home)}
        guard fstat(home,&info)==0 else{throw Self.failure}
        let identity=Self.identity(info),config=openat(home,"config.toml",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard config>=0 else{throw Self.failure};defer{close(config)}
        var settings="cli_auth_credentials_store = \"file\"\n"
        if let daemonAutoStart {settings += "[features]\ndaemon_auto_start = \(daemonAutoStart ? "true":"false")\n"}
        try FileHandle(fileDescriptor:config,closeOnDealloc:false).write(contentsOf:Data(settings.utf8))
        guard fsync(config)==0,fsync(home)==0,fsync(homes)==0 else{throw Self.failure}
        let group=CodexLoginGroup(id:id,name:name,home:path,homeIdentity:identity,createdAt:Date())
        try Self.home(group,root);document.groups.append(group);try Self.save(document,root)
        return group
    }
}
