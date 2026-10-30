import Foundation
import AppKit
import Darwin

/// Kernel identity of the built-in Terminal. AppKit's running-app registry is
/// not an authority for whether an existing process is alive.
public struct TerminalProcessIdentity:Equatable,Sendable {
    public let pid:Int32
    public let startedSeconds:UInt64
    public let startedMicroseconds:UInt64
    public init(pid:Int32,startedSeconds:UInt64,startedMicroseconds:UInt64) {
        self.pid=pid;self.startedSeconds=startedSeconds;self.startedMicroseconds=startedMicroseconds
    }
}

public enum TerminalProcessLookup {
    public static let bundleID="com.apple.Terminal"
    public static let executable="/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"
    public struct Source {
        public var candidates:() throws -> [Int32]
        public var identity:(Int32)->TerminalProcessIdentity?
        public init(candidates:@escaping () throws -> [Int32],identity:@escaping (Int32)->TerminalProcessIdentity?) {
            self.candidates=candidates;self.identity=identity
        }
        public static var live:Self {.init(candidates:{try TerminalProcessLookup.candidates()},identity:{TerminalProcessLookup.identity(pid:$0)})}
    }
    private static func candidates() throws -> [Int32] {
        let required=proc_listpids(UInt32(PROC_UID_ONLY),getuid(),nil,0)
        guard required>0,required<=4*1024*1024 else {throw lookupFailed()}
        // Processes can start between sizing and reading. Never accept a
        // potentially truncated table as proof that Terminal is absent.
        for capacity in [Int(required)/MemoryLayout<Int32>.size+128,1024*1024] {
            var pids=[Int32](repeating:0,count:capacity)
            let bytes=Int32(pids.count*MemoryLayout<Int32>.size)
            let count=proc_listpids(UInt32(PROC_UID_ONLY),getuid(),&pids,bytes)
            guard count>0,count<=bytes else {throw lookupFailed()}
            if count<bytes {return Array(pids.prefix(Int(count)/MemoryLayout<Int32>.size)).filter {$0>0}}
        }
        throw lookupFailed()
    }
    /// Reads no arguments, environment, terminal text or accessibility tree.
    public static func identity(pid:Int32)->TerminalProcessIdentity? {
        guard pid>0 else {return nil}
        func info()->proc_bsdinfo? {
            var value=proc_bsdinfo();let size=Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&value,size)==size,value.pbi_pid==UInt32(pid),
                  value.pbi_uid==getuid(),value.pbi_status != UInt32(SZOMB) else {return nil}
            return value
        }
        guard let before=info() else {return nil}
        var path=[UInt8](repeating:0,count:4*Int(MAXPATHLEN))
        guard proc_pidpath(pid,&path,UInt32(path.count))>0,
              let end=path.firstIndex(of:0),String(decoding:path[..<end],as:UTF8.self)==executable,
              let after=info(),before.pbi_start_tvsec==after.pbi_start_tvsec,before.pbi_start_tvusec==after.pbi_start_tvusec else {return nil}
        return .init(pid:pid,startedSeconds:after.pbi_start_tvsec,startedMicroseconds:after.pbi_start_tvusec)
    }
    public static func running(source:Source = .live) throws -> TerminalProcessIdentity {
        let identities=try Set(source.candidates()).sorted().compactMap {pid -> TerminalProcessIdentity? in
            guard pid>0,let value=source.identity(pid),value.pid==pid else {return nil};return value
        }
        guard !identities.isEmpty else {throw TerminalProfileAccessError.terminalNotRunning}
        guard identities.count==1 else {throw AppError.message("Terminal 프로세스가 여러 개라 탭 묶음을 구분하지 못했습니다. 사용할 Terminal만 남긴 뒤 다시 불러와주세요.")}
        return identities[0]
    }
    public static func ownerBundle(pid:Int32)->String? {
        if identity(pid:pid) != nil {return bundleID}
        let app=NSRunningApplication(processIdentifier:pid)
        guard app?.isTerminated==false,app?.bundleIdentifier != bundleID else {return nil}
        return app?.bundleIdentifier
    }
    private static func lookupFailed()->AppError {.message("실행 중인 Terminal 프로세스를 확인하지 못했습니다. 잠시 후 현재 창을 다시 불러와주세요.")}
}
