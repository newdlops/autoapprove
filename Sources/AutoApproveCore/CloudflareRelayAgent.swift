import Foundation

public struct CloudflareRelaySocket:@unchecked Sendable {
    public let session:URLSession
    public let task:URLSessionWebSocketTask
    public init(session:URLSession,task:URLSessionWebSocketTask) {self.session=session;self.task=task}
    public func cancel() {task.cancel(with:.goingAway,reason:nil);session.invalidateAndCancel()}
}
public struct CloudflareRelayServices:Sendable {
    public var connect:@Sendable(URLRequest)->CloudflareRelaySocket
    public var probe:@Sendable(URLRequest) async throws -> CloudflareHTTPReply
    public var diagnostic:@Sendable(String)->Void
    public init(connect:@escaping @Sendable(URLRequest)->CloudflareRelaySocket,probe:@escaping @Sendable(URLRequest) async throws -> CloudflareHTTPReply,diagnostic:@escaping @Sendable(String)->Void = {_ in}) {self.connect=connect;self.probe=probe;self.diagnostic=diagnostic}
    public static let live=CloudflareRelayServices(connect:{request in
        let config=URLSessionConfiguration.ephemeral;config.httpShouldSetCookies=false;config.urlCache=nil
        config.timeoutIntervalForRequest=20;config.timeoutIntervalForResource=86400
        let session=URLSession(configuration:config,delegate:TunnelRedirectPolicy(),delegateQueue:nil)
        return CloudflareRelaySocket(session:session,task:session.webSocketTask(with:request))
    },probe:{try await CloudflareServices.live.exchange($0)})
}

