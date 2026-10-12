import Foundation
import Security
import ServiceManagement
import TerminalInputSupport

/// Called only by explicit setup in the Mac app. ServiceManagement validates
/// both publisher-pinned signatures and installs the embedded helper itself.
/// No administrator shell, password handling, or remote installation endpoint.
enum TerminalInputAuthorization {
    static func install() throws {
        var authorization: AuthorizationRef?
        let created = AuthorizationCreate(nil, nil, [], &authorization)
        guard created == errAuthorizationSuccess, let authorization else { throw failure(created) }
        defer { AuthorizationFree(authorization, []) }
        let status = kSMRightBlessPrivilegedHelper.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                return AuthorizationCopyRights(authorization, &rights, nil,
                    [.interactionAllowed, .extendRights, .preAuthorize], nil)
            }
        }
        guard status == errAuthorizationSuccess else { throw failure(status) }
        var error: Unmanaged<CFError>?
        guard SMJobBless(kSMDomainSystemLaunchd, TTYInputConfiguration.service as CFString,
                         authorization, &error) else {
            let detail = error?.takeRetainedValue()
            let code = detail.map { CFErrorGetCode($0) } ?? -1
            throw AppError.message("macOS에서 직접 입력 서비스를 설치하지 못했습니다 (\(code)). 시스템의 설치 허용 상태를 확인해주세요. 원본 CLI는 유지됩니다.")
        }
    }

    private static func failure(_ status: OSStatus) -> AppError {
        if status == errAuthorizationCanceled {
            return .message("직접 입력 서비스 설치를 취소했습니다. 다시 연결할 때 Mac에서 관리자 승인을 진행해주세요.")
        }
        if status == errAuthorizationDenied {
            return .message("macOS에서 관리자 승인을 허용하지 않았습니다. 이 Mac의 관리자 계정으로 직접 입력 연결을 승인해주세요.")
        }
        return .message("macOS 관리자 승인을 시작하지 못했습니다 (\(status)). Mac에서 직접 입력 연결을 다시 선택해주세요.")
    }
}
