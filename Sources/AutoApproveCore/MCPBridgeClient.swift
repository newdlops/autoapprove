import Foundation
import Darwin

enum MCPBridgeClient {
    static func request(path: String, message: JSONObject, timeout: Int) throws -> JSONObject {
        for attempt in 0..<5 {
            do { return try SocketClient.request(path: path, message: message, timeout: timeout) }
            catch let error as LocalSocketConnectionFailure {
                guard attempt < 4, [ENOENT, ECONNREFUSED].contains(error.code) else { throw error }
                // App/listener replacement can briefly remove the Unix socket.
                // Only pre-send connection failures retry. An accepted request
                // with a lost response is returned to the caller as uncertain.
                Thread.sleep(forTimeInterval: 0.1 * Double(1 << attempt))
            }
        }
        throw AppError.message("AutoApprove의 로컬 연결을 확인하지 못했습니다.")
    }
}
