import Foundation

/// Security's synchronous IPC must never occupy the UI/network actor. Share
/// concurrent reads without caching credentials between requests. A stuck IPC
/// owns at most one worker, even after its HTTP callers time out or cancel.
@MainActor final class RemoteAccountPINReader {
    private struct Flight { let id:UUID, epoch:UUID }
    private struct Waiter {
        let continuation:CheckedContinuation<RemoteTunnelPIN?,Error>
        let timeout:Task<Void,Never>
    }
    private var epoch=UUID(),flight:Flight?
    private var waiters:[UUID:Waiter]=[:]

    func read(directory:URL,services:CloudflareServices) async throws -> RemoteTunnelPIN? {
        try Task.checkCancellation()
        let current=epoch
        if let flight,flight.epoch != current {
            throw RemoteHTTPError(503,"Mac의 접속 PIN을 다시 확인하고 있습니다. 잠시 후 다시 시도해주세요.")
        }
        if flight==nil {
            let started=Flight(id:UUID(),epoch:current);flight=started
            let read=services.readSecret
            Task.detached(priority:.userInitiated) { [weak self] in
                let result:Result<RemoteTunnelPIN?,Error>
                do {
                    let data=try read(directory,"remote-tunnel-pin")
                    result = .success(try data.flatMap {$0.isEmpty ? nil : try RemoteTunnelPIN.decode($0)})
                } catch {
                    result = .failure(RemoteHTTPError(503,"키체인에서 접속 PIN을 읽지 못했습니다. 키체인을 잠금 해제하거나 PIN을 다시 설정해주세요."))
                }
                await self?.complete(started,result:result)
            }
        }
        let id=UUID()
        let value=try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<RemoteTunnelPIN?,Error>) in
                guard !Task.isCancelled else {continuation.resume(throwing:CancellationError());return}
                let timeout=Task { [weak self] in
                    do {try await Task.sleep(for:.seconds(2))} catch {return}
                    self?.release(id,result:.failure(RemoteHTTPError(503,"Mac의 접속 PIN 확인이 지연되고 있습니다. 잠시 후 다시 시도해주세요.")))
                }
                waiters[id]=Waiter(continuation:continuation,timeout:timeout)
            }
        },onCancel:{ [weak self] in Task { @MainActor in self?.release(id,result:.failure(CancellationError())) } })
        try Task.checkCancellation()
        guard current==epoch else {throw RemoteHTTPError(409,"Mac의 로그인 설정이 변경됐습니다. 다시 확인해주세요.")}
        return value
    }
    private func release(_ id:UUID,result:Result<RemoteTunnelPIN?,Error>) {
        guard let waiter=waiters.removeValue(forKey:id) else {return}
        waiter.timeout.cancel();waiter.continuation.resume(with:result)
    }
    private func complete(_ completed:Flight,result:Result<RemoteTunnelPIN?,Error>) {
        guard flight?.id==completed.id else {return}
        flight=nil
        guard completed.epoch==epoch else {return}
        for id in Array(waiters.keys) {release(id,result:result)}
    }
    func invalidate() {
        epoch=UUID()
        for id in Array(waiters.keys) {release(id,result:.failure(RemoteHTTPError(409,"Mac의 로그인 설정이 변경됐습니다. 다시 확인해주세요.")))}
        // An uncancellable Security call keeps its reservation until completion.
    }
}
