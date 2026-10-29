// Isolated real HTTP/Bonjour servers with synthetic processes and terminal transports.
// Never reads or sends input to a user's terminal.
import Foundation
import Darwin
import AutoApproveCore
import TerminalInputSupport

private final class PreviewOSPermissions:@unchecked Sendable {
    let directory:URL
    private let lock=NSLock()
    private var inputs:[JSONObject]=[]
    let target=OSPermissionTarget(name:"컴퓨터 유즈 테스트 앱 · 긴 이름 한글🙂",bundleID:"local.preview.permission",path:"/fixture/긴 프로젝트 이름/컴퓨터 유즈 테스트 앱.app",requirement:"identifier local.preview.permission and stable publisher",pid:89990,started:"Synthetic original app start")
    init(_ directory:URL) {self.directory=directory}
    func scan()->OSPermissionMonitorStatus {
        let url=directory.appendingPathComponent("os-control.json")
        let data=(try? Data(contentsOf:url)) ?? Data("{}".utf8)
        let object=(try? JSONSerialization.jsonObject(with:data)) as? JSONObject ?? [:]
        if object["closed"] as? Bool==true {return .init(available:true,detail:"격리된 OS 권한 연결 · 실제 OS 입력 없음")}
        let kind=(object["kind"] as? String).flatMap(OSPermissionKind.init(rawValue:)) ?? .camera
        let suffix=object["suffix"] as? String ?? "first"
        let request=OSPermissionRequest(kind:kind,requester:target,ownerPID:77,ownerStarted:"Synthetic OS owner",ownerBundleID:"com.apple.UserNotificationCenter",windowToken:suffix,content:"\"컴퓨터 유즈 테스트 앱 · 긴 이름 한글🙂\" would like to access the camera.\n<img src=x onerror=alert(1)>\n실제 OS 요청이 아닌 격리된 테스트 데이터입니다.",action:.allow,actionToken:"allow-"+suffix)
        return .init(available:true,detail:"격리된 OS 권한 연결 · 실제 OS 입력 없음",requests:[request])
    }
    func input(_ request:OSPermissionRequest)->OSPermissionDelivery {
        lock.lock();defer{lock.unlock()};inputs.append(["id":request.id,"kind":request.kind.rawValue,"action":request.action.rawValue])
        if let data=try? JSONSerialization.data(withJSONObject:["inputs":inputs,"realOSInputs":0,"realTerminalInputs":0]) {try? data.write(to:directory.appendingPathComponent("os-inputs.json"),options:.atomic)}
        return .sent
    }
}

