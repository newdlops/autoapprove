import Foundation
import Darwin

/// Original CLI/server operations used by the app's restart coordinator.
/// Terminal delivery and collaboration-group restoration stay in the engine.
enum CodexCohortRuntime {
    /// A stopped official daemon can leave a real socket inode behind. File
    /// existence is not liveness; only connection refusal/absence means absent.
    private static func peer(home:String)throws->CodexNativePeerIdentity? {
        guard let path=CodexQueueConnection.socketPath(home:home) else {
            let entry=URL(fileURLWithPath:home).appendingPathComponent("app-server-control/app-server-control.sock").path
            var info=stat(),target=stat()
            if lstat(entry,&info) != 0,errno==ENOENT{return nil}
            if info.st_uid==getuid(),info.st_mode&S_IFMT==S_IFLNK,stat(entry,&target) != 0,errno==ENOENT{return nil}
            throw AppError.message("원래 서버의 소켓 소유자·형식을 확인하지 못했습니다.")
        }
        var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX);address.sun_len=UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes=Array(path.utf8)+[0]
        guard bytes.count<=MemoryLayout.size(ofValue:address.sun_path) else{throw AppError.message("서버 소켓 경로가 너무 깁니다.")}
        withUnsafeMutableBytes(of:&address.sun_path){$0.copyBytes(from:bytes)}
        let fd=Darwin.socket(AF_UNIX,SOCK_STREAM,0)
        guard fd>=0 else{throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
        defer{close(fd)}
        guard fcntl(fd,F_SETFD,FD_CLOEXEC)==0,fcntl(fd,F_SETFL,O_NONBLOCK)==0 else{throw POSIXError(.EIO)}
        var result=withUnsafePointer(to:&address){pointer in pointer.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
        var error=errno
        if result != 0,error==EINPROGRESS {
            var descriptor=pollfd(fd:fd,events:Int16(POLLOUT),revents:0)
            guard poll(&descriptor,1,1000)>0 else{throw AppError.message("원래 서버의 연결 상태를 확인하지 못했습니다.")}
            var size=socklen_t(MemoryLayout<Int32>.size),socketError:Int32=0
            guard getsockopt(fd,SOL_SOCKET,SO_ERROR,&socketError,&size)==0 else{throw POSIXError(.EIO)}
            error=socketError;result=socketError==0 ? 0:-1
        }
        if result != 0 {
            if error==ECONNREFUSED || error==ENOENT{return nil}
            throw POSIXError(POSIXErrorCode(rawValue:error) ?? .EIO)
        }
        let observed=try CodexNativeKernelPeer.connectedSocket(fd).identity
        let verified=try CodexOfficialExecutable.verifyServer(CodexQueueConnection(home:home))
        guard observed==verified else{throw AppError.message("조회 중 원래 서버 연결이 바뀌었습니다.")}
        return verified
    }
    private static func background<Value>(_ operation:@escaping @Sendable () async throws ->Value) async throws ->Value {
        let task=Task.detached(priority:.utility,operation:operation)
        return try await withTaskCancellationHandler(operation:{try await task.value},onCancel:{task.cancel()})
    }
    static func restarted(_ context:CodexCohortRestartContext,plan:CodexCohortRestartPlan)throws->Bool {
        guard context.quiesced==true,let peer=try peer(home:plan.sourceHome) else{return false}
        return context.restartServer==false || peer != context.originalServer
    }

    static func restart(_ initial:CodexCohortRestartContext,plan:CodexCohortRestartPlan,
                        save:@escaping @Sendable(CodexCohortRestartContext) async throws ->Void) async throws ->CodexCohortRestartContext {
        try await background {
            var context=initial
            let cli=try context.launch.officialContext()
            if context.quiesced != true {
                let connection=try CodexQueueConnection(home:plan.sourceHome,requestScopedDeadline:true)
                guard try CodexOfficialExecutable.verifyServer(connection)==context.originalServer else{throw AppError.message("종료할 원래 서버가 바뀌었습니다. 새 서버의 작업은 중단하지 않았습니다.")}
                let target=CodexAccountTransitionTarget(home:plan.sourceHome,executable:cli.executable)
                let runtime=try CodexAccountRuntime(target)
                let server=try CodexAccountTransitionLocal.identity(target,runtime:runtime)
                // Stop future Goal work and flush current work/accounting using
                // the same original lifecycle used by account reconnection.
                let roots=plan.original.entries.map(\.conversationID)
                let movingRoots=Set(plan.original.entries.filter{plan.movingEntryIDs.contains($0.id)}.map(\.conversationID))
                var settled=Set<String>()
                while true {
                    // A running parent may have spawned a child after the
                    // preview. Refresh after each parent is stopped, and keep
                    // previously captured children across a cold archive retry.
                    let fresh=try CodexMigrationThread.captureScope(connection:connection,home:plan.sourceHome,rootIDs:roots)
                    var byID=Dictionary(uniqueKeysWithValues:context.scope.map{($0.id,$0)})
                    var changed=false
                    for thread in fresh {
                        if let previous=byID[thread.id] {
                            guard previous.parentID==thread.parentID else{throw AppError.message("보존할 하위 대화의 부모 연결이 바뀌었습니다.")}
                        } else {
                            byID[thread.id]=thread;context.scope.append(thread);changed=true
                            context.originalGoals[thread.id]=try CodexSessionAttachment.goalIfPresent(home:plan.sourceHome,threadID:thread.id)
                        }
                    }
                    func ancestry(_ id:String)throws->[String] {
                        var chain=[String](),seen=Set<String>(),current=id
                        while !roots.contains(current) {
                            guard seen.insert(current).inserted,let parent=byID[current]?.parentID,byID[parent] != nil else{throw AppError.message("보존할 하위 대화의 소속을 확인하지 못했습니다.")}
                            chain.append(current);current=parent
                        }
                        return chain+[current]
                    }
                    var depths:[String:Int]=[:]
                    for thread in context.scope {
                        let chain=try ancestry(thread.id);depths[thread.id]=chain.count
                        if let root=chain.last,movingRoots.contains(root),context.movingThreads.insert(thread.id).inserted {
                            context.transfers[thread.id]=UUID();changed=true
                        }
                    }
                    if changed {try await save(context)}
                    guard let item=context.scope.filter({!settled.contains($0.id)}).sorted(by:{(depths[$0.id] ?? 0,$0.id)<(depths[$1.id] ?? 0,$1.id)}).first else{break}
                    try Task.checkCancellation()
                    let metadata=try connection.request("thread/read",["threadId":item.id,"includeTurns":false])["thread"] as? JSONObject
                    if context.movingThreads.contains(item.id),(metadata?["path"] as? String)?.contains("/archived_sessions/")==true {settled.insert(item.id);continue}
                    if (metadata?["status"] as? JSONObject)?["type"] as? String == "notLoaded" {
                        if context.quiesceSeen?.contains(item.id) != true {
                            context.originalGoals[item.id]=try CodexSessionAttachment.goalIfPresent(home:plan.sourceHome,threadID:item.id)
                            context.quiesceSeen=(context.quiesceSeen ?? []).union([item.id])
                            try await save(context)
                        }
                        if let goal=context.originalGoals[item.id],goal.status == .active {
                            // Exclude an independent rollout writer while
                            // deferring automatic work before native attachment.
                            let lease=try CodexOfficialWriterLease(home:plan.sourceHome,threadIDs:[item.id])
                            defer{lease.close()}
                            let access=try CodexOfficialGoalStateAccess(home:plan.sourceHome,userHome:context.launch.userHome,executable:cli.executable)
                            let snapshot=try access.snapshot(threadID:item.id)
                            guard snapshot.row.goalID==goal.instanceID,snapshot.row.objective==goal.objective,
                                  snapshot.row.tokenBudget==goal.tokenBudget,snapshot.row.createdAtMs/1000==goal.createdAt,
                                  snapshot.row.status=="active",snapshot.row.tokensUsed>=goal.tokensUsed,
                                  snapshot.row.timeUsedSeconds>=goal.timeUsedSeconds else{throw AppError.message("독립 실행의 보존할 Goal이 바뀌었습니다.")}
                            _=try access.deferContinuation(snapshot)
                        }
                        // No parent message or model turn is injected. A Goal
                        // was paused/deferred above before this lifecycle hook.
                        _=try connection.request("thread/resume",["threadId":item.id,"excludeTurns":true],classifyError:true)
                    }
                    let current=try CodexAccountTransitionLocal.thread(connection,id:item.id,home:plan.sourceHome,allowSubagent:true)
                    if context.quiesceSeen?.contains(item.id) != true {
                        context.originalGoals[item.id]=current.goal
                        context.quiesceSeen=(context.quiesceSeen ?? []).union([item.id])
                        try await save(context)
                    }
                    try await CodexAccountTransitionLocal.quiesce(connection,target:target,runtime:runtime,server:server,id:item.id,token:current.stopToken)
                    settled.insert(item.id)
                }
                var archived:[String:String]=[:]
                if plan.sourceHome != plan.destinationHome {
                    let parents=Dictionary(uniqueKeysWithValues:context.scope.map{($0.id,$0.parentID)})
                    func depth(_ id:String)->Int {
                        var current=id,seen=Set<String>()
                        while let parent=parents[current] ?? nil,seen.insert(current).inserted {current=parent}
                        return seen.count
                    }
                    let selected=context.scope.filter{context.movingThreads.contains($0.id)}.sorted{(depth($0.id),$0.id)>(depth($1.id),$1.id)}
                    for item in selected {
                        let response=try connection.request("thread/read",["threadId":item.id,"includeTurns":false])
                        guard let row=response["thread"] as? JSONObject,let path=row["path"] as? String else{throw AppError.message("이동할 대화의 이력 위치를 확인하지 못했습니다.")}
                        let archivedPath:String
                        if path.contains("/archived_sessions/"){archivedPath=path}
                        else {
                            _=try connection.request("thread/archive",["threadId":item.id],classifyError:true)
                            archivedPath=URL(fileURLWithPath:plan.sourceHome).appendingPathComponent("archived_sessions").appendingPathComponent(URL(fileURLWithPath:path).lastPathComponent).path
                        }
                        _=try CodexMigrationRetirement.capture(home:plan.sourceHome,threadID:item.id,rolloutPath:archivedPath)
                        archived[item.id]=archivedPath
                    }
                }
                context.archivedPaths=archived;context.quiesced=true
                try await save(context)
            }
            if context.restartServer==false {
                guard try peer(home:plan.sourceHome)==context.originalServer else{throw AppError.message("독립 세션을 연결할 원래 서버가 바뀌었습니다.")}
                return context
            }
            if let current=try peer(home:plan.sourceHome) {
                if current==context.originalServer {
                    let result=try cli.run(["app-server","daemon","restart"],timeout:375)
                    guard result.status==0 else{throw AppError.message("원래 Codex 서버의 재시작 응답을 확인하지 못했습니다. 저장한 단계에서 연결 상태를 다시 확인합니다.")}
                }
            } else {
                // Native start owns stale-socket cleanup and daemon locks. The
                // app neither deletes socket files nor repeats an uncertain stop.
                let result=try cli.run(["app-server","daemon","start"],timeout:90)
                guard result.status==0 else{throw AppError.message("종료된 Codex 서버의 시작 결과를 확인하지 못했습니다.")}
            }
            guard try restarted(context,plan:plan) else{throw AppError.message("원래 Codex 서버의 종료를 기다리고 있습니다. 복원 명령은 아직 전달하지 않았습니다.")}
            return context
        }
    }

    static func transfer(_ context:CodexCohortRestartContext,plan:CodexCohortRestartPlan,database:String) async throws {
        if plan.sourceHome==plan.destinationHome{return}
        try await background {
            guard try restarted(context,plan:plan),context.quiesced==true else{throw AppError.message("원래 서버의 작업 정리·재시작이 끝나지 않았습니다.")}
            _=try CodexOfficialExecutable.verifyServer(CodexQueueConnection(home:plan.destinationHome))
            let service=try CodexOfficialConversationTransfer(store:AuditStore(path:database))
            for thread in context.movingThreads.sorted() {
                guard let id=context.transfers[thread],let path=context.archivedPaths?[thread] else{throw AppError.message("이동할 대화의 저장 기록이 없습니다.")}
                if try service.completed(id:id){continue}
                // A failed read is not absence. Only a genuinely missing state
                // permits preparing a new request; other errors remain errors.
                let journal=try CodexMigrationJournal(store:AuditStore(path:database))
                if try journal.load(id:id.uuidString.lowercased())==nil {
                    try service.prepare(id:id,sourceHome:plan.sourceHome,destinationHome:plan.destinationHome,threadID:thread,archivedPath:path,checkpoint:{try Task.checkCancellation()})
                }
                _=try service.advance(id:id,checkpoint:{try Task.checkCancellation()})
            }
            // Native unarchive updates the official index and moves the file.
            // Later TUI launch selects the UUID, never the obsolete archive path.
            let connection=try CodexQueueConnection(home:plan.destinationHome)
            for thread in context.movingThreads.sorted() {
                guard let id=context.transfers[thread] else{throw AppError.message("대화 이전 요청의 식별자가 없습니다.")}
                let state=try service.state(id:id)
                guard let relative=state.imported?.importedFiles.first?.relativePath ?? state.returnTo?.originalArchivePath else{throw AppError.message("이전한 대화의 보관 위치가 없습니다.")}
                let archive=URL(fileURLWithPath:state.destinationHome).appendingPathComponent(relative).path
                var info=stat()
                if lstat(archive,&info)==0 { _=try connection.request("thread/unarchive",["threadId":thread],classifyError:true) }
                else if errno != ENOENT {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
                let response=try connection.request("thread/read",["threadId":thread,"includeTurns":false])
                guard let row=response["thread"] as? JSONObject,let path=row["path"] as? String else{throw AppError.message("목적지의 대화 이력을 확인하지 못했습니다.")}
                if path.contains("/archived_sessions/"){_=try connection.request("thread/unarchive",["threadId":thread],classifyError:true)}
                // Let the original server initialize its own paginated store;
                // this read neither selects a TUI nor starts a model turn.
                _=try connection.request("thread/turns/list",["threadId":thread,"limit":1,"itemsView":"notLoaded"])
                let sourceLease=try CodexOfficialWriterLease(home:plan.sourceHome,threadIDs:[thread])
                let targetLease=try CodexOfficialWriterLease(home:plan.destinationHome,threadIDs:[thread])
                defer{sourceLease.close();targetLease.close()}
                try CodexThreadHistoryTransfer.install(id:id,sourceHome:plan.sourceHome,destinationHome:plan.destinationHome,
                    threadID:thread,replacingRetired:state.returnTo != nil,store:AuditStore(path:database),checkpoint:{
                        try Task.checkCancellation()
                        try sourceLease.verifyScope(home:plan.sourceHome,threadIDs:[thread])
                        try targetLease.verifyScope(home:plan.destinationHome,threadIDs:[thread])
                    })
            }
        }
    }
    static func transferred(_ context:CodexCohortRestartContext,plan:CodexCohortRestartPlan,database:String) async throws->Bool {
        if plan.sourceHome==plan.destinationHome{return true}
        return try await background {
            let service=try CodexOfficialConversationTransfer(store:AuditStore(path:database))
            for thread in context.movingThreads {
                guard let id=context.transfers[thread],try service.completed(id:id) else{return false}
                let state=try service.state(id:id)
                guard let relative=state.imported?.importedFiles.first?.relativePath ?? state.returnTo?.originalArchivePath else{return false}
                var info=stat()
                if lstat(URL(fileURLWithPath:state.destinationHome).appendingPathComponent(relative).path,&info)==0{return false}
                guard errno==ENOENT else{throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
                let connection=try CodexQueueConnection(home:plan.destinationHome)
                _=try CodexOfficialExecutable.verifyServer(connection)
                let reply=try connection.request("thread/read",["threadId":thread,"includeTurns":false])
                guard let row=reply["thread"] as? JSONObject,let path=row["path"] as? String,!path.contains("/archived_sessions/") else{return false}
                guard try CodexThreadHistoryTransfer.completed(id:id,sourceHome:plan.sourceHome,destinationHome:plan.destinationHome,
                    threadID:thread,store:AuditStore(path:database)) else{return false}
            }
            return true
        }
    }

    static func resumeGoals(_ context:CodexCohortRestartContext,plan:CodexCohortRestartPlan) async throws {
        try await background {
            let parents=Dictionary(uniqueKeysWithValues:context.scope.map{($0.id,$0.parentID)})
            func depth(_ id:String)->Int {
                var current=id,seen=Set<String>()
                while let next=parents[current] ?? nil,seen.insert(current).inserted {current=next}
                return seen.count
            }
            let goals=context.originalGoals.filter{$0.value.status == .active}.sorted {depth($0.key)==depth($1.key) ? $0.key<$1.key:depth($0.key)>depth($1.key)}
            for (id,original) in goals {
                try Task.checkCancellation()
                let home=context.movingThreads.contains(id) ? plan.destinationHome:plan.sourceHome
                let connection=try CodexQueueConnection(home:home)
                _=try CodexOfficialExecutable.verifyServer(connection)
                let metadata=try connection.request("thread/read",["threadId":id,"includeTurns":false])["thread"] as? JSONObject
                if (metadata?["status"] as? JSONObject)?["type"] as? String=="notLoaded" {
                    // A child has no selected TUI to load it after a cold
                    // handoff. Attest its preserved Goal before attaching the
                    // original lifecycle; never infer identity from its PID.
                    guard let goal=try CodexSessionAttachment.goalIfPresent(home:home,threadID:id),
                          goal.instanceID==original.instanceID,goal.objective==original.objective,
                          goal.tokenBudget==original.tokenBudget,goal.createdAt==original.createdAt,
                          goal.tokensUsed>=original.tokensUsed,goal.timeUsedSeconds>=original.timeUsedSeconds else{throw AppError.message("휴면 하위 대화의 원래 Goal을 확인하지 못했습니다.")}
                    if goal.status != .paused && goal.status != .active {continue}
                    _=try connection.request("thread/resume",["threadId":id,"excludeTurns":true],classifyError:true)
                }
                let current=try CodexAccountTransitionLocal.thread(connection,id:id,home:home,allowSubagent:true)
                guard let goal=current.goal,goal.instanceID==original.instanceID,goal.objective==original.objective,
                      goal.tokenBudget==original.tokenBudget,goal.createdAt==original.createdAt,
                      goal.tokensUsed>=original.tokensUsed,goal.timeUsedSeconds>=original.timeUsedSeconds else{throw AppError.message("복원할 Goal이 바뀌어 재개하지 않았습니다.")}
                if goal.status != .paused && goal.status != .active {continue}
                if let owner=current.subagent {
                    let target=CodexReplyTarget(executable:context.launch.executable,home:home,threadID:owner.rootThreadID)
                    let expected=CodexSubagentGoal(rootThreadID:owner.rootThreadID,threadID:id,parentThreadID:owner.parentThreadID,goal:goal,executionState:current.active ? "active":"idle",turnID:current.turnID)
                    if goal.status == .paused {
                        _=try await CodexSubagentGoalTransport.change(target:target,cwd:owner.rootCwd,expected:expected,action:.resume,authorize:{try Task.checkCancellation()})
                    } else {_=try await CodexSubagentGoalTransport.settleRecovered(target:target,cwd:owner.rootCwd,expected:expected,authorize:{try Task.checkCancellation()})}
                } else {
                    if goal.status == .paused {_=try connection.request("thread/goal/set",["threadId":id,"status":"active","origin":"automatic"],classifyError:true)}
                    _=try connection.request("thread/resume",["threadId":id,"excludeTurns":true],classifyError:true)
                }
            }
        }
    }
}
