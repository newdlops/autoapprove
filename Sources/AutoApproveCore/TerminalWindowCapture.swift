import Foundation
import AppKit
import ApplicationServices
import CoreServices
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

public struct TerminalNativeImage: Codable, Equatable, Sendable {
    public var data: String
    public var width: Int
    public var height: Int
    public init(data: String, width: Int, height: Int) { self.data = data; self.width = width; self.height = height }
    public func validate() throws {
        guard data.utf8.count <= 1_000_000, (1...2048).contains(width), (1...2048).contains(height),
              width * height <= 4_194_304, let bytes = Data(base64Encoded: data), bytes.count <= 750_000,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == width,
              (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == height else {
            throw RemoteHTTPError(502, "원본 터미널 이미지가 허용된 크기나 형식과 다릅니다.")
        }
    }
}

public struct TerminalNativeDisplay: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case live, permissionRequired, inactive, unavailable }
    public var state: State
    public var message: String?
    public var image: TerminalNativeImage?
    public init(state: State, message: String? = nil, image: TerminalNativeImage? = nil) {
        self.state = state; self.message = message; self.image = image
    }
    public var compact: Self { var result = self; result.image = nil; return result }
}

public struct TerminalWindowPermissions: Equatable, Sendable {
    public var screen: Bool
    public var keyboard: Bool
    public var automation: Bool
    public init(screen: Bool, keyboard: Bool, automation: Bool) { self.screen = screen; self.keyboard = keyboard; self.automation = automation }
}

public struct TerminalCaptureTarget: Hashable, Sendable {
    public let pid: Int32
    public let started: String
    public let tty: String
    public let agent: String
    public init(pid: Int32, started: String, tty: String, agent: AgentKind) {
        self.pid = pid; self.started = started; self.tty = tty; self.agent = agent.rawValue
    }
}

/// Captures one emulator-owned window. The selected native tab and immutable
/// window owner are checked around every capture; no desktop/display filter is used.
@MainActor public final class TerminalWindowCapture {
    public static var screenPermissionGranted: Bool { CGPreflightScreenCaptureAccess() }
    @discardableResult public static func requestScreenPermission() -> Bool {
        screenPermissionGranted || CGRequestScreenCaptureAccess()
    }
    private let host: ScreenHost
    private let ownerBundleID: String
    private let requiresAccessibilityForMetadata: Bool
    private let permissions: @MainActor @Sendable () -> TerminalWindowPermissions
    private let automationPermission: @MainActor @Sendable () -> Bool
    private let keyboardPermission: @MainActor @Sendable () -> Bool
    private let request: @MainActor @Sendable () -> Void
    private let metadata: @Sendable (String) async throws -> TerminalWindowMetadata?
    private let captureImage: @Sendable (TerminalWindowMetadata) async throws -> TerminalNativeImage
    private struct Pending {
        var token: UUID
        var permissions: TerminalWindowPermissions
        var task: Task<TerminalNativeDisplay, Error>
        var observedAt: Date?
        var metadata: TerminalWindowMetadata?
        var validation: (token: UUID, task: Task<TerminalNativeDisplay, Error>)?
    }
    private var pending: [TerminalCaptureTarget: Pending] = [:]

