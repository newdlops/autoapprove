import Foundation
import Darwin
import CryptoKit

/// Only the application's fixed resource location can select a bundled CLI.
/// Profile files cannot supply an executable or a package manifest.
enum CodexBundledRuntime {
    private struct Manifest:Decodable {
        let format:Int,upstreamVersion:String,upstreamCommit:String,buildLabel:String,architecture:String
        let binarySHA256:String,features:[String],nativeRuntimeSchemaVersion:Int
    }
    private struct Package:Decodable {let version:String,target:String,entrypoint:String}
    fileprivate struct Identity:Equatable,Sendable {
        let device:dev_t,inode:ino_t,size:off_t,seconds:Int,nanos:Int
        init(_ info:stat){device=info.st_dev;inode=info.st_ino;size=info.st_size;seconds=info.st_mtimespec.tv_sec;nanos=info.st_mtimespec.tv_nsec}
    }
    struct Installation:Sendable {
        let executable:String
        let version="0.167.1"
        fileprivate let identity:Identity
        func verifyUnchanged()throws {
            let fd=try CodexBundledRuntime.file(executable)
            defer{close(fd)}
            var info=stat();guard fstat(fd,&info)==0,Identity(info)==identity else{throw CodexBundledRuntime.failure}
        }
    }
    private static var failure:AppError {.message("앱에 포함된 Codex 실행 파일의 버전·기능·지문을 확인하지 못했습니다. 기존 서버를 변경하지 않았습니다.")}
    static func bundled()throws->Installation? {
        guard let resources=Bundle.main.resourceURL else{return nil}
        let root=resources.appendingPathComponent("CodexRuntime",isDirectory:true).path
        var info=stat()
        if lstat(root,&info) != 0 {guard errno==ENOENT else{throw failure};return nil}
        return try inspect(root:root)
    }
    private static func directory(_ path:String)throws {
        var info=stat()
        guard lstat(path,&info)==0,info.st_mode&S_IFMT==S_IFDIR,[getuid(),0].contains(info.st_uid),info.st_mode&0o022==0 else{throw failure}
    }
    fileprivate static func file(_ path:String)throws->Int32 {
        let fd=open(path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard fd>=0 else{throw failure}
        var info=stat()
        guard fstat(fd,&info)==0,info.st_mode&S_IFMT==S_IFREG,[getuid(),0].contains(info.st_uid),info.st_mode&0o022==0 else{close(fd);throw failure}
        return fd
    }
    private static func json<T:Decodable>(_ type:T.Type,path:String)throws->T {
        let fd=try file(path);defer{close(fd)}
        var info=stat();guard fstat(fd,&info)==0,(1...1_048_576).contains(info.st_size) else{throw failure}
        let data=try FileHandle(fileDescriptor:fd,closeOnDealloc:false).read(upToCount:1_048_577) ?? Data()
        guard data.count==info.st_size else{throw failure}
        return try JSONDecoder().decode(type,from:data)
    }
    /// Internal validation seam; production callers always use bundled().
    static func inspect(root:String)throws->Installation {
        try directory(root);try directory(root+"/bin")
        let manifest=try json(Manifest.self,path:root+"/manifest.json")
        let package=try json(Package.self,path:root+"/codex-package.json")
        #if arch(arm64)
        let architecture="arm64",target="aarch64-apple-darwin"
        #else
        let architecture="x86_64",target="x86_64-apple-darwin"
        #endif
        let required:Set<String>=["codex-app-server/autoapprove-goal-control","codex-app-server/autoapprove-native-inventory",
                                  "codex-app-server/autoapprove-selected-transition","codex-tui/autoapprove-native-inventory"]
        guard manifest.format==1,manifest.upstreamVersion=="0.167.1",manifest.architecture==architecture,
              manifest.upstreamCommit=="0a94398fa60c4fac0e7659e4213a0a36e613dd46",
              manifest.buildLabel=="autoapprove-managed-1671-2",manifest.nativeRuntimeSchemaVersion==1,
              required.isSubset(of:manifest.features),manifest.features.count<=64,
              manifest.binarySHA256.utf8.count==64,manifest.binarySHA256.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}),
              package.version==manifest.upstreamVersion,package.target==target,package.entrypoint=="bin/codex" else{throw failure}
        let executable=root+"/bin/codex",fd=try file(executable);defer{close(fd)}
        var before=stat(),after=stat()
        guard fstat(fd,&before)==0,(4...1_073_741_824).contains(before.st_size),before.st_mode&0o111 != 0 else{throw failure}
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:false)
        var hash=SHA256(),tail=Data(),found=Set<Int>(),count=0
        let markers=[manifest.buildLabel,"autoapprove-native-runtime-registration","autoapprove-native-tui-input-hold"].map{Data($0.utf8)}
        while let chunk=try handle.read(upToCount:1_048_576),!chunk.isEmpty {
            try Task.checkCancellation()
            if count==0 {
                let magic=chunk.prefix(4).reduce(UInt32(0)){($0<<8)|UInt32($1)}
                guard [0xfeedface,0xcefaedfe,0xfeedfacf,0xcffaedfe,0xcafebabe,0xbebafeca,0xcafebabf,0xbfbafeca].contains(magic) else{throw failure}
            }
            count+=chunk.count;guard count<=before.st_size else{throw failure};hash.update(data:chunk)
            var scanned=tail;scanned.append(chunk)
            for (index,marker) in markers.enumerated() where scanned.range(of:marker) != nil{found.insert(index)}
            tail=Data(scanned.suffix(256))
        }
        guard count==before.st_size,found.count==markers.count,fstat(fd,&after)==0,Identity(before)==Identity(after),
              hash.finalize().map({String(format:"%02x",$0)}).joined()==manifest.binarySHA256 else{throw failure}
        return Installation(executable:executable,identity:Identity(before))
    }
}
