import Foundation
import Darwin
import CryptoKit

extension CodexAccountTransitionTarget {
    public static func discover(_ records: [ProcessRecord]) async throws -> [Self] {
        try await Task.detached(priority: .utility) {
            let sessions = ProcessDiscovery.sessions(records).filter { $0.agent == .codex && $0.tty.hasPrefix("/dev/") }
            var grouped: [String: Self] = [:]
            for session in sessions {
                try Task.checkCancellation()
                guard let record = records.first(where: { $0.key == session.id }),
                      let executable=CodexServerLocation.executable(record) else { continue }
                let hints = [ProcessEnvironment.read(record)?["CODEX_HOME"], NSHomeDirectory() + "/.codex"].compactMap { $0 }
                guard let home = CodexServerLocation.connectedHome(pid: record.pid, hints: hints) else { continue }
                let witness = CodexAccountTransitionWitness(pid: record.pid, started: record.started, tty: session.tty, threadID: nil)
                if grouped[home] == nil { grouped[home] = Self(home: home, executable: executable) }
                grouped[home]?.witnesses.append(witness)
            }
            return grouped.values.map { target in
                var copy = target; copy.witnesses.sort { $0.pid < $1.pid }; return copy
            }.sorted { $0.home < $1.home }
        }.value
    }
}

extension CodexAccountTransitionServices {
    public static var live: Self {
        Self(observe: { target in
            try await CodexAccountBackground.run { try CodexAccountTransitionLocal.observe(target) }
        }, interrupt: { target, server, thread, turn in
            try await CodexAccountBackground.run {
                guard try CodexAccountTransitionLocal.identity(target) == server else { throw AppError.message("중단 직전 Codex 서버가 바뀌었습니다.") }
                try Task.checkCancellation()
                let connection = try CodexQueueConnection(home: target.home)
                try CodexAccountTransitionLocal.quiesce(connection,target:target,server:server,id:thread,token:turn)
            }
        }, restart: { target, expected in
            try await CodexAccountBackground.run {
                let fresh = try CodexAccountTransitionLocal.observe(target)
                guard fresh.serverID == expected.serverID, fresh.savedAccount == expected.savedAccount,
                      fresh.serverAccount == expected.serverAccount,
                      fresh.savedAccount != nil, fresh.serverAccount != fresh.savedAccount || expected.loginRefreshRequested,
                      fresh.threads == expected.threads, fresh.threads.allSatisfy({ !$0.active && $0.blocker == nil }) else {
                    throw AppError.message("서버 전환 직전 계정·작업·대기 입력이 바뀌었습니다. 전환을 보류했습니다.")
                }
                for witness in target.witnesses {
                    guard CodexAccountTransitionLocal.sameProcess(witness),
                          CodexServerLocation.connectedHome(pid: witness.pid, hints: [target.home]) == target.home else {
                        throw AppError.message("기존 Codex 창의 서버 연결이 바뀌었습니다. 서버 전환을 보류했습니다.")
                    }
                }
                guard try CodexAccountTransitionLocal.identity(target) == expected.serverID else { throw AppError.message("전환할 서버가 바뀌었습니다.") }
                try Task.checkCancellation()
                // Official 0.166 defaults to a 60s graceful stop, permits
                // 300s, then allows forced-exit and readiness checks. A 30s
                // wrapper kills a valid restart before its drain completes.
                let result = try CommandRunner.run(target.executable, ["app-server", "daemon", "restart"], timeout: 375,
                    environment: CodexAccountTransitionLocal.environment(target), inheritEnvironment: false, outputLimit: 32_768, errorLimit: 32_768)
                guard result.status == 0 else { throw AppError.message("공통 서버 전환 결과를 확인하지 못했습니다. 같은 요청을 반복하지 말고 Mac에서 연결을 확인해주세요.") }
            }
        }, verify: { target, witnesses, threads in
            try await CodexAccountBackground.run {
                let before = try CodexAccountTransitionLocal.identity(target)
                let connection=try CodexQueueConnection(home:target.home)
                let serverPID=try connection.peerProcessID()
                // Background conversations are reattached by the official
                // TUI on selection. Verify retained history without resuming
                // it or requiring every offscreen thread to become loaded.
                for thread in threads {
                    guard let response=try? connection.request("thread/read",["threadId":thread.id,"includeTurns":false]),
                          let row=response["thread"] as? JSONObject,row["id"] as? String==thread.id,
                          let status=(row["status"] as? JSONObject)?["type"] as? String,["idle","notLoaded"].contains(status) else{return 0}
                }
                var verified = 0
                for witness in witnesses {
                    guard CodexAccountTransitionLocal.sameProcess(witness),
                          CodexServerLocation.connectedHome(pid: witness.pid, hints: [target.home],peerPID:serverPID) == target.home else { continue }
                    verified += 1
                }
                guard try CodexAccountTransitionLocal.identity(target) == before else {throw AppError.message("창 재연결 확인 중 Codex 서버가 바뀌었습니다.")}
                return verified
            }
        },resume:{target,expected,original,receipt in
            try await CodexAccountBackground.run {try CodexAccountContinuationLocal.resume(target,expected:expected,original:original,receipt:receipt)}
        })
    }
}