    public init(host: ScreenHost = .terminal,
                ownerBundleID: String? = nil,
                requiresAccessibilityForMetadata: Bool = false,
                permissions: (@MainActor @Sendable () -> TerminalWindowPermissions)? = nil,
                automationPermission: (@MainActor @Sendable () -> Bool)? = nil,
                keyboardPermission: (@MainActor @Sendable () -> Bool)? = nil,
                requestPermissions: (@MainActor @Sendable () -> Void)? = nil,
                metadata: (@Sendable (String) async throws -> TerminalWindowMetadata?)? = nil,
                capture: (@Sendable (TerminalWindowMetadata) async throws -> TerminalNativeImage)? = nil) {
        self.host = host
        let expectedOwner = ownerBundleID ?? host.bundleID
        self.ownerBundleID = expectedOwner; self.requiresAccessibilityForMetadata = requiresAccessibilityForMetadata
        self.permissions = permissions ?? { Self.livePermissions(host) }
        if let automationPermission { self.automationPermission = automationPermission }
        else if let permissions { self.automationPermission = { permissions().automation } }
        else { self.automationPermission = { Self.liveAutomationPermission(host) } }
        if let keyboardPermission { self.keyboardPermission = keyboardPermission }
        else if let permissions { self.keyboardPermission = { permissions().keyboard } }
        else { self.keyboardPermission = { TerminalKeyboard.isAvailable } }
        self.request = requestPermissions ?? {
            if requiresAccessibilityForMetadata { _ = TerminalKeyboard.requestPermission() }
            _ = Self.requestScreenPermission()
        }
        self.metadata = metadata ?? { tty in try await Task.detached { try TerminalAdapter.windowMetadata(tty: tty, host: host) }.value }
        self.captureImage = capture ?? { try await Self.captureVerifiedWindow($0, ownerBundleID: expectedOwner) }
    }
    deinit { for value in pending.values { value.task.cancel(); value.validation?.task.cancel() } }
    public var keyboardPermissionGranted: Bool { keyboardPermission() }
    public var nonpromptAutomationGranted: Bool { automationPermission() }
    public func requestPermissions() { request(); invalidate() }
    public func invalidate() {
        for value in pending.values { value.task.cancel(); value.validation?.task.cancel() }; pending.removeAll()
    }
    public func permissionState() -> TerminalNativeDisplay? { Self.permissionState(permissions(), host: host, requiresAccessibility: requiresAccessibilityForMetadata) }
    private static func permissionState(_ value: TerminalWindowPermissions, host: ScreenHost, requiresAccessibility: Bool) -> TerminalNativeDisplay? {
        var missing = [String]()
        if !value.screen { missing.append("화면 기록") }
        if requiresAccessibility && !value.keyboard { missing.append("손쉬운 사용") }
        if !value.automation { missing.append("\(host.title) 자동화") }
        guard !missing.isEmpty else { return nil }
        return TerminalNativeDisplay(state: .permissionRequired,
            message: "Mac의 시스템 설정 → 개인정보 보호 및 보안에서 AutoApprove의 \(missing.joined(separator: " · ")) 권한을 허용해주세요. 연결 버튼을 누르면 원래 터미널에 다시 연결합니다.")
    }
    private static func liveAutomationPermission(_ host: ScreenHost) -> Bool {
        let descriptor = NSAppleEventDescriptor(bundleIdentifier: host.bundleID)
        // This preflight cannot open the app or ask for Automation consent.
        return AEDeterminePermissionToAutomateTarget(descriptor.aeDesc, typeWildCard, typeWildCard, false) == noErr
    }
    private static func livePermissions(_ host: ScreenHost) -> TerminalWindowPermissions {
        TerminalWindowPermissions(screen: screenPermissionGranted, keyboard: TerminalKeyboard.isAvailable,
            automation: liveAutomationPermission(host))
    }