private final class PreviewScreens: @unchecked Sendable {
    private let lock = NSLock()
    var screens: [String: String] = [:]
    private var nextScrollLine = 1000
    var historyReport:URL?
    private var historyReads=0
    var progressReport:URL?
    private var progressInputs:[JSONObject]=[]
    static let progressWorking="• Working (12s • esc to interrupt)\n\n› Ask Codex to do anything\n\n? for shortcuts"
    func history() -> String {
        lock.lock();historyReads+=1;let count=historyReads;lock.unlock()
        if let file=historyReport,let data=try? JSONSerialization.data(withJSONObject:["captures":count,"realTerminalReads":0]) {try? data.write(to:file,options:.atomic)}
        Thread.sleep(forTimeInterval:0.3)
        return "EARLIEST HISTORY · 가장 오래된 기록\n"+(0..<20_000).map {"기록 \($0) · 한글🙂 e\u{301} <img src=x onerror=alert(1)>\n"}.joined()+"LATEST HISTORY · 가장 최근 기록"
    }
    static func scrollLine(_ index: Int) -> String {
        var bits = UInt64(index) &+ 0x9e3779b97f4a7c15, words = ""
        for _ in 0..<4 { bits = bits &* 2862933555777941757 &+ 3037000493; words += String(format:"%016llx",bits) }
        return String(format:"%05d",index)+" 합성 Codex 한글🙂 e\u{301} /fixture/ "+words+"\n"
    }
    func read(_ tty: String) -> String {
        lock.lock(); defer { lock.unlock() }
        if CommandLine.arguments.contains("--connection-performance") { Thread.sleep(forTimeInterval:0.08) }
        return screens[tty] ?? ""
    }
    func input(_ target: ScreenTarget, _ expected: String, _ input: RemoteTerminalInput) -> TerminalDelivery {
        lock.lock(); defer { lock.unlock() }
        guard screens[target.tty] == expected else { return .screenChanged }
        if CommandLine.arguments.contains("--codex-progress") {
            progressInputs.append(["kind":input.kind.rawValue,"text":input.text,"tty":target.tty])
            if let file=progressReport,let data=try? JSONSerialization.data(withJSONObject:["inputs":progressInputs,"realTerminalInputs":0]) {try? data.write(to:file,options:.atomic)}
            if input.kind == .escape,!CommandLine.arguments.contains("--progress-hang") {screens[target.tty]="Conversation interrupted\n\n› Ask Codex to do anything\n\n? for shortcuts"}
            if input.kind == .submit {screens[target.tty]="Synthetic progress request accepted\n"+Self.progressWorking}
            return .sent
        }
        if CommandLine.arguments.contains("--scroll-payload"), input.bytes.hasPrefix("SCROLL-") {
            let lines = expected.split(separator:"\n",omittingEmptySubsequences:false).dropLast()
            let added = (nextScrollLine..<(nextScrollLine+3)).map(Self.scrollLine).joined(); nextScrollLine += 3
            if input.bytes.hasPrefix("SCROLL-UP-") { screens[target.tty] = added+lines.dropLast(3).joined(separator:"\n")+"\n" }
            else { screens[target.tty] = lines.dropFirst(3).joined(separator:"\n")+"\n"+added }
            return .sent
        }
        screens[target.tty, default: ""] += "\n[검증용 입력] " + ([.text, .submit, .characters].contains(input.kind) ? input.bytes : input.kind.rawValue)
        return .sent
    }
}

