import Foundation
import ScreenCaptureKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

public struct TestScreenSource: Codable, Equatable, Sendable {
    public var id: UInt32
    public var scope: String
    public var title: String
    public var width: Int
    public var height: Int
    public var ownerPID: Int32?
    public var ownerBundleID: String?
    public var ownerStarted:String?
    public init(id: UInt32, scope: String, title: String, width: Int, height: Int, ownerPID: Int32? = nil, ownerBundleID: String? = nil, ownerStarted:String? = nil) {
        self.id = id; self.scope = scope; self.title = title; self.width = width; self.height = height; self.ownerPID = ownerPID; self.ownerBundleID = ownerBundleID;self.ownerStarted=ownerStarted
    }
}

public struct TestScreenShare: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var source: TestScreenSource
    public var expiresAt: Date
}

public struct TestScreenFrame: Codable, Sendable {
    public var shareID: String
    public var observedAt: Date
    public var image: TerminalNativeImage
    public var controlVersion:Int?=1
}

/// Only explicit MCP/web start calls authorize a source. No captures occur in discovery or ordinary terminal mode.
@MainActor public final class TestScreenSharing {
    private struct Capture {
        let id=UUID()
        let task:Task<TestScreenFrame,Error>
    }
    private struct Entry {
        var owner: String
        var share: TestScreenShare
        var frame: TestScreenFrame?
        var imageTag:String?
        var task:Capture?
        var expiry: Task<Void, Never>?
    }
    private var entries: [String: Entry] = [:]
    private var generation: UInt64 = 0
    private let permission: @MainActor (Bool) -> Bool
    private let readSources: @Sendable () async throws -> [TestScreenSource]
    private let capture: @Sendable (TestScreenSource) async throws -> TerminalNativeImage
    private let interactiveCapture:@Sendable(TestScreenSource) async throws ->TerminalNativeImage
    public let remoteControl:RemoteScreenControl
    public init(permission: (@MainActor (Bool) -> Bool)? = nil,
                sources: (@Sendable () async throws -> [TestScreenSource])? = nil,
                capture: (@Sendable (TestScreenSource) async throws -> TerminalNativeImage)? = nil,
                interactiveCapture:(@Sendable(TestScreenSource) async throws ->TerminalNativeImage)? = nil,
                remoteControl:RemoteScreenControl? = nil) {
        self.permission = permission ?? { request in CGPreflightScreenCaptureAccess() || request && CGRequestScreenCaptureAccess() }
        self.readSources = sources ?? { try await Self.sources() }
        self.capture = capture ?? { try await Self.capture($0) }
        self.interactiveCapture=interactiveCapture ?? capture ?? {try await Self.capture($0,interactive:true)}
        self.remoteControl=remoteControl ?? RemoteScreenControl()
    }
    public var active: [TestScreenShare] {
        expire(); return entries.values.map(\.share).sorted { $0.expiresAt < $1.expiresAt }
    }
    public func availableSources() async throws -> [TestScreenSource] {
        guard permission(false) else { throw RemoteHTTPError(403, "Mac의 시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 녹음에서 AutoApprove를 허용해주세요.") }
        return try await readSources()
    }
    public func start(_ object: JSONObject, owner: String) async throws -> TestScreenShare {
        expire()
        let startingGeneration = generation
        guard entries.count < 8 else { throw RemoteHTTPError(409, "이미 공유 중인 화면을 먼저 종료해주세요.") }
        guard permission(true) else { throw RemoteHTTPError(403, "Mac에서 AutoApprove의 화면 녹음 권한을 허용한 뒤 다시 공유를 시작해주세요.") }
        let scope = object["scope"] as? String ?? "display"
        let seconds = object["durationSeconds"] as? Int ?? 600
        guard ["display", "window"].contains(scope), (30...900).contains(seconds) else {
            throw RemoteHTTPError(400, "화면 공유 범위와 30~900초의 제한 시간을 지정해주세요.")
        }
        let sources = try await readSources()
        guard generation == startingGeneration else { throw RemoteHTTPError(409, "화면 공유 연결이 종료되었습니다. 다시 공유를 시작해주세요.") }
        guard entries.count < 8 else { throw RemoteHTTPError(409, "이미 공유 중인 화면을 먼저 종료해주세요.") }
        if let value = object["sourceID"] {
            guard let number = value as? NSNumber, number.doubleValue >= 1, number.doubleValue <= Double(UInt32.max), number.doubleValue.rounded() == number.doubleValue else { throw RemoteHTTPError(400, "화면 ID가 올바르지 않습니다.") }
        }
        let supplied = (object["sourceID"] as? NSNumber)?.uint32Value
        let preferred = scope == "display" ? CGMainDisplayID() : 0
        guard var source = sources.first(where: { $0.scope == scope && $0.id == (supplied ?? preferred) })
                ?? (supplied == nil && scope == "display" ? sources.first(where: { $0.scope == scope }) : nil) else {
            throw RemoteHTTPError(404, "공유할 화면을 찾지 못했습니다. list_screens로 현재 화면을 확인해주세요.")
        }
        if source.scope=="window",source.ownerStarted==nil,let pid=source.ownerPID {source.ownerStarted=(try? ProcessDiscovery.read(pid:pid))?.first?.started}
        let title = object["title"] as? String ?? source.title
        guard !title.isEmpty, title.utf8.count <= 1000 else { throw RemoteHTTPError(400, "공유 제목이 올바르지 않습니다.") }
        let share = TestScreenShare(id: UUID().uuidString, title: title, source: source, expiresAt: Date().addingTimeInterval(Double(seconds)))
        // Record the capability without retaining an image; the phone explicitly opens the viewer.
        entries[share.id] = Entry(owner: owner, share: share)
        entries[share.id]?.expiry = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000) } catch { return }
            try? self?.stop(share.id)
        }
        return share
    }
    public func stop(_ id: String, owner: String? = nil) throws {
        guard let entry = entries[id], owner == nil || owner == entry.owner else { throw RemoteHTTPError(404, "공유가 종료되었거나 이 MCP 연결의 공유가 아닙니다.") }
        remoteControl.revoke(shareID:id)
        let removed = entries.removeValue(forKey: id); removed?.task?.task.cancel(); removed?.expiry?.cancel()
    }
    public func stopAll(owner: String? = nil) {
        if owner == nil { generation &+= 1 }
        for id in Array(entries.keys) where owner == nil || entries[id]?.owner == owner { try? stop(id, owner: owner) }
    }
    public func frame(_ id: String) async throws -> TestScreenFrame {
        try Task.checkCancellation()
        expire()
        guard let entry = entries[id] else { throw RemoteHTTPError(410, "화면 공유가 종료되었습니다.") }
        guard permission(false) else {remoteControl.revoke(shareID:id);throw RemoteHTTPError(403, "Mac의 화면 녹음 권한이 필요합니다.") }
        let interactive=remoteControl.isControlling(id)
        if let frame = entry.frame, Date().timeIntervalSince(frame.observedAt) < (interactive ? 0.12:0.5) { return frame }
        let work:Capture
        if let existing = entry.task { work = existing }
        else {
            let capture = interactive ? self.interactiveCapture:self.capture, source = entry.share.source
            work=Capture(task:Task {
                let image=try await capture(source);try Task.checkCancellation();try image.validate()
                return TestScreenFrame(shareID:id,observedAt:Date(),image:image)
            });entries[id]?.task=work
        }
        do {
            let frame=try await work.task.value;try Task.checkCancellation()
            guard let current = entries[id], current.share == entry.share, current.share.expiresAt > Date() else {
                throw RemoteHTTPError(410, "화면 공유가 종료되었습니다.")
            }
            if current.task?.id==work.id {entries[id]?.task=nil}
            if let newer=current.frame,newer.observedAt>=frame.observedAt {return newer}
            let image=frame.image
            if current.frame?.image != image || current.imageTag==nil {
                var digest=SHA256();digest.update(data:Data("\(id):\(image.width)x\(image.height):1:".utf8));digest.update(data:Data(image.data.utf8))
                entries[id]?.imageTag="W/\"screen-"+digest.finalize().map {String(format:"%02x",$0)}.joined()+"\""
            }
            entries[id]?.frame = frame
            return frame
        } catch {
            // A cancelled read-only viewer does not own another viewer's input
            // lease, nor a newer capture that has already replaced this work.
            if !(error is CancellationError) || !Task.isCancelled {remoteControl.revoke(shareID:id)}
            if entries[id]?.task?.id==work.id {entries[id]?.task=nil}
            throw error
        }
    }
    /// Revalidate capture/permission first. A weak tag describes the displayed
    /// image; the current observation time travels independently on every reply.
    public func response(_ id:String,entityTag:String?) async throws ->RemoteHTTPResponse {
        let frame=try await frame(id)
        guard let tag=entries[id]?.imageTag else {throw RemoteHTTPError(410,"화면 공유가 종료되었습니다.")}
        var response:RemoteHTTPResponse
        if entityTag==tag {response=RemoteHTTPResponse(status:304,body:Data())} else {response=try .json(frame)}
        response.entityTag=tag;response.observedAt=frame.observedAt
        return response
    }
    public func beginControl(_ object:JSONObject) throws ->RemoteScreenControlGrant {
        let entry=try controlEntry(object);return try remoteControl.begin(share:entry.share,frame:entry.frame)
    }
    public func bindControl(_ object:JSONObject) throws ->JSONObject {
        let entry=try controlEntry(object);try remoteControl.validate(object,frame:entry.frame);return ["bound":true,"mode":"screen"]
    }
    public func screenInput(_ object:JSONObject) throws ->JSONObject {
        let entry=try controlEntry(object);return try remoteControl.input(object,frame:entry.frame)
    }
    public func heartbeatControl(_ object:JSONObject) throws ->JSONObject {
        let entry=try controlEntry(object);try remoteControl.heartbeat(object,frame:entry.frame);return ["active":true]
    }
    public func endControl(_ object:JSONObject) throws ->JSONObject {try remoteControl.end(object);return ["ended":true]}
    private func controlEntry(_ object:JSONObject) throws ->Entry {
        expire()
        guard let id=object["shareID"] as? String,let entry=entries[id] else {throw RemoteHTTPError(410,"화면 공유가 종료되었습니다.")}
        guard permission(false) else {remoteControl.revoke(shareID:id);throw RemoteHTTPError(403,"Mac의 화면 녹음 권한이 필요합니다.")}
        return entry
    }
    private func expire() {
        for id in Array(entries.keys) where entries[id]!.share.expiresAt <= Date() { try? stop(id) }
    }
    nonisolated private static func sources() async throws -> [TestScreenSource] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return content.displays.map { TestScreenSource(id: $0.displayID, scope: "display", title: "Mac 전체 화면 \($0.displayID)", width: $0.width, height: $0.height) }
            + content.windows.filter { $0.windowLayer == 0 && $0.isOnScreen && $0.owningApplication != nil }.map {
                TestScreenSource(id: $0.windowID, scope: "window", title: String(($0.title ?? $0.owningApplication!.applicationName).prefix(300)),
                    width: Int($0.frame.width), height: Int($0.frame.height), ownerPID: $0.owningApplication!.processID, ownerBundleID: $0.owningApplication!.bundleIdentifier)
            }
    }
    nonisolated private static func capture(_ source: TestScreenSource,interactive:Bool = false) async throws -> TerminalNativeImage {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let filter: SCContentFilter
        let size:CGSize
        if source.scope == "display" {
            guard let display = content.displays.first(where: { $0.displayID == source.id }) else { throw RemoteHTTPError(410, "공유할 디스플레이가 연결 해제되었습니다.") }
            filter = SCContentFilter(display: display, excludingWindows: [])
            size=CGSize(width:display.width,height:display.height)
        } else {
            guard let window = content.windows.first(where: { $0.windowID == source.id && $0.owningApplication?.processID == source.ownerPID && $0.owningApplication?.bundleIdentifier == source.ownerBundleID }), window.isOnScreen else {
                throw RemoteHTTPError(410, "공유할 Mac 창이 닫혔거나 바뀌었습니다.")
            }
            if let started=source.ownerStarted,let pid=source.ownerPID,(try? ProcessDiscovery.read(pid:pid))?.first?.started != started {throw RemoteHTTPError(410,"공유할 Mac 창의 소유 실행이 바뀌었습니다.")}
            filter = SCContentFilter(desktopIndependentWindow: window)
            size=window.frame.size
        }
        guard size.width.isFinite,size.height.isFinite,size.width>0,size.height>0 else {throw RemoteHTTPError(410,"공유할 화면의 현재 크기를 확인하지 못했습니다.")}
        let scale = min(1, (interactive ? 1280.0:2048.0) / max(size.width,size.height))
        let config = SCStreamConfiguration()
        config.width=max(1,Int(size.width*scale));config.height=max(1,Int(size.height*scale))
        config.showsCursor = true; config.capturesAudio = false; config.scalesToFit = true
        config.ignoreShadowsSingleWindow=true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw RemoteHTTPError(502, "공유 이미지를 만들지 못했습니다.") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: interactive ? 0.55:0.65] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= 750_000 else { throw RemoteHTTPError(502, "공유 화면이 너무 큽니다. 창 하나를 지정해 다시 공유해주세요.") }
        return TerminalNativeImage(data: (data as Data).base64EncodedString(), width: image.width, height: image.height)
    }
}