    public func read(_ target: TerminalCaptureTarget, validateIdentity: @escaping @Sendable () throws -> Bool) async throws -> TerminalNativeDisplay {
        let granted = permissions()
        let value: Pending
        let cached: Bool
        if let existing = pending[target], existing.permissions == granted,
           existing.observedAt.map({ Date().timeIntervalSince($0) < 0.2 }) ?? true {
            value = existing
            cached = existing.observedAt != nil
        } else {
            cached = false
            if let old = pending.removeValue(forKey: target) { old.task.cancel(); old.validation?.task.cancel() }
            if pending.count >= 32 {
                guard let oldest = pending.filter({ $0.value.observedAt != nil }).min(by: { $0.value.observedAt! < $1.value.observedAt! })?.key else {
                    throw RemoteHTTPError(429, "원본 터미널 화면 요청이 많습니다. 잠시 뒤 다시 연결해주세요.")
                }
                if let old = pending.removeValue(forKey: oldest) { old.task.cancel(); old.validation?.task.cancel() }
            }
            let metadata = self.metadata, captureImage = self.captureImage, host = self.host, expectedOwner = ownerBundleID, requiresAccessibility = requiresAccessibilityForMetadata
            let token = UUID()
            let task = Task<TerminalNativeDisplay, Error> { [weak self] in
                guard try await Task.detached(operation: validateIdentity).value else { throw RemoteHTTPError(409, "원래 CLI의 PID 또는 TTY가 바뀌었습니다. 목록을 새로고침해주세요.") }
                try Task.checkCancellation()
                if let required = Self.permissionState(granted, host: host, requiresAccessibility: requiresAccessibility) { return required }
                let before = try await metadata(target.tty)
                guard let before else { return TerminalNativeDisplay(state: .unavailable, message: "원래 터미널의 창을 찾지 못했습니다. Mac에서 같은 탭이 열려 있는지 확인해주세요.") }
                guard before.tty == target.tty, before.windowID > 0, before.ownerPID > 0, before.ownerBundleID == expectedOwner else {
                    return TerminalNativeDisplay(state: .unavailable, message: "원래 터미널 창의 앱과 창 ID를 확인하지 못했습니다. 다른 창은 공유하지 않습니다.")
                }
                guard before.selected, !before.minimized else { return TerminalNativeDisplay(state: .inactive, message: "Mac에서 이 터미널 탭을 선택하거나 연결 버튼으로 같은 탭을 표시해주세요.") }
                let image: TerminalNativeImage
                do { image = try await captureImage(before); try image.validate() }
                catch {
                    try Task.checkCancellation()
                    return TerminalNativeDisplay(state: .unavailable, message: "원본 터미널 이미지를 받지 못했습니다. 화면 기록 권한을 방금 허용했다면 AutoApprove를 다시 실행한 뒤 연결해주세요.")
                }
                try Task.checkCancellation()
                let after = try await metadata(target.tty)
                guard try await Task.detached(operation: validateIdentity).value else { throw RemoteHTTPError(409, "이미지를 읽는 동안 원래 CLI가 종료되거나 바뀌었습니다. 목록을 새로고침해주세요.") }
                guard after == before, after?.selected == true, after?.minimized == false else {
                    return TerminalNativeDisplay(state: .inactive, message: "이미지를 읽는 동안 터미널의 선택 탭이나 창이 바뀌었습니다. 같은 탭을 선택하고 다시 연결해주세요.")
                }
                if self?.pending[target]?.token == token { self?.pending[target]?.metadata = before }
                return TerminalNativeDisplay(state: .live,
                    message: host == .terminal && !granted.keyboard ? "화면은 연결되었습니다. Mac의 손쉬운 사용에서 AutoApprove를 허용하면 화면에서 바로 입력하고 특수 키를 사용할 수 있습니다." : nil, image: image)
            }
            value = Pending(token: token, permissions: granted, task: task); pending[target] = value
        }
        do {
            var result = try await value.task.value; try Task.checkCancellation()
            guard pending[target]?.token == value.token else { throw RemoteHTTPError(409, "원본 창 연결이 바뀌었습니다. 다시 연결해주세요.") }
            if cached, result.state == .live {
                guard let frozen = pending[target]?.metadata else { throw RemoteHTTPError(409, "캐시된 원본 창의 식별자를 확인하지 못했습니다.") }
                let validation: (token: UUID, task: Task<TerminalNativeDisplay, Error>)
                if let existing = pending[target]?.validation { validation = existing }
                else {
                    let metadata = self.metadata, image = result
                    validation = (UUID(), Task {
                        guard try await Task.detached(operation: validateIdentity).value else { throw RemoteHTTPError(409, "원래 CLI가 종료되거나 바뀌어 캐시된 이미지를 공유하지 않습니다.") }
                        try Task.checkCancellation()
                        let current = try await metadata(target.tty)
                        try Task.checkCancellation()
                        guard try await Task.detached(operation: validateIdentity).value else { throw RemoteHTTPError(409, "캐시를 확인하는 동안 원래 CLI가 종료되거나 바뀌었습니다.") }
                        guard current == frozen, current?.selected == true, current?.minimized == false else {
                            return TerminalNativeDisplay(state: .inactive, message: "캐시된 이미지를 확인하는 동안 원래 창이나 선택 탭이 바뀌었습니다. 같은 탭을 선택하고 다시 연결해주세요.")
                        }
                        return image
                    })
                    pending[target]?.validation = validation
                }
                result = try await validation.task.value; try Task.checkCancellation()
                guard pending[target]?.token == value.token else { throw RemoteHTTPError(409, "원본 창 연결이 바뀌었습니다. 다시 연결해주세요.") }
                if pending[target]?.validation?.token == validation.token { pending[target]?.validation = nil }
                if result.state != .live { pending.removeValue(forKey: target) }
            }
            if pending[target]?.observedAt == nil { pending[target]?.observedAt = Date() }
            // A revoked grant must never leave a cached image live.
            if let required = permissionState() { return required }
            return result
        } catch {
            if pending[target]?.token == value.token { pending.removeValue(forKey: target) }
            throw error
        }
    }

