import Foundation
import Network
import AutoApproveCore

extension ApprovalTests {
    @MainActor func testPeerCachePrunesExpiredRemovedAndPreservesPending() async throws {
        let cache = RemotePeerStateCache(), endpoint = NWEndpoint.hostPort(host:"127.0.0.1",port:8765)
        let now = Date(), token = UUID()
        func view(_ id: String, online: Bool) throws -> RemoteNodeView {
            try JSONDecoder().decode(RemoteNodeView.self,from:JSONSerialization.data(withJSONObject:["id":id,"name":"QA","local":false,"online":online]))
        }
        let completeView = try view("complete",online:true), pendingView = try view("pending",online:false), removedView = try view("removed",online:false)
        let finished = Task { completeView }
        cache.insert(finished,id:"complete",token:token,endpoint:endpoint)
        cache.finish(id:"complete",token:token,endpoint:endpoint,expires:now.addingTimeInterval(1))
        let pending = Task { () -> RemoteNodeView in
            try? await Task.sleep(for:.seconds(30)); return pendingView
        }
        cache.insert(pending,id:"pending",token:UUID(),endpoint:endpoint)
        cache.insert(Task { removedView },id:"removed",token:UUID(),endpoint:endpoint)
        cache.prune(liveIDs:["complete","pending"],at:now)
        try expectEqual(cache.count,2); try expect(!pending.isCancelled)
        cache.prune(liveIDs:["complete","pending"],at:now.addingTimeInterval(2))
        try expectEqual(cache.count,1); try expect(!pending.isCancelled)
        let replacement = UUID()
        cache.insert(pending,id:"pending",token:replacement,endpoint:endpoint)
        cache.finish(id:"pending",token:UUID(),endpoint:endpoint,expires:now)
        cache.prune(liveIDs:["pending"],at:now.addingTimeInterval(60))
        try expectEqual(cache.count,1,"An old completion cannot expire a newer in-flight read")
        cache.prune(liveIDs:[],at:now); try expectEqual(cache.count,0); try expect(pending.isCancelled)
        _ = await pending.value
    }

    @MainActor func testLANUpdateDownloadResumesOnlyMatchingManifest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:directory) }
        let bytes = Data((0..<LANUpdateManifest.chunkSize*2+17).map { UInt8($0 % 251) })
        let manifest = LANUpdateManifest(nodeID:UUID().uuidString,release:RemoteWebVersion(version:"0.2.60",build:75),size:bytes.count,sha256:LANUpdateInstallation.digest(bytes))
        var offsets: [Int] = []
        let read: @MainActor @Sendable (String) async throws -> RemoteHTTPResponse = { path in
            let offset = Int(URLComponents(string:"http://localhost"+path)!.queryItems!.first(where:{$0.name=="offset"})!.value!)!
            offsets.append(offset)
            if offset == LANUpdateManifest.chunkSize { throw RemoteHTTPError(504,"QA interruption") }
            return RemoteHTTPResponse(body:bytes.subdata(in:offset..<min(offset+LANUpdateManifest.chunkSize,bytes.count)))
        }
        do { _ = try await LANUpdateDownload.download(manifest:manifest,directory:directory,read:read); throw AppError.message("Interruption was not reported") }
        catch let error as RemoteHTTPError { try expectEqual(error.diagnostics?["offset"],String(LANUpdateManifest.chunkSize)) }
        offsets.removeAll()
        let resumed: @MainActor @Sendable (String) async throws -> RemoteHTTPResponse = { path in
            let offset = Int(URLComponents(string:"http://localhost"+path)!.queryItems!.first(where:{$0.name=="offset"})!.value!)!
            offsets.append(offset); return RemoteHTTPResponse(body:bytes.subdata(in:offset..<min(offset+LANUpdateManifest.chunkSize,bytes.count)))
        }
        let archive = try await LANUpdateDownload.download(manifest:manifest,directory:directory,read:resumed)
        try expectEqual(offsets,[LANUpdateManifest.chunkSize,LANUpdateManifest.chunkSize*2]); try expectEqual(try Data(contentsOf:archive),bytes)
        var different = manifest; different.nodeID = UUID().uuidString; offsets.removeAll()
        _ = try await LANUpdateDownload.download(manifest:different,directory:directory,read:resumed)
        try expectEqual(offsets.first,0,"An address or matching checksum cannot authorize a different node's resume")
        try expectEqual((try FileManager.default.attributesOfItem(atPath:archive.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
    }

    @MainActor func testLANUpdateDownloadRejectsCorruptCompletedResume() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-resume-corrupt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:directory) }
        let bytes = Data(repeating:7,count:LANUpdateManifest.chunkSize+1)
        let manifest = LANUpdateManifest(nodeID:UUID().uuidString,release:RemoteWebVersion(version:"0.2.60",build:75),size:bytes.count,sha256:LANUpdateInstallation.digest(bytes))
        let read: @MainActor @Sendable (String) async throws -> RemoteHTTPResponse = { path in
            let offset = Int(URLComponents(string:"http://localhost"+path)!.queryItems!.first(where:{$0.name=="offset"})!.value!)!
            return RemoteHTTPResponse(body:bytes.subdata(in:offset..<min(offset+LANUpdateManifest.chunkSize,bytes.count)))
        }
        let archive = try await LANUpdateDownload.download(manifest:manifest,directory:directory,read:read)
        try Data(repeating:8,count:bytes.count).write(to:archive)
        do { _ = try await LANUpdateDownload.download(manifest:manifest,directory:directory,read:read); throw AppError.message("Corrupt resume was accepted") }
        catch { try expect(error.localizedDescription != "Corrupt resume was accepted") }
        try expect(!FileManager.default.fileExists(atPath:archive.path))
        try expect(LANUpdateRetryPolicy.delay(failures:1) < 10); try expectEqual(LANUpdateRetryPolicy.delay(failures:100),60)
    }

    @MainActor func testMouseReportsDistinctAXAndEventPermissions() throws {
        let fake = FakeMouseActivity(); fake.permission = false
        var control = fake.control
        control.diagnostics = { MouseActivityPermissions(accessibilityGranted:true,eventPostingGranted:fake.permission,bundleIdentifier:"local.autoapprove.mac",executable:"/Applications/AutoApprove.app/Contents/MacOS/AutoApproveApp") }
        let mouse = MouseActivity(control:control); mouse.setEnabled(true)
        try expectEqual(mouse.status.permissions?.accessibilityGranted,true)
        try expectEqual(mouse.status.permissions?.eventPostingGranted,false)
        try expect(mouse.status.detail.contains("손쉬운 사용은 허용"))
        fake.now += 60; mouse.evaluate(); try expectEqual(fake.pulses.count,0)
        fake.permission = true; fake.now += 60; mouse.evaluate()
        try expectEqual(mouse.status.permissions?.eventPostingGranted,true); try expectEqual(fake.pulses.count,1)
        fake.session = .locked; fake.now += 60; mouse.evaluate(); try expectEqual(fake.pulses.count,1)
        mouse.stop()
    }
}
