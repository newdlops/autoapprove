import Foundation
import AutoApproveCore

private func maskedInputFrame(_ payload:Data,code:UInt8 = 2,final:Bool = true) -> Data {
    let mask:[UInt8] = [0x37,0xfa,0x21,0x3d]
    var data = Data([(final ? 0x80:0)|code])
    if payload.count < 126 {data.append(0x80|UInt8(payload.count))}
    else {data.append(contentsOf:[0xfe,UInt8(truncatingIfNeeded:payload.count >> 8),UInt8(truncatingIfNeeded:payload.count)])}
    data.append(contentsOf:mask)
    for (index,byte) in payload.enumerated() {data.append(byte ^ mask[index & 3])}
    return data
}

extension ApprovalTests {
    func testInputSocketRFCHandshakeFragmentationAndBounds() throws {
        let header = "GET /api/input/socket HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: http://127.0.0.1\r\nConnection: keep-alive, Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: autoapprove-input.v1\r\n\r\n"
        let request = try RemoteHTTPRequest.parse(Data(header.utf8))!
        let handshake = String(decoding:try RemoteWebSocketParser.handshake(request),as:UTF8.self)
        try expect(handshake.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))
        try expect(handshake.hasPrefix("HTTP/1.1 101"));try expectFalse(handshake.contains("Sec-WebSocket-Extensions"))
        for changed in [header.replacingOccurrences(of:"Origin: http://127.0.0.1\r\n",with:""),header.replacingOccurrences(of:"Version: 13",with:"Version: 12"),header.replacingOccurrences(of:"autoapprove-input.v1",with:"other"),header.replacingOccurrences(of:"dGhlIHNhbXBsZSBub25jZQ==",with:"short")] {
            try expectThrows(try RemoteWebSocketParser.handshake(RemoteHTTPRequest.parse(Data(changed.utf8))!))
        }
        let raw = Data("한글😀\u{1b}[D".utf8)
        let joined = maskedInputFrame(Data(raw.prefix(5)),final:false)+maskedInputFrame(Data([1,2,3]),code:9)+maskedInputFrame(Data(raw.dropFirst(5)),code:0)
        var parser = RemoteWebSocketParser(),events:[RemoteWebSocketParser.Event] = []
        for byte in joined {events += try parser.append(Data([byte]))}
        try expectEqual(events,[.ping(Data([1,2,3])),.message(raw)])
        try expectEqual(try parser.append(maskedInputFrame(raw)+maskedInputFrame(raw)),[.message(raw),.message(raw)])
        for bad in [Data([0x82,0]),Data([0xc2,0x80,0,0,0,0]),maskedInputFrame(Data(),code:0),maskedInputFrame(Data(),code:9,final:false),Data([0x82,0xfe,0,1,0,0,0,0,0]),Data([0x82,0xff]),maskedInputFrame(Data([3,237]),code:8),maskedInputFrame(Data(repeating:0,count:RemoteWebSocketParser.maximumMessage+1))] {
            var invalid = RemoteWebSocketParser();try expectThrows(try invalid.append(bad))
        }
        let packet = try RemoteInputPacket(kind:.pty,sequence:0x01020304,payload:raw).encoded()
        try expectEqual(Data(packet.prefix(8)),Data([65,73,1,2,1,2,3,4]))
        try expectEqual(try RemoteInputPacket.decode(packet).payload,raw)
        for bad in [Data(),Data([65,73,2,2,0,0,0,1]),Data([65,73,1,99,0,0,0,1]),Data(repeating:0,count:16010)] {try expectThrows(try RemoteInputPacket.decode(bad))}
    }

    func testInputSocketRealGatewayAuthOrderingAndRevocation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-input-socket-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let engine = try ApprovalEngine(paths:AppPaths(directory:root),processReader:{[]},webLoopbackOnly:true)
        defer {engine.stop()}
        let descriptor = try engine.managedPTY.create(cwd:root.path,program:"shell",command:["/bin/cat"],columns:80,rows:24)
        var status = RemoteNetworkStatus()
        let web = RemoteNetworkService(engine:engine,nodeID:UUID().uuidString,name:"Socket QA",bonjourEnabled:false,loopbackOnly:true,discoveryAddresses:{[]},onStatus:{status = $0})
        defer {web.stop()};try web.start(port:0)
        for _ in 0..<200 where !status.ready {try await Task.sleep(for:.milliseconds(10))}
        try expect(status.ready)
        let gateway = try RemoteTunnelGateway(handler:{await web.handle($0)})
        defer {gateway.stop()};try await gateway.start(port:0);try gateway.setOrigin("https://input.example.com")
        let port = gateway.port!,config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil;config.httpShouldSetCookies = false;config.timeoutIntervalForRequest = 3;config.timeoutIntervalForResource = 5
        let session = URLSession(configuration:config);defer {session.invalidateAndCancel()}
        func socket(cookie:String? = nil,origin:String = "https://input.example.com") -> URLSessionWebSocketTask {
            var request = URLRequest(url:URL(string:"ws://127.0.0.1:\(port)/api/input/socket")!)
            request.setValue(origin,forHTTPHeaderField:"Origin");request.setValue("autoapprove-input.v1",forHTTPHeaderField:"Sec-WebSocket-Protocol")
            if let cookie {request.setValue(cookie,forHTTPHeaderField:"Cookie")}
            let socket = session.webSocketTask(with:request);socket.maximumMessageSize = 16009;socket.resume();return socket
        }
        let anonymous = socket();do {_ = try await anonymous.receive();throw AppError.message("Anonymous socket accepted") } catch let error as AppError {throw error} catch {}
        anonymous.cancel(with:.goingAway,reason:nil)
        var login = URLRequest(url:URL(string:"http://127.0.0.1:\(port)/auth/login")!);login.httpMethod = "POST"
        login.setValue("https://input.example.com",forHTTPHeaderField:"Origin");login.setValue("application/json",forHTTPHeaderField:"Content-Type")
        login.httpBody = try JSONSerialization.data(withJSONObject:["key":gateway.accessKey])
        let (_,response) = try await session.data(for:login)
        let http = response as! HTTPURLResponse;try expectEqual(http.statusCode,200)
        let cookie = String(http.value(forHTTPHeaderField:"Set-Cookie")!.split(separator:";")[0])
        let foreign = socket(cookie:cookie,origin:"https://foreign.example.com")
        do {_ = try await foreign.receive();throw AppError.message("Cross-origin socket accepted") } catch let error as AppError {throw error} catch {}
        foreign.cancel(with:.goingAway,reason:nil)
        let active = socket(cookie:cookie);defer {active.cancel(with:.goingAway,reason:nil)}
        func receive(_ task:URLSessionWebSocketTask) async throws -> RemoteInputPacket {
            guard case .data(let data) = try await task.receive() else {throw AppError.message("Binary response expected")};return try RemoteInputPacket.decode(data)
        }
        try expectEqual(try await receive(active).payload,Data([1]))
        let client = UUID().uuidString
        let binding:JSONObject = ["mode":"pty","ptyID":descriptor.ptyID,"streamID":descriptor.streamID,"clientID":client,"sequenceBase":0]
        try await active.send(.data(RemoteInputPacket(kind:.bind,payload:JSONSerialization.data(withJSONObject:binding)).encoded()))
        try expectEqual(try await receive(active).kind,.ready)
        for sequence in UInt32(1)...12 {try await active.send(.data(RemoteInputPacket(kind:.pty,sequence:sequence,payload:Data("ORDER-\(sequence) ".utf8)).encoded()))}
        for sequence in UInt32(1)...12 {let reply = try await receive(active);try expectEqual(reply.kind,.ack);try expectEqual(reply.sequence,sequence)}
        try await active.send(.data(RemoteInputPacket(kind:.pty,sequence:12,payload:Data("REPLAY-MUST-NOT-WRITE".utf8)).encoded()))
        try expectEqual(try await receive(active).kind,.failure)
        try expectFalse(try engine.managedPTY.terminal(descriptor.ptyID).screen().contains("REPLAY-MUST-NOT-WRITE"))
        let revoked = socket(cookie:cookie);try expectEqual(try await receive(revoked).payload,Data([1]))
        gateway.setPIN(nil,accessKey:String(repeating:"r",count:43))
        do {_ = try await revoked.receive();throw AppError.message("Revoked socket survived") } catch let error as AppError {throw error} catch {}
        revoked.cancel(with:.goingAway,reason:nil)
    }

    func testTunnelQualityBoundsMetricsAndPrivacy() throws {
        let tracker = RemoteTunnelQualityTracker()
        for number in 0..<100 {tracker.recordProbe(milliseconds:Double(number),ray:"private-ray-prefix-NRT")}
        tracker.recordProbe(milliseconds:.nan,ray:nil);tracker.recordProbe(milliseconds:.infinity,ray:nil)
        tracker.reconnected()
        tracker.registration("Registered tunnel connection account=private-account location=icn01 protocol=quic")
        tracker.metrics("quic_client_smoothed_rtt{conn_index=\"0\"} 12\nquic_client_smoothed_rtt{conn_index=\"1\"} 20\ncloudflared_tunnel_ha_connections 4\nquic_client_lost_packets{conn_index=\"0\"} 2\nquic_client_lost_packets{conn_index=\"1\"} 3\nquic_client_smoothed_rtt{conn_index=\"2\"} NaN\ncloudflared_tunnel_server_locations{connection_id=\"0\",edge_location=\"lax03\"} 1\ncloudflared_tunnel_server_locations{connection_id=\"0\",edge_location=\"icn01\"} 0\n")
        let value = tracker.snapshot()
        try expectEqual(value.samples,64);try expectEqual(value.medianMS,67);try expectEqual(value.p95MS,96)
        try expectEqual(value.edge,"NRT");try expectEqual(value.failedProbes,2);try expectEqual(value.succeeded,false)
        try expectEqual(value.connectorLocations,["LAX"]);try expectEqual(value.connectorProtocol,"QUIC")
        try expectEqual(value.connectorMS,12);try expectEqual(value.connections,4);try expectEqual(value.lostPackets,5);try expectEqual(value.reconnects,1)
        let encoded = String(decoding:try JSONEncoder().encode(value),as:UTF8.self)
        try expectFalse(encoded.contains("private-ray"));try expectFalse(encoded.contains("private-account"));try expectFalse(encoded.contains("conn_index"))
        tracker.reconnected();try expectNil(tracker.snapshot().connectorMS);try expectNil(tracker.snapshot().connections);try expectEqual(tracker.snapshot().connectorLocations,[])
        tracker.registration("Registered tunnel connection location=icn01 protocol=http2")
        tracker.metrics("quic_client_smoothed_rtt{conn_index=\"0\"} 99\nquic_client_lost_packets{conn_index=\"0\"} 42\n")
        try expectNil(tracker.snapshot().connectorMS);try expectNil(tracker.snapshot().lostPackets)
        tracker.connectorPing(milliseconds:23);try expectEqual(tracker.snapshot().connectorProtocol,"WSS 443")
    }
}
