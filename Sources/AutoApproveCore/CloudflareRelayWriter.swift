import Foundation

/// One WSS writer. Interactive replies and credit pass queued bulk output;
/// every caller awaits its own send, preserving per-request frame order.
actor CloudflareRelayWriter {
    private struct Job {let data:Data;let continuation:CheckedContinuation<Void,Error>}
    private let socket:CloudflareRelaySocket
    private var control:[Job] = [],bulk:[Job] = [],bytes = 0,draining = false,stopped = false
    init(socket:CloudflareRelaySocket) {self.socket = socket}
    func send(_ data:Data,interactive:Bool) async throws {
        try Task.checkCancellation()
        guard !stopped,bytes+data.count <= 8_000_000 else {throw URLError(.networkConnectionLost)}
        try await withCheckedThrowingContinuation { continuation in
            let job = Job(data:data,continuation:continuation);bytes += data.count
            if interactive {control.append(job)} else {bulk.append(job)}
            if !draining {draining = true;Task {await self.drain()}}
        }
    }
    private func drain() async {
        while !stopped && (!control.isEmpty || !bulk.isEmpty) {
            let job = !control.isEmpty ? control.removeFirst():bulk.removeFirst();bytes -= job.data.count
            do {try await socket.task.send(.data(job.data));job.continuation.resume()}
            catch {job.continuation.resume(throwing:error);cancel();break}
        }
        draining = false
    }
    func cancel() {
        guard !stopped else {return};stopped = true
        let queued = control+bulk;control.removeAll();bulk.removeAll();bytes = 0
        for job in queued {job.continuation.resume(throwing:CancellationError())}
    }
}