/// A single native WSS connection multiplexes HTTP/SSE. Each request is sent
/// once to the fixed local gateway; reconnect never resubmits a request.
actor CloudflareRelayAgent {
    private final class Call {
        let token=UUID(),bodyBytes:Int
        var task:Task<Void,Never>?,credit=0,waiter:CheckedContinuation<Void,Error>?
        var buffer=Data(),timer:Task<Void,Never>?,flush:Task<Void,Error>?,flushID=UUID()
        init(bodyBytes:Int) {self.bodyBytes=bodyBytes}
    }
    private let socket:CloudflareRelaySocket,localURL:URL,host:String,upstream:URLSession
    private let diagnostic:@Sendable(String)->Void
    private var calls:[UInt32:Call]=[:],bodyBytes=0
    init(socket:CloudflareRelaySocket,localURL:URL,host:String,diagnostic:@escaping @Sendable(String)->Void = {_ in}) {
        self.socket=socket;self.localURL=localURL;self.host=host
        self.diagnostic=diagnostic
        let config=URLSessionConfiguration.ephemeral;config.httpShouldSetCookies=false;config.httpCookieStorage=nil;config.urlCache=nil
        config.httpMaximumConnectionsPerHost=32;config.timeoutIntervalForRequest=45;config.timeoutIntervalForResource=86400
        upstream=URLSession(configuration:config,delegate:TunnelRedirectPolicy(),delegateQueue:nil)
    }
    nonisolated func cancel() {socket.cancel();upstream.invalidateAndCancel()}
    private func send(_ kind:CloudflareRelayPacket.Kind,_ id:UInt32,_ payload:Data = Data()) async throws {
        try Task.checkCancellation();try await socket.task.send(.data(try CloudflareRelayPacket(kind:kind,id:id,payload:payload).encoded()))
    }
    private func cancelCall(_ id:UInt32) {
        guard let call=calls.removeValue(forKey:id) else {return}
        bodyBytes-=call.bodyBytes;call.task?.cancel();call.timer?.cancel();call.flush?.cancel();call.waiter?.resume(throwing:CancellationError());call.waiter=nil
    }
    func run(onConnected:@escaping @Sendable() async -> Void) async throws {
        socket.task.maximumMessageSize=CloudflareRelayPacket.maximumSize;socket.task.resume()
        defer {for id in Array(calls.keys) {cancelCall(id)};cancel()}
        guard case .data(let greeting)=try await socket.task.receive() else {throw invalid()}
        let hello=try CloudflareRelayPacket.decode(greeting)
        guard hello.kind == .hello,hello.payload == Data([1]) else {throw invalid()}
        await onConnected()
        while !Task.isCancelled {
            guard case .data(let data)=try await socket.task.receive() else {throw invalid()}
            let packet=try CloudflareRelayPacket.decode(data)
            switch packet.kind {
            case .request:
                guard calls[packet.id] == nil else {diagnostic("duplicate_request");throw invalid()}
                let request=try packet.request()
                guard calls.count<32,bodyBytes+request.body.count<=8_000_000 else {
                    try await send(.headers,packet.id,JSONSerialization.data(withJSONObject:["status":503,"headers":["Cache-Control":"no-store"]]));try await send(.end,packet.id);continue
                }
                let call=Call(bodyBytes:request.body.count);calls[packet.id]=call;bodyBytes+=call.bodyBytes
                call.task=Task {await self.forward(request,id:packet.id,call:call)}
            case .cancel:guard packet.payload.isEmpty else {throw invalid()};cancelCall(packet.id)
            case .credit:
                let amount=try packet.credit()
                if let call=calls[packet.id] {
                    guard call.credit+amount<=262144 else {diagnostic("credit_overflow");throw invalid()}
                    call.credit+=amount;call.waiter?.resume();call.waiter=nil
                }
            default:throw invalid()
            }
        }
        throw CancellationError()
    }
    private func consume(_ amount:Int,id:UInt32,call:Call) async throws {
        while true {
            try Task.checkCancellation();guard calls[id] === call else {throw CancellationError()}
            if call.credit>=amount {call.credit-=amount;return}
            try await withCheckedThrowingContinuation {continuation in call.waiter=continuation}
        }
    }
    private func flush(_ call:Call,id:UInt32) async throws {
        try Task.checkCancellation()
        while let previous=call.flush {
            let token=call.flushID
            try await previous.value
            if call.flushID==token {call.flush=nil}
        }
        try Task.checkCancellation();guard calls[id] === call else {throw CancellationError()}
        guard !call.buffer.isEmpty else {return}
        let data=call.buffer;call.buffer.removeAll(keepingCapacity:true)
        let token=UUID();call.flushID=token
        let task=Task {try await self.consume(data.count,id:id,call:call);try await self.send(.data,id,data)}
        call.flush=task
        try await task.value
        if call.flushID==token {call.flush=nil}
    }
    private func scheduleFlush(_ call:Call,id:UInt32) {
        guard call.timer==nil else {return}
        call.timer=Task {
            defer{call.timer=nil}
            do {
                // Binary terminal frames need no newline. A one-shot timer
                // coalesces a short burst, with no timer on an idle stream.
                while !call.buffer.isEmpty {
                    try await Task.sleep(for:.milliseconds(4));try await self.flush(call,id:id)
                }
            } catch {if !Task.isCancelled,calls[id] === call {cancelCall(id);try? await send(.cancel,id)}}
        }
    }
    private func forward(_ request:CloudflareRelayPacket.Request,id:UInt32,call:Call) async {
        defer {if calls[id] === call {call.timer?.cancel();call.flush?.cancel();call.waiter?.resume(throwing:CancellationError());call.waiter=nil;bodyBytes-=call.bodyBytes;calls.removeValue(forKey:id)}}
        do {
            guard let url=URL(string:localURL.absoluteString+request.path),url.scheme=="http",url.host=="127.0.0.1",url.port==localURL.port,url.user==nil,url.password==nil else {throw invalid()}
            var input=URLRequest(url:url);input.httpMethod=request.method;input.httpShouldHandleCookies=false;input.cachePolicy = .reloadIgnoringLocalCacheData
            let hop=Set(["connection","upgrade","keep-alive","transfer-encoding","te","trailer","content-length","proxy-authorization","proxy-authenticate","host","accept-encoding"])
            for (name,value) in request.headers where !hop.contains(name.lowercased()) {input.setValue(value,forHTTPHeaderField:name)}
            input.setValue(host,forHTTPHeaderField:"Host");input.setValue("identity",forHTTPHeaderField:"Accept-Encoding")
            if !request.body.isEmpty {input.httpBody=request.body}
            let (bytes,response)=try await upstream.bytes(for:input)
            guard let response=response as? HTTPURLResponse else {throw invalid()}
            var headers:[String:String]=[:]
            for (key,value) in response.allHeaderFields {
                let name=String(describing:key)
                if !hop.contains(name.lowercased()),name.lowercased() != "content-encoding" {headers[name]=String(describing:value)}
            }
            let metadata=try JSONSerialization.data(withJSONObject:["status":response.statusCode,"headers":headers])
            guard metadata.count<=32768 else {throw invalid()}
            try await send(.headers,id,metadata)
            call.buffer.reserveCapacity(32768)
            for try await byte in bytes {
                call.buffer.append(byte);scheduleFlush(call,id:id)
                if call.buffer.count>=32768 {try await flush(call,id:id)}
            }
            call.timer?.cancel();try await flush(call,id:id)
            try await send(.end,id)
        } catch {if !Task.isCancelled,calls[id] === call {diagnostic("upstream_error_"+String((error as? URLError)?.code.rawValue ?? 0));try? await send(.cancel,id)}}
    }
    private func invalid()->AppError {.message("HTTPS 중계 응답을 확인하지 못했습니다. 다시 연결해주세요.")}
}