private enum CodexAccountBackground {
    static func run<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        let child = Task.detached(priority: .utility, operation: operation)
        return try await withTaskCancellationHandler(operation: {
            do {
                let result = try await child.value
                try Task.checkCancellation(); return result
            } catch {
                // The socket client also stops on cancellation, using its
                // historical timeout error. Preserve cancellation at this API.
                try Task.checkCancellation(); throw error
            }
        }, onCancel: { child.cancel() })
    }
}

/// All inspection is local metadata. This adapter never reads credentials,
/// resumes a conversation, creates a turn, edits a queue or types into a TUI.
enum CodexAccountTransitionLocal {
    static func environment(_ target: CodexAccountTransitionTarget) -> [String: String] {
        ["HOME": NSHomeDirectory(), "CODEX_HOME": target.home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "NO_COLOR": "1"]
    }
    static func sameProcess(_ witness: CodexAccountTransitionWitness) -> Bool {
        (try? ProcessDiscovery.read(pid: witness.pid))?.contains {
            $0.pid == witness.pid && $0.started == witness.started && "/dev/" + $0.tty == witness.tty && $0.agent == .codex
        } == true
    }
    static func identity(_ target: CodexAccountTransitionTarget) throws -> String {
        guard target.executable.hasPrefix("/"), target.home.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: target.executable),
              let socket = CodexQueueConnection.socketPath(home: target.home) else { throw AppError.message("이 Codex의 관리형 로컬 서버를 찾지 못했습니다.") }
        let result = try CommandRunner.run(target.executable, ["app-server", "daemon", "version"], timeout: 8,
            environment: environment(target), inheritEnvironment: false, outputLimit: 32_768, errorLimit: 32_768)
        guard result.status == 0, let data = result.output.data(using: .utf8),
              let version = try JSONSerialization.jsonObject(with: data) as? JSONObject,
              version["status"] as? String == "running", ["pid", "launchd"].contains(version["backend"] as? String ?? ""),
              let current = version["appServerVersion"] as? String, supported(current),
              version["cliVersion"] as? String == current, version["managedCodexVersion"] as? String == current,
              let managed = version["managedCodexPath"] as? String, managed.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: managed),
              let control = version["socketPath"] as? String, URL(fileURLWithPath: control).resolvingSymlinksInPath().path == socket else {
            throw AppError.message("공식 관리형 Codex 0.166.0 이상과 같은 버전의 CLI가 필요합니다. 현재 실행 방식은 자동 전환을 지원하지 않습니다.")
        }
        var info = stat(), binary = stat(), managedInfo = stat()
        guard lstat(socket, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK,
              stat(target.executable, &binary) == 0, stat(managed, &managedInfo) == 0,
              [getuid(), 0].contains(binary.st_uid), [getuid(), 0].contains(managedInfo.st_uid) else {
            throw AppError.message("Codex 서버·실행 파일의 소유권을 확인하지 못했습니다.")
        }
        return digest([socket, String(info.st_dev), String(info.st_ino), current, String(binary.st_dev), String(binary.st_ino), String(managedInfo.st_ino)])
    }
    static func supported(_ version: String) -> Bool {
        let pieces = version.split(separator: ".")
        guard pieces.count == 3, let major = Int(pieces[0]), let minor = Int(pieces[1]), let patch = Int(pieces[2]), patch >= 0 else { return false }
        return major > 0 || major == 0 && minor >= 166
    }
    static func digest(_ values: [String]) -> String {
        SHA256.hash(data: try! JSONEncoder().encode(values)).map { String(format: "%02x", $0) }.joined()
    }
    static func account(_ result: JSONObject) throws -> String? {
        guard let sessions = result["sessions"] as? [JSONObject], sessions.count <= 100 else { throw AppError.message("Codex 로그인 메타데이터를 확인하지 못했습니다.") }
        if sessions.isEmpty, result["activeSessionId"] == nil || result["activeSessionId"] is NSNull { return nil }
        guard let active = result["activeSessionId"] as? String,
              sessions.filter({ $0["isActive"] as? Bool == true }).count == 1,
              let selected = sessions.first(where: { $0["sessionId"] as? String == active && $0["isActive"] as? Bool == true }),
              let user = selected["userId"] as? String, !user.isEmpty, user.utf8.count <= 1024,
              let workspace = selected["selectedWorkspaceAccountId"] as? String, !workspace.isEmpty, workspace.utf8.count <= 1024 else {
            throw AppError.message("로그인의 안정된 계정 ID를 확인하지 못했습니다. 로그인 완료 후 다시 확인해주세요.")
        }
        return digest([user, workspace])
    }
    static func observe(_ target: CodexAccountTransitionTarget) throws -> CodexAccountTransitionObservation {
        let before = try identity(target)
        let saved = try CodexAccountMetadataProcess.read(target)
        let connection = try CodexQueueConnection(home: target.home)
        // A validated empty session list is a signed-out server, not a failed
        // observation. It must be recoverable using the saved login. Malformed
        // metadata still throws, and restart revalidates this exact nil state.
        let current = try account(connection.request("accountSession/list", ["refreshWorkspaceMetadata": false]))
        var cursor: String?, seen = Set<String>(), ids = Set<String>(), threads: [CodexAccountTransitionThread] = []
        repeat {
            var params: JSONObject = ["limit": 100]
            if let cursor { params["cursor"] = cursor }
            let page = try connection.request("thread/loaded/list", params)
            guard let rows = page["data"] as? [String], rows.count <= 100 else { throw AppError.message("전체 실행 대화 목록을 확인하지 못했습니다.") }
            for id in rows {
                guard UUID(uuidString: id) != nil, ids.insert(id).inserted, ids.count <= 1000 else { throw AppError.message("실행 대화 목록이 중복되거나 지원 범위를 넘었습니다.") }
                let metadata=try connection.request("thread/read",["threadId":id,"includeTurns":false])
                if let row=metadata["thread"] as? JSONObject,row["id"] as? String==id,
                   row["ephemeral"] as? Bool==true,row["threadSource"] as? String=="thread_title",
                   let status=(row["status"] as? JSONObject)?["type"] as? String,["active","idle","systemError","notLoaded"].contains(status) {
                    // Official TUI title generation has neither paginated
                    // turns nor retained history. The daemon lifecycle owns
                    // cancelling this internal job; it is not a user session.
                    // Unknown/user ephemeral threads still fail closed below.
                    continue
                }
                threads.append(try thread(connection, id: id,metadata:metadata,home:target.home))
            }
            cursor = try nextCursor(page)
            guard cursor == nil || seen.insert(cursor!).inserted, seen.count < 100 else { throw AppError.message("실행 대화 목록 조회가 반복됐습니다.") }
        } while cursor != nil
        guard try identity(target) == before else { throw AppError.message("계정 확인 중 공통 서버가 바뀌었습니다.") }
        return .init(savedAccount: saved, serverAccount: current, serverID: before, threads: threads.sorted { $0.id < $1.id })
    }
    static func nextCursor(_ page: JSONObject) throws -> String? {
        guard let value = page["nextCursor"], !(value is NSNull) else { return nil }
        guard let cursor = value as? String, !cursor.isEmpty, cursor.utf8.count <= 8192 else { throw AppError.message("목록의 다음 위치를 확인하지 못했습니다.") }
        return cursor
    }
    static func quiesce(_ connection:CodexQueueConnection,target:CodexAccountTransitionTarget,server:String,id:String,token:String) throws {
        func current() throws -> CodexAccountTransitionThread {
            try Task.checkCancellation()
            guard try identity(target)==server else {throw AppError.message("작업 정리 중 Codex 서버가 바뀌었습니다.")}
            let value=try thread(connection,id:id,home:target.home)
            guard value.stopToken==token else {throw AppError.message("작업 정리 중 새 실행 차례가 시작됐습니다. 새 작업은 중단하지 않았습니다.")}
            return value
        }
        _ = try current()
        let goal=try connection.request("thread/goal/get",["threadId":id])
        if (goal["goal"] as? JSONObject)?["status"] as? String == "active" {
            let latest=try current();try Task.checkCancellation()
            if latest.blocker == "활성 Goal" {
                let paused=try connection.request("thread/goal/set",["threadId":id,"status":"paused","origin":"automatic"])
                guard (paused["goal"] as? JSONObject)?["status"] as? String == "paused" else {throw AppError.message("Goal 일시정지 결과를 확인하지 못했습니다. 같은 요청은 반복하지 않습니다.")}
            }
        }
        var cursor:String?,seen=Set<String>(),processes=Set<String>()
        repeat {
            var params:JSONObject=["threadId":id,"limit":100]
            if let cursor {params["cursor"]=cursor}
            let page=try connection.request("thread/backgroundTerminals/list",params)
            guard let data=page["data"] as? [JSONObject],data.count<=100 else {throw AppError.message("정리할 Codex 백그라운드 작업 목록을 확인하지 못했습니다.")}
            for row in data {
                guard let process=row["processId"] as? String,!process.isEmpty,process.utf8.count<=256,
                      processes.insert(process).inserted,processes.count<=1000 else {throw AppError.message("백그라운드 작업 식별자가 중복되거나 불명확합니다.")}
            }
            cursor=try nextCursor(page)
            guard cursor==nil || seen.insert(cursor!).inserted,seen.count<100 else {throw AppError.message("백그라운드 작업 목록이 반복됐습니다.")}
        } while cursor != nil
        // One durable thread reservation precedes this entire operation. On
        // partial/unknown delivery none of its mutations are replayed.
        for process in processes.sorted() {
            _ = try current();try Task.checkCancellation()
            let result=try connection.request("thread/backgroundTerminals/terminate",["threadId":id,"processId":process])
            guard result["terminated"] is Bool else {throw AppError.message("백그라운드 작업 종료 결과를 확인하지 못했습니다.")}
        }
        let value=try current()
        if value.active {
            guard let turn=value.turnID else {throw AppError.message("중단할 실행 차례를 확인하지 못했습니다.")}
            try Task.checkCancellation()
            do {
                _ = try connection.request("turn/interrupt",["threadId":id,"turnId":turn],classifyError:true)
            } catch let error as CodexControlRPCError where error.method == "turn/interrupt" && error.code == -32600 && error.reason == "no active turn to interrupt" {
                // Goal pause can finish this turn between inspection and the
                // interrupt. Read back the reserved turn; never send it again.
                for attempt in 0..<5 {
                    try Task.checkCancellation()
                    let metadata=try connection.request("thread/read",["threadId":id,"includeTurns":false])
                    guard let row=metadata["thread"] as? JSONObject,row["id"] as? String==id,
                          let status=(row["status"] as? JSONObject)?["type"] as? String,["active","idle"].contains(status) else {throw error}
                    if status == "idle" {
                        let settled=try current()
                        guard !settled.needsQuiescence,settled.turnID==turn,
                              ["completed","interrupted","failed"].contains(settled.turnStatus ?? "") else {throw error}
                        let fresh=try connection.request("thread/read",["threadId":id,"includeTurns":false])
                        guard let latest=fresh["thread"] as? JSONObject,latest["id"] as? String==id,
                              (latest["status"] as? JSONObject)?["type"] as? String == "idle",
                              try identity(target)==server else {throw error}
                        return
                    }
                    if attempt < 4 {Thread.sleep(forTimeInterval:0.05)}
                }
                throw error
            }
        }
    }
    static func thread(_ connection: CodexQueueConnection, id: String,metadata:JSONObject?=nil,home:String?=nil,allowSubagent:Bool=false) throws -> CodexAccountTransitionThread {
        let result = try metadata ?? connection.request("thread/read", ["threadId": id, "includeTurns": false])
        guard let row = result["thread"] as? JSONObject, row["id"] as? String == id,
              let status = (row["status"] as? JSONObject)?["type"] as? String, ["active", "idle", "systemError"].contains(status) else {
            throw AppError.message("대화의 실행 상태를 확인하지 못했습니다. 연결 상태가 불명확해 전환을 보류했습니다.")
        }
        let turns: JSONObject
        do {
            turns = try connection.request("thread/turns/list", ["threadId": id, "limit": 1, "itemsView": "notLoaded", "sortDirection": "desc"], classifyError: true)
        } catch let error as CodexControlRPCError where status == "idle" && error.isUnmaterialized(id) {
            // Official Codex rejects history before the first user message.
            // Confirm idle again: never hide an active turn or another error.
            let fresh = try connection.request("thread/read", ["threadId": id, "includeTurns": false])
            guard let row = fresh["thread"] as? JSONObject, row["id"] as? String == id,
                  (row["status"] as? JSONObject)?["type"] as? String == "idle" else {
                throw AppError.message("빈 대화 확인 중 작업이 시작됐습니다. 현재 상태를 다시 확인해주세요.")
            }
            turns = ["data": [JSONObject]()]
        }
        guard let latest = turns["data"] as? [JSONObject], latest.count <= 1 else { throw AppError.message("현재 실행 차례를 확인하지 못했습니다.") }
        var turnID: String?
        if let turn = latest.first {
            guard let value = turn["id"] as? String, !value.isEmpty, value.utf8.count <= 256,
                  let turnStatus = turn["status"] as? String,
                  (status == "active" ? turnStatus == "inProgress" : ["completed", "interrupted", "failed"].contains(turnStatus)) else {
                throw AppError.message("대화 상태와 실행 차례가 달라 다시 확인해야 합니다.")
            }
            turnID = value
        } else if status == "active" { throw AppError.message("중단할 현재 실행 차례가 없습니다.") }
        if status == "systemError" {
            // Official ThreadWatchManager clears running on systemError. An
            // expired login must not prevent replacing that very login. A
            // terminal last turn and a fresh dormant read are both required;
            // in-progress/stale error snapshots remain a restart barrier.
            let fresh=try connection.request("thread/read",["threadId":id,"includeTurns":false])
            guard latest.count==1,let row=fresh["thread"] as? JSONObject,row["id"] as? String==id,
                  let freshStatus=(row["status"] as? JSONObject)?["type"] as? String,["idle","systemError"].contains(freshStatus) else {
                throw AppError.message("오류 대화의 종료를 확인하는 중 상태가 바뀌었습니다. 새 작업은 중단하지 않았습니다.")
            }
        }
        var blocker: String?
        for (method, reason) in [("thread/queue/list", "대기 입력"), ("thread/backgroundTerminals/list", "백그라운드 작업")] {
            let page = try connection.request(method, ["threadId": id, "limit": 1])
            guard let data = page["data"] as? [JSONObject], data.count <= 1 else { throw AppError.message("대기 입력·백그라운드 작업을 확인하지 못했습니다.") }
            let next = try nextCursor(page)
            guard !data.isEmpty || next == nil else { throw AppError.message("대기 작업 목록이 불완전합니다.") }
            if !data.isEmpty { blocker = reason == "백그라운드 작업" ? reason : blocker ?? reason }
        }
        let parent=row["parentThreadId"] as? String
        let child=allowSubagent && parent.map({UUID(uuidString:$0) != nil && $0 != id}) == true
        let goalResult = try child
            ? connection.request("autoapprove/thread/goal/read",["threadId":id,"parentThreadId":parent!])
            : connection.request("thread/goal/get", ["threadId": id])
        if let goal = goalResult["goal"], !(goal is NSNull) {
            guard let object = goal as? JSONObject, let value = object["status"] as? String,
                  CodexGoal.Status(rawValue: value) != nil else { throw AppError.message("Goal 실행 상태를 확인하지 못했습니다.") }
            if value == "active" { blocker = "활성 Goal" }
        }
        let cwd=row["cwd"] as? String,provider=row["modelProvider"] as? String
        let root=row["source"] is String && row["threadSource"] as? String=="user" &&
            (row["parentThreadId"]==nil || row["parentThreadId"] is NSNull)
        let continuable=(root || child) && row["ephemeral"] as? Bool==false && cwd?.hasPrefix("/")==true && provider?.isEmpty==false
        var goal=continuable ? try CodexGoalTransport.decode(goalResult,threadID:id):nil
        if child,let current=goal {
            guard let identity=goalResult["identity"] as? JSONObject,let instance=identity["goalId"] as? String,
                  UUID(uuidString:instance) != nil,identity["objective"] as? String==current.objective,
                  identity["status"] as? String==current.status.rawValue,
                  (identity["tokenBudget"] as? NSNumber)?.int64Value==current.tokenBudget else {
                throw AppError.message("이동할 서브에이전트 Goal의 식별자를 확인하지 못했습니다.")
            }
            goal?.instanceID=instance
        }
        if !child,let home,let current=goal,let stored=try? CodexGoalTransport.readDatabase(home:home,threadID:id),
           stored.createdAt==current.createdAt,stored.objective==current.objective,stored.tokenBudget==current.tokenBudget {goal?.instanceID=stored.instanceID}
        return .init(id: id, turnID: turnID, active: status == "active", blocker: blocker,continuable:continuable,cwd:cwd,modelProvider:provider,goal:goal,turnStatus:latest.first?["status"] as? String)
    }
}