    /// Source-specific callers must supply a verified selected window and immutable bundle owner.
    /// This entry never discovers a global frontmost window or activates an application.
    nonisolated public static func captureVerifiedWindow(_ metadata: TerminalWindowMetadata, ownerBundleID: String) async throws -> TerminalNativeImage {
        guard CGPreflightScreenCaptureAccess() else { throw RemoteHTTPError(409, "Mac에서 AutoApprove의 화면 기록 권한을 허용해주세요.") }
        guard metadata.selected, !metadata.minimized, metadata.windowID > 0, metadata.ownerPID > 0,
              metadata.ownerBundleID == ownerBundleID else { throw RemoteHTTPError(409, "정확한 원본 앱과 선택 창을 확인하지 못했습니다.") }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == metadata.windowID && $0.owningApplication?.processID == metadata.ownerPID && $0.owningApplication?.bundleIdentifier == ownerBundleID }), window.isOnScreen, window.windowLayer == 0 else {
            throw RemoteHTTPError(409, "원래 터미널 창을 화면에서 확인하지 못했습니다.")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let rect = filter.contentRect, pixelScale = Double(filter.pointPixelScale)
        guard rect.width.isFinite, rect.height.isFinite, pixelScale.isFinite, rect.width > 0, rect.height > 0, pixelScale > 0 else { throw RemoteHTTPError(502, "터미널 창 크기를 확인하지 못했습니다.") }
        let scale = min(pixelScale, 2048 / Double(rect.width), 2048 / Double(rect.height))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(Double(rect.width) * scale)); configuration.height = max(1, Int(Double(rect.height) * scale))
        configuration.showsCursor = false; configuration.capturesAudio = false; configuration.scalesToFit = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        guard (1...2048).contains(image.width), (1...2048).contains(image.height), image.width * image.height <= 4_194_304 else { throw RemoteHTTPError(502, "터미널 이미지가 너무 큽니다.") }
        for quality in [0.85, 0.7, 0.5, 0.3] {
            let bytes = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { break }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { break }
            if bytes.length <= 750_000 { return TerminalNativeImage(data: (bytes as Data).base64EncodedString(), width: image.width, height: image.height) }
        }
        throw RemoteHTTPError(502, "터미널 이미지가 전송 한도를 넘었습니다. Mac에서 창 크기를 줄여주세요.")
    }
}
