import Foundation
import Darwin

/// Original Codex 0.169's cross-process writer-lock namespace. This holds only
/// persistent thread writers, not RPC admission, Goals, TUI drafts, subscriptions
/// or a complete client census. It grants no migration authority by itself.
final class CodexOfficialWriterLease {
    private struct File {
        let name:String,fd:Int32,device:dev_t,inode:ino_t
    }
    private let home:String
    private let homeFD:Int32,homeDevice:dev_t,homeInode:ino_t
    private let directoryFD:Int32,directoryDevice:dev_t,directoryInode:ino_t
    private var files:[File]=[]
    private var closed=false
    private static var failure:AppError {.message("선택한 대화의 공식 Codex 쓰기 잠금을 확인하지 못했습니다. 이력을 변경하지 않았습니다.")}

    init(home:String,threadIDs:[String])throws {
        let scope=threadIDs.sorted()
        guard !scope.isEmpty,scope.count<=512,Set(scope).count==scope.count,
              scope.allSatisfy({UUID(uuidString:$0)?.uuidString.lowercased()==$0}) else{throw Self.failure}
        self.home=try CodexAccountTransitionTarget.canonicalHome(home)
        let root=Darwin.open(self.home,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard root>=0 else{throw Self.failure}
        var rootInfo=stat()
        guard fstat(root,&rootInfo)==0,rootInfo.st_uid==getuid(),rootInfo.st_mode&S_IFMT==S_IFDIR else{Darwin.close(root);throw Self.failure}
        homeFD=root;homeDevice=rootInfo.st_dev;homeInode=rootInfo.st_ino
        // The official runtime creates this directory. Missing lock namespaces
        // cannot be guessed for older, remote or future storage implementations.
        let directory=openat(root,"thread-writer-locks",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard directory>=0 else{Darwin.close(root);throw Self.failure}
        var directoryInfo=stat()
        guard fstat(directory,&directoryInfo)==0,directoryInfo.st_uid==getuid(),directoryInfo.st_mode&S_IFMT==S_IFDIR else{
            Darwin.close(directory);Darwin.close(root);throw Self.failure
        }
        directoryFD=directory;directoryDevice=directoryInfo.st_dev;directoryInode=directoryInfo.st_ino
        do {
            // Hold shared coordination through the lease. Official writers use
            // the same shared lock; cleanup requires exclusive coordination and
            // therefore cannot unlink an inode while it is being held here.
            let coordination=try Self.openFile(directory:directory,name:".coordination.lock")
            files.append(coordination)
            guard flock(coordination.fd,LOCK_SH|LOCK_NB)==0 else{throw Self.failure}
            for id in scope {
                let file=try Self.openFile(directory:directory,name:id+".lock")
                files.append(file)
                guard flock(file.fd,LOCK_EX|LOCK_NB)==0 else{
                    throw AppError.message("이동 대상 대화를 다른 Codex가 기록하고 있습니다. 원래 실행과 이력을 유지했습니다.")
                }
            }
            try verifyUnchanged()
        }catch{close();throw error}
    }
    deinit{close()}
    private static func openFile(directory:Int32,name:String)throws->File {
        let fd=openat(directory,name,O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK,0o600)
        guard fd>=0 else{throw failure}
        var info=stat()
        guard fstat(fd,&info)==0,info.st_mode&S_IFMT==S_IFREG,info.st_uid==getuid(),info.st_nlink==1 else{Darwin.close(fd);throw failure}
        return .init(name:name,fd:fd,device:info.st_dev,inode:info.st_ino)
    }
    func verifyUnchanged()throws {
        guard !closed else{throw Self.failure}
        var root=stat(),directory=stat()
        guard lstat(home,&root)==0,root.st_mode&S_IFMT==S_IFDIR,root.st_uid==getuid(),root.st_dev==homeDevice,root.st_ino==homeInode,
              fstatat(homeFD,"thread-writer-locks",&directory,AT_SYMLINK_NOFOLLOW)==0,
              directory.st_mode&S_IFMT==S_IFDIR,directory.st_uid==getuid(),directory.st_dev==directoryDevice,directory.st_ino==directoryInode else{throw Self.failure}
        for file in files {
            var current=stat()
            guard fstatat(directoryFD,file.name,&current,AT_SYMLINK_NOFOLLOW)==0,
                  current.st_mode&S_IFMT==S_IFREG,current.st_uid==getuid(),current.st_nlink==1,
                  current.st_dev==file.device,current.st_ino==file.inode else{throw Self.failure}
        }
    }
    func verifyScope(home expectedHome:String,threadIDs:[String])throws {
        guard home == (try CodexAccountTransitionTarget.canonicalHome(expectedHome)),
              !threadIDs.isEmpty,Set(threadIDs).count==threadIDs.count,
              threadIDs.allSatisfy({id in files.contains(where:{$0.name==id+".lock"})}) else{throw Self.failure}
        try verifyUnchanged()
    }
    func close() {
        guard !closed else{return};closed=true
        // Thread locks close before coordination. Never unlink Codex's locks:
        // another official process may already be opening the same file.
        for file in files.reversed(){Darwin.close(file.fd)}
        files.removeAll();Darwin.close(directoryFD);Darwin.close(homeFD)
    }
}
