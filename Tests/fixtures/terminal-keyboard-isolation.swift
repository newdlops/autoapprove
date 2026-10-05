// This shim permits the current production sender to be checked without a
// package rebuild. Domain/process helpers come from the prior release; the
// runner extracts the current production ScreenTarget declaration verbatim.
import Foundation
import AutoApproveCore

public typealias AgentKind = AutoApproveCore.AgentKind
public typealias ScreenHost = AutoApproveCore.ScreenHost
public typealias TerminalDelivery = AutoApproveCore.TerminalDelivery
public typealias TerminalWindowMetadata = AutoApproveCore.TerminalWindowMetadata
public typealias ProcessRecord = AutoApproveCore.ProcessRecord
public typealias ProcessDiscovery = AutoApproveCore.ProcessDiscovery
public typealias TerminalAdapter = AutoApproveCore.TerminalAdapter
public typealias TerminalAdapterError = AutoApproveCore.TerminalAdapterError
public typealias AppError = AutoApproveCore.AppError
public typealias RemoteHTTPError = AutoApproveCore.RemoteHTTPError
public typealias JSONObject = [String: Any]

enum AutomationScript {
    static func literal(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
    }
    static func run(_ body: String, app: String, denied: TerminalAdapterError, timeout: TimeInterval = 8) throws -> String {
        throw AppError.message("Isolated native checks must inject all automation operations")
    }
}
enum ITermAdapter { static let visibleFunction = "throw Error('The isolated native check cannot use iTerm');" }
enum TerminalDeviceInput {
    static func deliver(target: ScreenTarget, agent: AgentKind, input: RemoteTerminalInput) throws -> TerminalDelivery {
        throw AppError.message("Legacy isolated keyboard checks cannot invoke the original TTY input service")
    }
}
enum OrcaAdapter {
    static func readScreen(handle: String) throws -> String { throw AppError.message("Isolated native checks cannot access Orca") }
    static func normalize(_ value: String) -> String { preconditionFailure("Isolated native checks cannot access Orca") }
    static func sendComposed(handle: String, text: String) throws -> JSONObject { throw AppError.message("Isolated native checks cannot access Orca") }
}
