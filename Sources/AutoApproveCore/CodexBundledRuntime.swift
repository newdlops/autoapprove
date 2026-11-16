import Foundation
import Darwin
import CryptoKit

/// Launch only bytes from the official release pinned in the signed app's
/// resources. A runtime's own manifest cannot attest or select its executable.
enum CodexBundledRuntime {
    struct Release:Decodable,Sendable {
        let format:Int
        let version:String
        let upstreamCommit:String
        let architecture:String
        let target:String
        let files:[String:String]
        static func bundled()throws->Self {
            // The packaged app keeps the resource bundle in Contents/Resources.
            // SPM's Bundle.module traps when it cannot find the bundle there, so
            // check the packaged location first, as RemoteWebVersion does.
            let packaged=Bundle.main.resourceURL?.appendingPathComponent("AutoApprove_AutoApproveCore.bundle/CodexOfficialRelease.json")
            let url:URL
            if let packaged, FileManager.default.fileExists(atPath:packaged.path) {
                url=packaged
            } else {
                guard let module=Bundle.module.url(forResource:"CodexOfficialRelease",withExtension:"json") else{throw failure}
                url=module
            }
            return try JSONDecoder().decode(Self.self,from:Data(contentsOf:url))
        }
    }
    private struct Package:Decodable {let version:String,target:String,entrypoint:String}
    fileprivate struct Identity:Equatable,Sendable {
        let device:dev_t,inode:ino_t,size:off_t,seconds:Int,nanos:Int
        init(_ info:stat){device=info.st_dev;inode=info.st_ino;size=info.st_size;seconds=info.st_mtimespec.tv_sec;nanos=info.st_mtimespec.tv_nsec}
    }
    struct Installation:Sendable {
        let executable:String
        let version:String
        fileprivate let identities:[String:Identity]
        func verifyUnchanged()throws {
            for (path,identity) in identities {
                let fd=try CodexBundledRuntime.file(path)
                defer{close(fd)}
                var info=stat();guard fstat(fd,&info)==0,Identity(info)==identity else{throw failure}
            }
        }
    }
    private static var failure:AppError {.message("공식 Codex 실행 파일과 리소스의 버전·지문을 확인하지 못했습니다. 앱을 다시 설치해주세요.")}
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
    /// The injected catalog is an internal fixture seam. Production always uses
    /// the catalog packaged with AutoApprove, never data from the runtime tree.
    static func inspect(root:String,release supplied:Release?=nil)throws->Installation {
        let release=try supplied ?? Release.bundled()
        #if arch(arm64)
        let architecture="arm64",target="aarch64-apple-darwin"
        #else
        let architecture="x86_64",target="x86_64-apple-darwin"
        #endif
        guard release.format==1,release.architecture==architecture,release.target==target,
              release.version.range(of:#"^\d+\.\d+\.\d+$"#,options:.regularExpression) != nil,
              release.files["bin/codex"] != nil,release.files["codex-package.json"] != nil,
              release.files.count<=16384 else{throw failure}
        try directory(root)
        var identities:[String:Identity]=[:],packageData:Data?
        for (relative,expected) in release.files {
            let parts=relative.split(separator:"/",omittingEmptySubsequences:false)
            guard !relative.hasPrefix("/"),!relative.contains("\\"),!relative.contains("\0"),
                  parts.allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".."}),
                  expected.count==64,expected.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) else{throw failure}
            var parent=root
            for part in parts.dropLast(){parent+="/"+part;try directory(parent)}
            let path=root+"/"+relative,fd=try file(path)
            defer{close(fd)}
            var before=stat(),after=stat()
            guard fstat(fd,&before)==0,(0...1_073_741_824).contains(before.st_size),
                  relative != "bin/codex" || before.st_mode&0o111 != 0 else{throw failure}
            let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:false)
            var hash=SHA256(),count=0,metadata=Data()
            while let chunk=try handle.read(upToCount:1_048_576),!chunk.isEmpty {
                try Task.checkCancellation()
                count+=chunk.count;guard count<=before.st_size else{throw failure}
                hash.update(data:chunk)
                if relative=="codex-package.json" {guard count<=1_048_576 else{throw failure};metadata.append(chunk)}
            }
            guard count==before.st_size,fstat(fd,&after)==0,Identity(before)==Identity(after),
                  hash.finalize().map({String(format:"%02x",$0)}).joined()==expected else{throw failure}
            identities[path]=Identity(before)
            if relative=="codex-package.json" {packageData=metadata}
        }
        guard let packageData else{throw failure}
        let package=try JSONDecoder().decode(Package.self,from:packageData)
        guard package.version==release.version,package.target==target,package.entrypoint=="bin/codex" else{throw failure}
        return Installation(executable:root+"/bin/codex",version:release.version,identities:identities)
    }
}
