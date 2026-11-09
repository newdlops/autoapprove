import Foundation

/// Kept for the CLI setup command. It never registers or installs a service.
public enum TerminalInputInstaller {
    public enum Result: Equatable, Sendable {
        case alreadyConnected
        public var message: String { TerminalInputStatus.available.message }
    }
    public static func prepare(app: URL, ownIdentifier: String = "local.autoapprove.mac") throws -> String {
        let plan: [String: Any] = ["registration": "Accessibility", "application": app.path,
            "administratorShell": false, "privilegedService": false, "requiresAccessibility": true]
        return String(decoding: try JSONSerialization.data(withJSONObject: plan, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }
    @discardableResult public static func install(app: URL = Bundle.main.bundleURL,
        ownIdentifier: String = "local.autoapprove.mac") throws -> Result {
        guard TerminalInputClient.shared.isAvailable else { throw AppError.message(TerminalInputStatus.notInstalled.message) }
        return .alreadyConnected
    }
}
