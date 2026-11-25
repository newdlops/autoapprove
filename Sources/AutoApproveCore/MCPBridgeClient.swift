import Foundation
import Darwin

enum MCPBridgeClient {
    static func request(path: String, message: JSONObject, timeout: Int) throws -> JSONObject {
        let deadline = ProcessInfo.processInfo.systemUptime + min(8, Double(timeout))
        var delay = 0.1
        while true {
            do { return try SocketClient.request(path: path, message: message, timeout: timeout) }
            catch let error as LocalSocketConnectionFailure {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0, [ENOENT, ECONNREFUSED, EAGAIN, ENOBUFS].contains(error.code) else { throw error }
                Thread.sleep(forTimeInterval: min(delay, remaining))
                delay = min(1, delay * 2)
            }
        }
    }
}
