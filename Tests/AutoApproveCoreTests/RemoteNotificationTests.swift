import Foundation
import AutoApproveCore

private final class NotificationScreen: @unchecked Sendable {
    private let lock=NSLock()
    private var value=TerminalScreen(tty:"/dev/ttys099",contents:"initial e\u{301}\n• Working (esc to interrupt)")
    func replace(_ raw: String, cursor: TerminalCursor? = nil, appearance: TerminalAppearance? = nil) {
        lock.lock();defer{lock.unlock()}
        value=TerminalScreen(tty:value.tty,contents:raw,appearance:appearance,cursor:cursor)
    }
    func read() -> TerminalScreen { lock.lock();defer{lock.unlock()};return value }
}

@MainActor private final class NotificationStreamProbe {
    private let session=URLSession(configuration:.ephemeral)
    private var task: Task<Void,Never>?
    private var frames:[JSONObject]=[]
    private var failure:Error?
    init(_ url: URL) {
        task=Task { @MainActor [weak self] in
            guard let self else{return}
            do {
                var request=URLRequest(url:url);request.timeoutInterval=8
                let (bytes,response)=try await self.session.bytes(for:request)
                guard (response as? HTTPURLResponse)?.statusCode==200 else { throw AppError.message("Synthetic SSE did not open") }
                defer{bytes.task.cancel()}
                for try await line in bytes.lines where line.hasPrefix("data: ") {
                    if let frame=try JSONSerialization.jsonObject(with:Data(line.dropFirst(6).utf8)) as? JSONObject { self.frames.append(frame) }
                }
            } catch { if !Task.isCancelled { self.failure=error } }
        }
    }
    func wait(seconds: Double, matching: (JSONObject)->Bool) async throws -> JSONObject {
        let deadline=Date().addingTimeInterval(seconds)
        while Date()<deadline {
            if let frame=frames.first(where:matching){return frame}
            if let failure{throw failure}
            try await Task.sleep(for:.milliseconds(10))
        }
        throw AppError.message("Synthetic SSE missed its source-change notification")
    }
    func close(){task?.cancel();task=nil;session.invalidateAndCancel()}
}

extension ApprovalTests {
    @MainActor func testTerminalNotificationsKeepFirstFrameLiveChangesAndReopen() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("aa-notifications-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let records=ProcessDiscovery.parse("990001 1 ttys099 990001 990001 Mon Sep 21 09:00:00 2026 /fixture/codex")
        var original=ProcessDiscovery.sessions(records,environment:{_ in [:]})[0];original.terminal = .iterm
        let screen=NotificationScreen()
        let adapter=ScreenHostAdapter(screens:{_ in TerminalSnapshot(screens:[screen.read()])},
            approve:{_,_,_ in fatalError("The notification test must not send input")},reveal:{_ in nil})
        let engine=try ApprovalEngine(paths:AppPaths(directory:directory),claudeRegistryReader:{_ in []},processReader:{records},
            screenAdapters:[.iterm:adapter],terminalInputAvailable:{false},terminalInputIdentity:{_ in nil})
        defer{engine.stop()}
        engine.updateDiscovery([original],records:records);await engine.connectScreenHost(.iterm)
        let beforeOpen="latest before opening 한글 e\u{301}\n• Working (esc to interrupt)"
        screen.replace(beforeOpen);await engine.refreshScreenHost(.iterm)
        var status=RemoteNetworkStatus()
        let service=RemoteNetworkService(engine:engine,nodeID:UUID().uuidString,bonjourEnabled:false,loopbackOnly:true,discoveryAddresses:{[]},onStatus:{status=$0})
        defer{service.stop()}
        func start() async throws -> URL {
            try service.start(port:0)
            for _ in 0..<200 where !status.ready {try await Task.sleep(for:.milliseconds(10))}
            guard status.ready,let port=status.port else{throw AppError.message("Synthetic loopback listener did not start")}
            var url=URLComponents(string:"http://127.0.0.1:\(port)/api/terminal/stream")!
            url.queryItems=[URLQueryItem(name:"session",value:original.id)]
            return url.url!
        }
        let first=NotificationStreamProbe(try await start());defer{first.close()}
        let initial=try await first.wait(seconds:5){$0["screen"] as? String == beforeOpen}
        try expectEqual(initial["sessionID"] as? String,original.id,"Opening after unobserved frames returns the latest same original")
        try await Task.sleep(for:.milliseconds(150))
        let changed="live changed 한글 e\u{301}\n• Working (esc to interrupt)"
        screen.replace(changed);await engine.refreshScreenHost(.iterm)
        _ = try await first.wait(seconds:1.5){$0["screen"] as? String == changed}
        try await Task.sleep(for:.milliseconds(150))
        screen.replace(changed,cursor:TerminalCursor(offset:2));await engine.refreshScreenHost(.iterm)
        _ = try await first.wait(seconds:1.5){($0["cursor"] as? JSONObject)?["offset"] as? Int == 2}
        try await Task.sleep(for:.milliseconds(150))
        screen.replace(changed,cursor:TerminalCursor(offset:2),appearance:TerminalAppearance(runs:[.init(offset:0,length:1,fg:"#22aacc")]))
        await engine.refreshScreenHost(.iterm)
        _ = try await first.wait(seconds:1.5){(($0["appearance"] as? JSONObject)?["runs"] as? [JSONObject])?.first?["fg"] as? String == "#22aacc"}
        first.close();service.stop()
        try await Task.sleep(for:.milliseconds(30))
        let reopened="latest after closing 🧪\n• Working (esc to interrupt)"
        screen.replace(reopened);await engine.refreshScreenHost(.iterm)
        let second=NotificationStreamProbe(try await start());defer{second.close()}
        let current=try await second.wait(seconds:5){$0["screen"] as? String == reopened}
        try expectEqual(current["sessionID"] as? String,original.id)
        try expect(engine.snapshot.events.isEmpty&&engine.managedPTY.inventory.isEmpty)
    }
}
