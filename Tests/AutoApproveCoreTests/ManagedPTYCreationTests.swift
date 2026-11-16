#if DEBUG
import Foundation
@testable import AutoApproveCore

private final class PTYCreationGate:@unchecked Sendable {
    let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
    private let lock=NSLock()
    private var created:[ManagedPTY]=[]
    var terminals:[ManagedPTY] {lock.lock();defer{lock.unlock()};return created}
    func waitForEntry() async ->Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos:.userInitiated).async { [self] in
                continuation.resume(returning:entered.wait(timeout:.now()+5) == .success)
            }
        }
    }
    func make(_ cwd:String,_ program:String,_ command:[String]?,_ columns:Int,_ rows:Int,_ environment:[String:String]?) throws ->ManagedPTY {
        entered.signal()
        guard release.wait(timeout:.now()+8) == .success else {throw AppError.message("Owned PTY creation gate timed out")}
        let terminal=try ManagedPTY(cwd:cwd,program:"shell",command:["/bin/cat"],columns:columns,rows:rows,environment:environment)
        lock.lock();created.append(terminal);lock.unlock();return terminal
    }
}

extension ApprovalTests {
    func testPTYCreationAdmissionAndStopDoNotBlockReaders() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-pty-admission-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let gate=PTYCreationGate()
        let manager=ManagedPTYManager(environment:["HOME":root.path,"ZDOTDIR":root.path,"PATH":"/usr/bin:/bin"],factory:{try gate.make($0,$1,$2,$3,$4,$5)})
        defer {for _ in 0..<9 {gate.release.signal()};manager.stop()}
        let tasks=(0..<8).map{_ in Task.detached {try manager.create(cwd:root.path,program:"shell",columns:80,rows:24)}}
        for _ in 0..<8 {
            let entered=await gate.waitForEntry()
            try expect(entered,"Every pending creation reserves one slot without holding the inventory lock")
        }
        let started=ContinuousClock.now
        try expect(manager.inventory.isEmpty)
        try expectThrows(manager.create(cwd:root.path,program:"shell",columns:80,rows:24))
        manager.stop()
        try expect(started.duration(to:.now) < .seconds(1),"Inventory, admission and stop must not wait for slow CLI preparation")
        for _ in 0..<8 {gate.release.signal()}
        for task in tasks {
            switch await task.result {
            case .failure(let error):try expect(error is CancellationError)
            case .success:throw AppError.message("A PTY created across stop was registered")
            }
        }
        try expect(manager.inventory.isEmpty)
        try expect(gate.terminals.allSatisfy{!$0.isRunning},"All owned terminals created across stop must close")
        gate.release.signal()
        let next=try await Task.detached {try manager.create(cwd:root.path,program:"shell",columns:80,rows:24)}.value
        try expectEqual(manager.inventory.map(\.ptyID),[next.ptyID],"Released reservations must permit a later normal creation")
    }

    func testPTYCreationCancellationLeavesMainActorResponsive() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-pty-engine-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let gate=PTYCreationGate()
        let manager=ManagedPTYManager(environment:["HOME":root.path,"ZDOTDIR":root.path,"PATH":"/usr/bin:/bin"],factory:{try gate.make($0,$1,$2,$3,$4,$5)})
        let engine=try ApprovalEngine(paths:AppPaths(directory:root.appendingPathComponent("profile")),processReader:{[]},managedPTY:manager)
        defer {gate.release.signal();engine.stop()}
        let start=ContinuousClock.now
        let request=Task {try await engine.createPTY(["cwd":root.path,"program":"shell"])}
        let entered=await gate.waitForEntry()
        try expect(entered)
        try expect(start.duration(to:.now) < .seconds(1),"The main actor must remain available while creation is blocked")
        request.cancel();gate.release.signal()
        switch await request.result {
        case .failure(let error):try expect(error is CancellationError)
        case .success:throw AppError.message("Cancelled engine creation returned a terminal")
        }
        try expect(manager.inventory.allSatisfy{$0.exitCode != nil})
        try expect(gate.terminals.allSatisfy{!$0.isRunning})
    }
}
#endif