/// A short-lived, non-TTY app-server reads freshly stored login metadata.
/// Only this owned child is stopped. Responses are bounded and never logged.
enum CodexAccountMetadataProcess {
    static func read(_ target: CodexAccountTransitionTarget,environment:[String:String]?=nil) throws -> String? {
        let process = Process(), input = Pipe(), output = Pipe(), exited = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: target.executable)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.environment = environment ?? CodexAccountTransitionLocal.environment(target)
        process.currentDirectoryURL = URL(fileURLWithPath: target.home)
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in exited.signal() }
        defer {
            try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
            if process.isRunning {
                process.terminate()
                if exited.wait(timeout: .now() + 0.25) == .timedOut {
                    if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                    _ = exited.wait(timeout: .now() + 0.25)
                }
            }
        }
        try process.run()
        try? output.fileHandleForWriting.close(); try? input.fileHandleForReading.close()
        let fd = output.fileHandleForReading.fileDescriptor, deadline = ProcessInfo.processInfo.systemUptime + 8
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw AppError.message("로그인 조회 채널을 준비하지 못했습니다.") }
        var buffer = Data(), total = 0
        func send(_ object: JSONObject) throws {
            var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        func response(_ id: Int) throws -> JSONObject {
            while true {
                try Task.checkCancellation()
                if let newline = buffer.firstIndex(of: 10) {
                    let data = buffer[..<newline]; buffer.removeSubrange(...newline)
                    guard let value = try JSONSerialization.jsonObject(with: data) as? JSONObject else { throw AppError.message("로그인 조회 응답 형식을 확인하지 못했습니다.") }
                    if value["id"] as? Int != id { continue }
                    guard value["error"] == nil, let result = value["result"] as? JSONObject else { throw AppError.message("이 Codex 버전의 로그인 조회를 지원하지 않습니다.") }
                    return result
                }
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw AppError.message("로그인 조회 시간이 초과됐습니다.") }
                var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&item, 1, Int32(min(remaining * 1000, 250)))
                if ready < 0, errno == EINTR { continue }
                guard ready >= 0 else { throw AppError.message("로그인 조회 연결이 끊겼습니다.") }
                if ready == 0 { continue }
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count < 0, [EAGAIN, EWOULDBLOCK, EINTR].contains(errno) { continue }
                guard count > 0, total + count <= 524_288 else { throw AppError.message("로그인 조회 응답이 없거나 너무 큽니다.") }
                buffer.append(contentsOf: bytes.prefix(count)); total += count
            }
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "autoapprove-account-check", "version": RemoteWebVersion.current?.version ?? "0.2.231"], "capabilities": ["experimentalApi": true]]])
        _ = try response(1); try send(["method": "initialized"])
        try send(["id": 2, "method": "accountSession/list", "params": ["refreshWorkspaceMetadata": false]])
        return try CodexAccountTransitionLocal.account(response(2))
    }
}
