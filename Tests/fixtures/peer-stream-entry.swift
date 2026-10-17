// The runner appends the real peer stream implementation from the source tree.
// Only the boundary search is instrumented; all sockets and gzip are real.
import Foundation
import Network
import CryptoKit
import Darwin
import AutoApproveCore

typealias RemoteHTTPStreamCompletion = @Sendable (Result<Data?, Error>) -> Void
protocol RemoteHTTPBodyStream: AnyObject, Sendable {
    var needsHeartbeat: Bool { get }
    func next(_ completion: @escaping RemoteHTTPStreamCompletion)
    func cancel()
}
extension RemoteLAN {
    static func localNetworkError(_ path: NWPath?) -> RemoteHTTPError? {
        guard let path else { return nil }
        return localNetworkError(status:path.status,reason:path.unsatisfiedReason)
    }
}

private final class BoundaryWork: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0, calls = 0
    func search(_ data: Data, range: Range<Data.Index>) -> Range<Data.Index>? {
        lock.lock(); bytes += range.count; calls += 1; lock.unlock()
        return data.range(of:Data([10,10]),in:range)
    }
    func snapshot() -> [String:Int] {
        lock.lock(); defer { lock.unlock() }; return ["bytes":bytes,"calls":calls]
    }
}
private let boundaryWork = BoundaryWork()
private func probeBoundary(_ data: Data, range: Range<Data.Index>) -> Range<Data.Index>? {
    boundaryWork.search(data,range:range)
}

@main struct PeerStreamEntryProbe {
    static func main() async throws {
        let endpoint = try RemoteNetworkAddress.endpoint(CommandLine.arguments[1])
        let stream = try RemotePTYPeerBodyStream(endpoint:endpoint,path:"/api/terminal/stream?case="+CommandLine.arguments[3],
            expectedNodeID:CommandLine.arguments[2],timeout:3)
        defer { stream.cancel() }
        var events = [Data](), initialBytes = 0, status: Int?, message: String?
        let began = ProcessInfo.processInfo.systemUptime
        var usageBefore = rusage(); getrusage(RUSAGE_SELF,&usageBefore)
        var openMS: Double?
        do {
            // PROBE_OPEN
            openMS = (ProcessInfo.processInfo.systemUptime-began)*1000
            initialBytes = initial.count
            if !initial.isEmpty { events.append(initial) }
            while let data = try await withCheckedThrowingContinuation({ continuation in
                stream.next { continuation.resume(with:$0) }
            }) { events.append(data) }
        } catch {
            status = (error as? RemoteHTTPError)?.status ?? -1
            message = error is CancellationError ? "cancelled" : "stream error"
        }
        var usageAfter = rusage(); getrusage(RUSAGE_SELF,&usageAfter)
        func cpu(_ usage: rusage) -> Double {
            Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)+Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1_000_000
        }
        var result: [String:Any] = ["initialBytes":initialBytes,"events":events.map { data in
            ["bytes":data.count,"sha256":SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()] as [String:Any]
        },"search":boundaryWork.snapshot(),"cpuMS":(cpu(usageAfter)-cpu(usageBefore))*1000]
        result["openMS"] = openMS; result["errorStatus"] = status; result["error"] = message
        print(String(decoding:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),as:UTF8.self))
    }
}
