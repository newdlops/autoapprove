import Foundation
import Darwin
import CLocalDashboard

/// No shell, inherited credentials, global process search, or token logging.
public final class OwnedToolProcess:@unchecked Sendable {
    public struct Result:Sendable {public let status:Int32,output:Data,error:Data}
    private let lock=NSLock()
    private var pid:Int32=0,cancelled=false
    private let output=Pipe(),error=Pipe()
    func cancel() {stop()}
    public static func run(_ executable:String,arguments:[String],environment:[String:String],directory:URL,
                           timeout:TimeInterval=120,onOutput:@escaping @Sendable(Data)->Void = {_ in}) async throws -> Result {
        let owned=OwnedToolProcess()
        return try await owned.result(executable,arguments:arguments,environment:environment,directory:directory,timeout:timeout,onOutput:onOutput)
    }
    func result(_ executable:String,arguments:[String],environment:[String:String],directory:URL,timeout:TimeInterval,onOutput:@escaping @Sendable(Data)->Void = {_ in}) async throws -> Result {
        return try await withTaskCancellationHandler(operation:{
            try await self.execute(executable,arguments:arguments,environment:environment,directory:directory,timeout:timeout,onOutput:onOutput)
        },onCancel:{self.stop()})
    }
    private func start(_ executable:String,arguments:[String],environment:[String:String],directory:URL) throws {
        lock.lock();defer {lock.unlock()}
        guard !cancelled else {throw CancellationError()}
        guard executable.hasPrefix("/"),directory.isFileURL else {
            throw AppError.message("연결 도구의 실행 정보를 확인하지 못했습니다.")
        }
        let values=[executable]+arguments,entries=environment.sorted {$0.key<$1.key}.map {$0.key+"="+$0.value}
        guard !(values+entries+[directory.path]).contains(where:{$0.contains("\0")}) else {throw AppError.message("연결 도구의 실행 정보를 확인하지 못했습니다.")}
        let args=values.map {strdup($0)}+[nil],env=entries.map {strdup($0)}+[nil]
        defer {for value in args+env {if let value {free(value)}}}
        guard args.dropLast().allSatisfy({$0 != nil}),env.dropLast().allSatisfy({$0 != nil}) else {throw AppError.message("연결 도구를 준비할 메모리가 부족합니다.")}
        var child:Int32=0
        let result=args.withUnsafeBufferPointer {args in env.withUnsafeBufferPointer {env in
            aa_spawn_owned_tool(executable,args.baseAddress,env.baseAddress,directory.path,output.fileHandleForWriting.fileDescriptor,error.fileHandleForWriting.fileDescriptor,&child)
        }}
        guard result == 0,child>0 else {throw AppError.message("Cloudflare 연결 도구를 실행하지 못했습니다.")}
        pid=child
    }
    private func stop() {
        lock.lock();defer {lock.unlock()};cancelled=true
        if pid>0 {aa_stop_owned_tool(pid);pid=0}
    }
    private func poll() throws -> Int32? {
        lock.lock();defer {lock.unlock()}
        guard !cancelled,pid>0 else {throw CancellationError()}
        var status:Int32=0
        let result=aa_poll_owned_tool(pid,&status)
        if result == 0 {return nil}
        pid=0
        guard result == 1 else {throw AppError.message("Cloudflare 연결 도구의 종료를 확인하지 못했습니다.")}
        return status
    }
    private func execute(_ executable:String,arguments:[String],environment:[String:String],directory:URL,timeout:TimeInterval,onOutput:@escaping @Sendable(Data)->Void) async throws -> Result {
        defer {stop();try? output.fileHandleForReading.close();try? output.fileHandleForWriting.close();try? error.fileHandleForReading.close();try? error.fileHandleForWriting.close()}
        try Task.checkCancellation()
        for handle in [output.fileHandleForReading,error.fileHandleForReading] {
            let fd=handle.fileDescriptor,flags=fcntl(handle.fileDescriptor,F_GETFL)
            guard flags>=0,fcntl(fd,F_SETFL,flags|O_NONBLOCK)==0 else {throw AppError.message("연결 도구의 출력 채널을 준비하지 못했습니다.")}
        }
        try start(executable,arguments:arguments,environment:environment,directory:directory)
        try output.fileHandleForWriting.close();try error.fileHandleForWriting.close()
        var stdout=Data(),stderr=Data()
        let deadline=ProcessInfo.processInfo.systemUptime+timeout
        func drain(_ handle:FileHandle,_ data:inout Data) throws {
            var bytes=[UInt8](repeating:0,count:4096)
            while true {
                let count=bytes.withUnsafeMutableBytes {Darwin.read(handle.fileDescriptor,$0.baseAddress,4096)}
                if count<0 {if errno==EINTR {continue};if errno==EAGAIN||errno==EWOULDBLOCK {return};throw AppError.message("연결 도구의 응답을 읽지 못했습니다.")}
                if count==0 {return}
                guard data.count+count<=524288 else {throw AppError.message("연결 도구의 응답이 너무 큽니다.")}
                let chunk=Data(bytes.prefix(count));data.append(chunk);onOutput(chunk)
            }
        }
        while true {
            try Task.checkCancellation();try drain(output.fileHandleForReading,&stdout);try drain(error.fileHandleForReading,&stderr)
            if let status=try poll(){try drain(output.fileHandleForReading,&stdout);try drain(error.fileHandleForReading,&stderr);return Result(status:status,output:stdout,error:stderr)}
            guard ProcessInfo.processInfo.systemUptime<deadline else {throw AppError.message("Cloudflare 작업 시간이 초과됐습니다. 다시 시도해주세요.")}
            try await Task.sleep(for:.milliseconds(20))
        }
    }
}
