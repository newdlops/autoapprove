#if DEBUG
import Foundation
import Darwin
@testable import AutoApproveCore

private final class NativeRegistryFixture {
    let root="/private/tmp/aa-rg-"+UUID().uuidString.prefix(8)
    let id=UUID().uuidString.lowercased()
    var home:String{root+"/home"}
    var directory:String{root+"/t-"+String(getpid())+"-"+id.replacingOccurrences(of:"-",with:"")}
    var record:[String:Any]=[:]
    var listeners:[Int32]=[]
    init()throws {
        var ready=false;defer{if !ready{cleanup()}}
        try CodexNativeRuntimeRoot.prepare(at:root)
        for path in [home,directory]{try FileManager.default.createDirectory(atPath:path,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])}
        var pair:[Int32]=[-1,-1]
        guard socketpair(AF_UNIX,SOCK_STREAM,0,&pair)==0 else{throw AppError.message("Owned socket pair failed")}
        defer{close(pair[0]);close(pair[1])}
        let peer=try CodexNativeKernelPeer.connectedSocket(pair[0]).identity
        record=["schemaVersion":1,"producer":"autoapprove-native-runtime-registration","cliVersion":"0.167.1",
                "registrationId":id,"role":"tui","controlKind":"terminal-input-hold","pid":getpid(),
                "processIdentity":try JSONSerialization.jsonObject(with:JSONEncoder().encode(peer)),
                "executable":"/Applications/Codex.app/Contents/MacOS/codex",
                "home":home,"inventorySocket":"i.sock","controlSocket":"c.sock","membershipComplete":false,"migrationAuthorized":false]
        for name in ["i.sock","c.sock"] {
            let fd=socket(AF_UNIX,SOCK_STREAM,0);guard fd>=0 else{throw AppError.message("Owned registry socket failed")}
            listeners.append(fd)
            var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX);address.sun_len=UInt8(MemoryLayout<sockaddr_un>.size)
            let bytes=Array((directory+"/"+name).utf8)+[0]
            withUnsafeMutableBytes(of:&address.sun_path){$0.copyBytes(from:bytes)}
            let bound=withUnsafePointer(to:&address){p in p.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
            guard bound==0,listen(fd,4)==0 else{throw AppError.message("Owned registry listener failed")}
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:directory+"/"+name)
        }
        try save();ready=true
    }
    deinit{cleanup()}
    private func cleanup(){for fd in listeners{close(fd)};listeners=[];try? FileManager.default.removeItem(atPath:root)}
    func save()throws {
        try JSONSerialization.data(withJSONObject:record).write(to:URL(fileURLWithPath:directory+"/registration.json"))
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:directory+"/registration.json")
    }
    func hints()throws->[CodexNativeRuntimeHint]{
        guard CodexNativeRuntimeRoot.existing(at:root)==root else{throw AppError.message("Owned fixture root is not private")}
        return try CodexNativeRuntimeRegistry.candidates(root:root,pid:getpid(),role:.tui,home:home)
    }
    func serveOnce()->Task<Void,Error> {
        let listener=listeners[0],pid=getpid()
        return Task.detached {
            var item=pollfd(fd:listener,events:Int16(POLLIN),revents:0)
            guard poll(&item,1,3000)>0 else{throw AppError.message("Owned registry accept timed out")}
            let fd=accept(listener,nil,nil);guard fd>=0 else{throw AppError.message("Owned registry accept failed")};defer{close(fd)}
            var timeout=timeval(tv_sec:2,tv_usec:0),one:Int32=1
            setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout.size(ofValue:timeout)))
            setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,socklen_t(MemoryLayout.size(ofValue:timeout)))
            setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,socklen_t(MemoryLayout.size(ofValue:one)))
            var input=Data()
            while input.count<1024 {
                var byte:UInt8=0;guard recv(fd,&byte,1,0)==1 else{throw AppError.message("Owned registry request incomplete")}
                if byte==10{break};input.append(byte)
            }
            let request=try JSONSerialization.jsonObject(with:input) as! [String:String]
            var reply=try JSONSerialization.data(withJSONObject:["schemaVersion":1,"producer":"autoapprove-native-tui-prototype","cliVersion":"0.167.1","pid":pid,"nonce":request["nonce"]!,"membershipComplete":false,"admissionGranted":false]);reply.append(10)
            try reply.withUnsafeBytes{buffer in
                var offset=0
                while offset<buffer.count{let count=send(fd,buffer.baseAddress!.advanced(by:offset),buffer.count-offset,0);guard count>0 else{throw AppError.message("Owned registry response failed")};offset+=count}
            }
        }
    }
}

