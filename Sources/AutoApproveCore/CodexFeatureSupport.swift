import Foundation

/// Product support for the unmodified official runtime. Unsupported operations
/// fail before preparing servers, sending terminal input or changing journals.
public enum CodexFeatureSupport {
    public static let canMoveOpenSessions=true
    public static let canInspectAllClientConnections=false
    public static let canAttachOpenStandaloneSessions=true
    static let canUsePrivateSessionAttachment=false
    public static let sessionMoveUnavailable="이전 방식의 Codex 이동 기록은 자동 실행하지 않습니다. 현재 세션의 대화 ID로 이동 범위를 다시 확인해주세요."
    public static let connectionInventoryUnavailable="공식 Codex는 터미널별 전체 접속 ID·백엔드 목록을 제공하지 않습니다. 연결 서버와 계정 확인은 계속 사용할 수 있습니다."
    public static let legacyRuntimeUnavailable="선택된 서버 패키지의 공식 Codex 서명을 확인하지 못했습니다. 기존 수정판 서버·클라이언트의 자동 교체는 지원하지 않습니다. 실행 중인 작업을 정리한 뒤 공식 CLI의 서버 패키지로 업데이트해주세요."
    public static let standaloneAttachmentUnavailable="이전 방식의 독립 세션 연결은 자동 실행하지 않습니다. 원래 터미널에서 현재 대화 ID와 로그인 홈을 다시 확인해주세요."

    static func requireSessionMove()throws {throw AppError.message(sessionMoveUnavailable)}
    static func requireConnectionInventory()throws {throw AppError.message(connectionInventoryUnavailable)}
}
