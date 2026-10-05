import Foundation
import ScreenCaptureKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public struct TestScreenSource: Codable, Equatable, Sendable {
    public var id: UInt32
    public var scope: String
    public var title: String
    public var width: Int
    public var height: Int
    public var ownerPID: Int32?
    public var ownerBundleID: String?
    public init(id: UInt32, scope: String, title: String, width: Int, height: Int, ownerPID: Int32? = nil, ownerBundleID: String? = nil) {
        self.id = id; self.scope = scope; self.title = title; self.width = width; self.height = height; self.ownerPID = ownerPID; self.ownerBundleID = ownerBundleID
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
}

/// Only explicit MCP start calls authorize a source. No captures occur in discovery or ordinary terminal mode.
@MainActor public final class TestScreenSharing {
    private struct Entry {
        var owner: String
        var share: TestScreenShare
        var frame: TestScreenFrame?
        var task: Task<TerminalNativeImage, Error>?
        var expiry: Task<Void, Never>?
    }
    private var entries: [String: Entry] = [:]
    private var generation: UInt64 = 0
    private let permission: @MainActor (Bool) -> Bool
    private let readSources: @Sendable () async throws -> [TestScreenSource]
    private let capture: @Sendable (TestScreenSource) async throws -> TerminalNativeImage
    public init(permission: (@MainActor (Bool) -> Bool)? = nil,
                sources: (@Sendable () async throws -> [TestScreenSource])? = nil,
                capture: (@Sendable (TestScreenSource) async throws -> TerminalNativeImage)? = nil) {
        self.permission = permission ?? { request in CGPreflightScreenCaptureAccess() || request && CGRequestScreenCaptureAccess() }
        self.readSources = sources ?? { try await Self.sources() }
        self.capture = capture ?? { try await Self.capture($0) }
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
        guard let source = sources.first(where: { $0.scope == scope && $0.id == (supplied ?? preferred) })
                ?? (supplied == nil && scope == "display" ? sources.first(where: { $0.scope == scope }) : nil) else {
            throw RemoteHTTPError(404, "공유할 화면을 찾지 못했습니다. list_screens로 현재 화면을 확인해주세요.")
        }
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
        let removed = entries.removeValue(forKey: id); removed?.task?.cancel(); removed?.expiry?.cancel()
    }
    public func stopAll(owner: String? = nil) {
        if owner == nil { generation &+= 1 }
        for id in Array(entries.keys) where owner == nil || entries[id]?.owner == owner { try? stop(id, owner: owner) }
    }
    public func frame(_ id: String) async throws -> TestScreenFrame {
        expire()
        guard let entry = entries[id] else { throw RemoteHTTPError(410, "화면 공유가 종료되었습니다.") }
        guard permission(false) else { throw RemoteHTTPError(403, "Mac의 화면 녹음 권한이 필요합니다.") }
        if let frame = entry.frame, Date().timeIntervalSince(frame.observedAt) < 0.5 { return frame }
        let task: Task<TerminalNativeImage, Error>
        if let existing = entry.task { task = existing }
        else {
            let capture = self.capture, source = entry.share.source
            task = Task { try await capture(source) }; entries[id]?.task = task
        }
        do {
            let image = try await task.value; try image.validate()
            guard !Task.isCancelled, let current = entries[id], current.share == entry.share, current.share.expiresAt > Date() else {
                throw RemoteHTTPError(410, "화면 공유가 종료되었습니다.")
            }
            let frame = TestScreenFrame(shareID: id, observedAt: Date(), image: image)
            entries[id]?.frame = frame; entries[id]?.task = nil
            return frame
        } catch { entries[id]?.task = nil; throw error }
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
    nonisolated private static func capture(_ source: TestScreenSource) async throws -> TerminalNativeImage {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let filter: SCContentFilter
        if source.scope == "display" {
            guard let display = content.displays.first(where: { $0.displayID == source.id }) else { throw RemoteHTTPError(410, "공유할 디스플레이가 연결 해제되었습니다.") }
            filter = SCContentFilter(display: display, excludingWindows: [])
        } else {
            guard let window = content.windows.first(where: { $0.windowID == source.id && $0.owningApplication?.processID == source.ownerPID && $0.owningApplication?.bundleIdentifier == source.ownerBundleID }), window.isOnScreen else {
                throw RemoteHTTPError(410, "공유할 Mac 창이 닫혔거나 바뀌었습니다.")
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
        }
        let scale = min(1, 2048 / Double(max(source.width, source.height)))
        let config = SCStreamConfiguration()
        config.width = max(1, Int(Double(source.width) * scale)); config.height = max(1, Int(Double(source.height) * scale))
        config.showsCursor = true; config.capturesAudio = false; config.scalesToFit = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw RemoteHTTPError(502, "공유 이미지를 만들지 못했습니다.") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.65] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= 750_000 else { throw RemoteHTTPError(502, "공유 화면이 너무 큽니다. 창 하나를 지정해 다시 공유해주세요.") }
        return TerminalNativeImage(data: (data as Data).base64EncodedString(), width: image.width, height: image.height)
    }
}
