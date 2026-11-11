import Foundation
import Darwin

enum CodexNativeRuntimeRole: String, Codable, Sendable {
    case tui, server
    var prefix: String { self == .tui ? "t" : "s" }
    var control: String { self == .tui ? "terminal-input-hold" : "selected-input-lease" }
    var producer: String { self == .tui ? "autoapprove-native-tui-prototype" : "autoapprove-native-server-prototype" }
}
/// Discovery hints only. A file's claimed identity cannot create a kernel witness.
struct CodexNativeRuntimeHint: Sendable {
    let inventorySocket: String, controlSocket: String
    let claimedPeer: CodexNativePeerIdentity
}
enum CodexNativeRuntimeRegistry {
    private struct Record: Decodable {
        let schemaVersion: Int, producer: String, cliVersion: String, registrationId: String
        let role: CodexNativeRuntimeRole, controlKind: String, pid: UInt32
        let processIdentity: CodexNativePeerIdentity
        let home: String, inventorySocket: String, controlSocket: String
        let membershipComplete: Bool, migrationAuthorized: Bool
    }
    private struct Header: Decodable {
        let schemaVersion: Int, producer: String, cliVersion: String, pid: UInt32, nonce: String
        let membershipComplete: Bool, admissionGranted: Bool
    }
    private static var failure: AppError {
        .message("Codex 창·서버의 유일한 제어 연결을 확인하지 못했습니다. 기존 세션을 유지했습니다.")
    }
    private static func privateDirectory(_ fd: Int32) throws -> stat {
        var info=stat()
        guard fd>=0,fstat(fd,&info)==0,info.st_mode&S_IFMT==S_IFDIR,info.st_uid==getuid(),info.st_mode&0o077==0 else{throw failure}
        return info
    }
    private static func sameDirectory(_ path:String,_ expected:stat)->Bool {
        var info=stat()
        return lstat(path,&info)==0 && info.st_mode&S_IFMT==S_IFDIR && info.st_uid==getuid()
            && info.st_mode&0o077==0 && info.st_dev==expected.st_dev && info.st_ino==expected.st_ino
    }
    static func candidates(root:String,pid:Int32,role:CodexNativeRuntimeRole,home:String)throws->[CodexNativeRuntimeHint] {
        guard pid>0,CodexNativeRuntimeRoot.existing(at:root)==root else{throw failure}
        // Foundation may prefer /tmp while Rust canonicalize uses /private/tmp.
        // Match the same actual home using the OS path, without changing any home.
        let permitted=try CodexAccountTransitionTarget.canonicalHome(home)
        guard let pointer=realpath(permitted,nil) else{throw failure};defer{free(pointer)}
        let expectedHome=String(cString:pointer)
        var homeInfo=stat()
        guard lstat(expectedHome,&homeInfo)==0,homeInfo.st_mode&S_IFMT==S_IFDIR,homeInfo.st_uid==getuid() else{throw failure}
        let fd=open(root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard fd>=0 else{throw failure};defer{close(fd)}
        let rootInfo=try privateDirectory(fd),duplicate=dup(fd)
        guard duplicate>=0 else{throw failure}
        guard let stream=fdopendir(duplicate) else{close(duplicate);throw failure}
        defer{closedir(stream)}
        let prefix=role.prefix+"-"+String(pid)+"-"
        var result:[CodexNativeRuntimeHint]=[],count=0
        while true {
            try Task.checkCancellation();errno=0
            guard let entry=readdir(stream) else{guard errno==0 else{throw failure};break}
            count+=1;guard count<=4096 else{throw failure}
            let name=withUnsafeBytes(of:entry.pointee.d_name){String(decoding:$0.prefix{$0 != 0},as:UTF8.self)}
            guard name.hasPrefix(prefix),name.utf8.count==prefix.utf8.count+32,
                  name.dropFirst(prefix.count).utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) else{continue}
            do {result.append(try candidate(fd,root:root,name:name,pid:pid,role:role,home:expectedHome))}
            catch is CancellationError {throw CancellationError()} catch {continue}
            guard result.count<=8 else{throw failure}
        }
        guard sameDirectory(root,rootInfo) else{throw failure}
        return result
    }
    private static func candidate(_ parent:Int32,root:String,name:String,pid:Int32,role:CodexNativeRuntimeRole,home:String)throws->CodexNativeRuntimeHint {
        let fd=openat(parent,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard fd>=0 else{throw failure};defer{close(fd)}
        let directory=try privateDirectory(fd)
        let record=openat(fd,"registration.json",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard record>=0 else{throw failure};defer{close(record)}
        var info=stat()
        guard fstat(record,&info)==0,info.st_mode&S_IFMT==S_IFREG,info.st_uid==getuid(),
              info.st_mode&0o077==0,info.st_nlink==1,(1...16384).contains(info.st_size) else{throw failure}
        let data=try FileHandle(fileDescriptor:record,closeOnDealloc:false).read(upToCount:16385) ?? Data()
        guard data.count==info.st_size else{throw failure}
        let value=try JSONDecoder().decode(Record.self,from:data)
        guard value.schemaVersion==1,value.producer=="autoapprove-native-runtime-registration",value.cliVersion=="0.167.1",
              UUID(uuidString:value.registrationId)?.uuidString.lowercased()==value.registrationId,
              name==role.prefix+"-"+String(pid)+"-"+value.registrationId.replacingOccurrences(of:"-",with:""),
              value.role==role,value.controlKind==role.control,value.pid==UInt32(pid),value.home==home,
              value.processIdentity.source=="macos-audit-token",value.processIdentity.pid==UInt32(pid),
              value.processIdentity.effectiveUid==getuid(),value.processIdentity.auditPidVersion>0,
              value.inventorySocket=="i.sock",value.controlSocket=="c.sock",!value.membershipComplete,!value.migrationAuthorized
        else{throw failure}
        for socket in [value.inventorySocket,value.controlSocket] {
            var info=stat()
            guard fstatat(fd,socket,&info,AT_SYMLINK_NOFOLLOW)==0,info.st_mode&S_IFMT==S_IFSOCK,
                  info.st_uid==getuid(),info.st_mode&0o077==0 else{throw failure}
        }
        let path=root+"/"+name
        guard sameDirectory(path,directory) else{throw failure}
        return .init(inventorySocket:path+"/i.sock",controlSocket:path+"/c.sock",claimedPeer:value.processIdentity)
    }
    static func live(_ hints:[CodexNativeRuntimeHint],role:CodexNativeRuntimeRole)async throws->CodexNativeRuntimeHint {
        let values=await withTaskGroup(of:CodexNativeRuntimeHint?.self,returning:[CodexNativeRuntimeHint].self){group in
            for hint in hints {group.addTask {
                do {
                    let read=try await CodexNativeObservation.query(path:hint.inventorySocket)
                    let head=try JSONDecoder().decode(Header.self,from:read.data)
                    guard read.peer.identity==hint.claimedPeer,head.schemaVersion==1,head.producer==role.producer,
                          head.cliVersion=="0.167.1",head.pid==hint.claimedPeer.pid,head.nonce==read.nonce,
                          !head.membershipComplete,!head.admissionGranted else{return nil}
                    return hint
                }catch{return nil}
            }}
            var values:[CodexNativeRuntimeHint]=[]
            for await value in group {if let value{values.append(value)}}
            return values
        }
        try Task.checkCancellation()
        guard values.count==1,let value=values.first else{throw failure}
        return value
    }
}

/// A current displayed association plus its discovered controls, never a full census.
struct CodexNativeRuntimePair:Sendable {
    let connection:CodexNativeDisplayedConnection
    let tuiInventorySocket:String,serverInventorySocket:String
    let tuiControlSocket:String,serverControlSocket:String
    private init(_ connection:CodexNativeDisplayedConnection,_ tui:CodexNativeRuntimeHint,_ server:CodexNativeRuntimeHint) {
        self.connection=connection;tuiInventorySocket=tui.inventorySocket;serverInventorySocket=server.inventorySocket
        tuiControlSocket=tui.controlSocket;serverControlSocket=server.controlSocket
    }
    static func resolve(root:String=CodexNativeRuntimeRoot.path,home:String,tuiPID:Int32,serverPID:Int32)async throws->Self {
        let hints=try await Task.detached(priority:.utility){
            (try CodexNativeRuntimeRegistry.candidates(root:root,pid:tuiPID,role:.tui,home:home),
             try CodexNativeRuntimeRegistry.candidates(root:root,pid:serverPID,role:.server,home:home))
        }.value
        async let tui=CodexNativeRuntimeRegistry.live(hints.0,role:.tui)
        async let server=CodexNativeRuntimeRegistry.live(hints.1,role:.server)
        let (client,host)=try await (tui,server)
        let connection=try await CodexNativeDisplayedConnection.observe(tuiSocket:client.inventorySocket,serverSocket:host.inventorySocket)
        guard connection.tuiPeer==client.claimedPeer,connection.serverPeer==host.claimedPeer else {
            throw AppError.message("제어 등록을 확인하는 중 Codex 프로세스가 바뀌었습니다.")
        }
        return Self(connection,client,host)
    }
}