@main struct RemotePreview {
    static func fixtureAppearance(_ screen: String) -> TerminalAppearance {
        if CommandLine.arguments.contains("--scroll-payload") {
            return TerminalAppearance(runs:[.init(offset:0,length:8,fg:"#87d7ff",bold:true),.init(offset:20,length:6,fg:"#a6e3a1")])
        }
        // Explicit synthetic cell attributes, not production keyword highlighting.
        let text = screen as NSString
        let samples: [(String, String, String?, Bool, Bool)] = [
            ("$ pnpm test", "#87d7ff", nil, true, false),
            ("✓ 12 checks passed · 합성 출력", "#d97757", nil, true, false),
            ("warning: 재연결 상태 검증 예시", "#b1b9f9", nil, false, true),
            ("error: 오류 강조 검증 예시", "#87d7ff", "#303030", false, false),
            ("+ 갱신 후", "#a6e3a1", nil, false, false),
            ("- 갱신 전", "#f38ba8", nil, false, false)]
        let runs = samples.compactMap { sample -> TerminalAppearance.Run? in
            let range = text.range(of: sample.0)
            guard range.location != NSNotFound else { return nil }
            return .init(offset: range.location, length: range.length, fg: sample.1, bg: sample.2,
                         bold: sample.3 ? true : nil, underline: sample.4 ? true : nil)
        }.sorted { $0.offset < $1.offset }
        return TerminalAppearance(runs: runs)
    }
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let label = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "A"
        let directOnly = CommandLine.arguments.contains("--direct-only")
        let connectionPerformance = CommandLine.arguments.contains("--connection-performance")
        let progressMode=CommandLine.arguments.contains("--codex-progress")
        let osMode=CommandLine.arguments.contains("--os-permissions")
        let releaseOption = CommandLine.arguments.first(where: { $0.hasPrefix("--web-version=") })?.dropFirst("--web-version=".count)
        let releaseParts = releaseOption?.split(separator: ":")
        let webVersion = releaseOption == "legacy" ? nil : releaseParts.flatMap { parts in
            parts.count == 2 ? Int(parts[1]).map { RemoteWebVersion(version: String(parts[0]), build: $0) } : nil
        } ?? RemoteWebVersion.current
        let state = PreviewScreens()
        if progressMode {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            state.progressReport=directory.appendingPathComponent("progress-inputs.json")
        }
        if CommandLine.arguments.contains("--terminal-history") {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            state.historyReport=directory.appendingPathComponent("history-captures.json")
        }
        let records = ProcessDiscovery.parse((0..<6).map { index in
            "\(82000 + index) 1 ttys0\(80 + index) \(82000 + index) \(82000 + index) Mon Sep 21 09:00:0\(index) 2026 /usr/local/bin/codex"
        }.joined(separator: "\n"))
        let transport = CodexReplyTransport(prepare: { _, question in CodexReplyTarget(executable: "/fixture/codex", home: directory.path, threadID: question.threadID) }, send: { _, _ in UUID().uuidString })
        var adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map {
            TerminalScreen(tty: $0.tty, contents: state.read($0.tty), title: "검증용 \(label) · " + $0.tty,
                appearance: Self.fixtureAppearance(state.read($0.tty)))
        }) }, approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, input: { target, expected, _, input in state.input(target, expected, input) })
        if connectionPerformance {
            adapter.presentationScreens = { targets in TerminalSnapshot(screens:targets.map {
                TerminalScreen(tty:$0.tty,contents:state.read($0.tty),cursor:TerminalCursor(offset:0))
            }) }
        }
        if CommandLine.arguments.contains("--terminal-history") {adapter.history={_ in state.history()}}
        let capture = connectionPerformance ? TerminalWindowCapture(permissions:{TerminalWindowPermissions(screen:false,keyboard:false,automation:true)},
            automationQuery:{Thread.sleep(forTimeInterval:0.12);return true}) : nil
        let progressIdentity:(@Sendable (Int32)->TTYInputIdentity?)?
        if progressMode {
            progressIdentity={pid in
                guard let record=records.first(where:{$0.pid==pid}) else {return nil}
                let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.timeZone = .current;formatter.dateFormat="EEE MMM d HH:mm:ss yyyy"
                guard let date=formatter.date(from:record.started) else {return nil}
                return TTYInputIdentity(pid:pid,processGroup:record.processGroup,uid:getuid(),effectiveUID:geteuid(),device:42,startSeconds:UInt64(date.timeIntervalSince1970),startMicroseconds:70)
            }
        } else {progressIdentity=nil}
        let inputAvailable:(@Sendable ()->Bool)?
        if progressMode {inputAvailable={true}} else if connectionPerformance {inputAvailable={false}} else {inputAvailable=nil}
        let osState=PreviewOSPermissions(directory)
        let osServices:OSPermissionServices?
        if osMode {osServices=OSPermissionServices(scan:{_ in osState.scan()},approve:{request,authorized in authorized() ? osState.input(request):.unavailable("Synthetic policy revoked")})} else {osServices=nil}
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), questionTransport: transport,
            claudeRegistryReader: { _ in [] }, processReader: { records }, screenAdapters: [.terminal: adapter],terminalWindowCapture:capture,
            terminalInputAvailable:inputAvailable,terminalInputIdentity:progressIdentity,osPermissionServices:osServices)
        if let raw=CommandLine.arguments.first(where:{$0.hasPrefix("--progress-delay=")}),let seconds=Double(raw.dropFirst("--progress-delay=".count)) {engine.codexProgressTimeout=seconds}
        try engine.start(poll: false)
        var sessions = ProcessDiscovery.sessions(records)
        sessions[0].id += "+한글 검증"
        for index in sessions.indices {
            sessions[index].terminal = .terminal
            sessions[index].cwd = "/Users/qa/projects/" + ["autoapprove", "결제-서비스", "아주-긴-프로젝트-이름-네트워크-협력-터미널-화면-검증", "api-server", "문서-정리", "배포-작업"][index]
            state.screens[sessions[index].tty] = "AutoApprove 웹 검증 · 합성 데이터 · \(label)\n\n프로젝트: \(sessions[index].cwd)\n브랜치: feature/network-sessions\n\n✓ 연결된 터미널의 현재 화면\n실제 사용자 터미널에 입력하지 않습니다.\n\n$ pnpm test\n✓ 12 checks passed · 합성 출력\nwarning: 재연결 상태 검증 예시\nerror: 오류 강조 검증 예시\n@@ -1,2 +1,2 @@\n- 갱신 전\n+ 갱신 후\n<img src=x onerror=alert(1)> · 문자로만 표시\n\n› \n? for shortcuts"
            if CommandLine.arguments.contains("--stream-payload") {
                var output = ""
                for line in 0..<600 {
                    output += "\n[합성 빌드 \(line)] /fixture/project/src/module-\(line).swift · 검사 통과 · 출력·색상·한글🙂 보존"
                }
                state.screens[sessions[index].tty,default:""] += output
            }
            if CommandLine.arguments.contains("--scroll-payload") { state.screens[sessions[index].tty] = (0..<600).map(PreviewScreens.scrollLine).joined() }
            if progressMode {state.screens[sessions[index].tty]=PreviewScreens.progressWorking}
        }
        engine.updateDiscovery(sessions, records: records); await engine.connectTerminal()
        for index in sessions.indices {
            try engine.setCustomization(sessions[index].id, value: SessionCustomization(title: index == 2 ? "긴 표시 이름과 여러 단어가 있는 터미널 · 좁은 휴대폰 화면에서도 전체 이름을 확인합니다" : "검증용 \(label) · " + ["웹 관리 구현", "질문 응답 대기", "긴 텍스트 검증", "API 회귀 검사", "문서 정리", "배포 준비"][index]))
        }
        try engine.setAutomatic(sessions[3].id, enabled: true)
        if progressMode {try engine.setAutomatic(sessions[0].id,enabled:true)}
        if osMode {try engine.setAutomatic(sessions[0].id,enabled:true)}
        engine.updateGitBranches(sessions.map { GitBranchUpdate(sessionID: $0.id, cwd: $0.cwd, state: .init(kind: .branch, name: "feature/network-sessions")) })
        let question = QueuedQuestion(id: "fixture-question-" + label, threadID: UUID().uuidString, title: "어떤 환경에서 네트워크 연결을 확인할까요? 검증용 질문이며 실제 작업에는 영향을 주지 않습니다.", options: ["개인 핫스팟에서 확인", "같은 Wi-Fi에서 확인", "긴 선택지의 줄바꿈과 선택 영역이 작은 휴대폰 화면에서도 유지되는지 확인"])
        engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: sessions[1].id, questions: [question], threadID: question.threadID)])
        let nodeIDFile = directory.appendingPathComponent("preview-node-id")
        let nodeID = (try? String(contentsOf: nodeIDFile, encoding: .utf8)) ?? UUID().uuidString
        try nodeID.write(to: nodeIDFile, atomically: true, encoding: .utf8)
        var status = RemoteNetworkStatus()
        let web = RemoteNetworkService(engine: engine, nodeID: nodeID, name: "QA Mac \(label) · 검증용", bonjourEnabled: !directOnly, discoveryAddresses: {
            // Test only these isolated endpoints, never scan the user's actual LAN.
            guard directOnly, let data = try? Data(contentsOf: directory.deletingLastPathComponent().appendingPathComponent("direct-peers.json")) else { return [] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }, webVersion: webVersion, onStatus: { status = $0 })
        if directOnly { web.directDiscoveryInterval = 1 }
        try web.start(port: 0)
        for _ in 0..<100 {
            if status.ready { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard status.ready, let port = status.port else { throw AppError.message("검증용 웹 서버 포트를 열지 못했습니다: " + status.detail) }
        for _ in 0..<100 {
            if directOnly || status.urls.contains(where: { URL(string: $0)?.host?.hasPrefix("autoapprove-") == true }) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let info: JSONObject = ["id": nodeID, "name": "QA Mac \(label) · 검증용", "url": "http://127.0.0.1:\(port)",
                                "namedURL": status.urls.first(where: { URL(string: $0)?.host?.hasPrefix("autoapprove-") == true }) ?? ""]
        print(String(decoding: try JSONSerialization.data(withJSONObject: info), as: UTF8.self)); fflush(stdout)
        while !Task.isCancelled {
            if osMode {await engine.refreshOSPermissions()}
            if progressMode {engine.receiveScreen(sessionID:sessions[0].id,raw:state.read(sessions[0].tty),generation:"terminal:"+sessions[0].id,source:.terminalScreen)}
            if CommandLine.arguments.contains("--trace-routes"), let value = Mirror(reflecting: web).children.first(where: { $0.label == "peers" })?.value {
                try? String(describing: value).write(to: directory.appendingPathComponent("route-trace.txt"), atomically: true, encoding: .utf8)
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        web.stop(); engine.stop()
    }
}