extension ApprovalTests {
    func testNativeRuntimeRootPreservesForeignAndPublicPaths() throws {
        let root="/private/tmp/aa-rt-"+UUID().uuidString.prefix(8)
        let alias=root+"-alias"
        defer {try? FileManager.default.removeItem(atPath:alias);try? FileManager.default.removeItem(atPath:root)}
        try expectNil(CodexNativeRuntimeRoot.existing(at:root))
        try expect(!FileManager.default.fileExists(atPath:root))
        try expectEqual(try CodexNativeRuntimeRoot.prepare(at:root),root)
        var info=stat();try expect(lstat(root,&info)==0)
        try expectEqual(info.st_mode&0o777,mode_t(0o700))
        try FileManager.default.createSymbolicLink(atPath:alias,withDestinationPath:root)
        try expectNil(CodexNativeRuntimeRoot.existing(at:alias))
        try expectThrows(CodexNativeRuntimeRoot.prepare(at:alias))
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:root)
        try expectThrows(CodexNativeRuntimeRoot.prepare(at:root))
        try expect(lstat(root,&info)==0);try expectEqual(info.st_mode&0o777,mode_t(0o755))
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:root)
        try expectEqual(CodexNativeRuntimeRoot.existing(at:root),root)
    }
    func testNativeRuntimeLaunchUsesLiteralCodexOnlyEnvironment() throws {
        let root="/private/tmp/aa-rc-"+UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer {try? FileManager.default.removeItem(atPath:root)}
        let executable=URL(fileURLWithPath:root).appendingPathComponent("codex")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$AUTOAPPROVE_NATIVE_RUNTIME_ROOT\" \"$CODEX_HOME\"\n".utf8).write(to:executable)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:executable.path)
        let entry=TerminalProfileEntry(title:"Owned",agent:"codex",cwd:root,conversationID:"",providerHome:"/fixture/account home")
        let native="/private/tmp/aa native'root"
        let result=try CommandRunner.run("/bin/zsh",["-c",try entry.resumeCommand(nativeRuntimeRoot:native)],environment:["PATH":root+":/usr/bin:/bin"],inheritEnvironment:false)
        try expectEqual(result.status,0);try expectEqual(result.output,native+"\n/fixture/account home\n")
        let ordinary=try CommandRunner.run("/bin/zsh",["-c",try entry.resumeCommand()],environment:["PATH":root+":/usr/bin:/bin"],inheritEnvironment:false)
        try expectEqual(ordinary.output,"\n/fixture/account home\n")
        var claude=entry;claude.agent="claude"
        try expectThrows(claude.resumeCommand(nativeRuntimeRoot:native))
    }
    func testNativeRuntimeRegistryRejectsMalformedOrForeignDiscoveryHints()throws {
        let f=try NativeRegistryFixture(),original=f.record
        try expectEqual(try f.hints().count,1)
        let aliasHome=try CodexAccountTransitionTarget.canonicalHome(f.home)
        try expectEqual(try CodexNativeRuntimeRegistry.candidates(root:f.root,pid:getpid(),role:.tui,home:aliasHome).count,1)
        for (field,value) in [("schemaVersion",2),("cliVersion","0.168.0"),("role","server"),
                             ("controlKind","selected-input-lease"),("home","/other/home"),
                             ("inventorySocket","../i.sock"),("controlSocket","other.sock"),
                             ("membershipComplete",true),("migrationAuthorized",true),("membershipComplete",1)] as [(String,Any)] {
            f.record=original;f.record[field]=value;try f.save();try expectEqual(try f.hints().count,0)
        }
        f.record=original;try f.save()
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:f.directory)
        try expectEqual(try f.hints().count,0)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:f.directory)
        let record=f.directory+"/registration.json",backup=f.home+"/record"
        try FileManager.default.moveItem(atPath:record,toPath:backup)
        try FileManager.default.createSymbolicLink(atPath:record,withDestinationPath:backup)
        try expectEqual(try f.hints().count,0);try expect(FileManager.default.fileExists(atPath:backup))
    }
    func testNativeRuntimeRegistryFileCannotForgeKernelProcessInstance()async throws {
        let f=try NativeRegistryFixture()
        var identity=f.record["processIdentity"] as! [String:Any]
        let actual=(identity["auditPidVersion"] as! NSNumber).uint32Value
        identity["auditPidVersion"]=actual==UInt32.max ? 1:actual+1
        f.record["processIdentity"]=identity;try f.save()
        let hints=try f.hints();try expectEqual(hints.count,1)
        let worker=f.serveOnce()
        do{_=try await CodexNativeRuntimeRegistry.live(hints,role:.tui);throw AppError.message("Forged discovery unexpectedly accepted")}
        catch{try expect(!error.localizedDescription.contains("unexpectedly accepted"))}
        try await worker.value
    }
}
#endif
