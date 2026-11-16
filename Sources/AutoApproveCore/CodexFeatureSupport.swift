import Foundation

/// Product support for the unmodified official runtime. Unsupported operations
/// fail before preparing servers, sending terminal input or changing journals.
public enum CodexFeatureSupport {
    public static let canMoveOpenSessions=false
    public static let canInspectAllClientConnections=false
    public static let canAttachOpenStandaloneSessions=false
    public static let sessionMoveUnavailable="공식 Codex에서는 열린 터미널의 대화 전체와 대기 입력을 확인할 수 없어 기존 세션의 로그인 그룹 이동·독립 실행 분리를 지원하지 않습니다. 새 세션은 원하는 로그인 그룹에서 시작해주세요."
    public static let connectionInventoryUnavailable="공식 Codex는 터미널별 전체 접속 ID·백엔드 목록을 제공하지 않습니다. 연결 서버와 계정 확인은 계속 사용할 수 있습니다."
    public static let legacyRuntimeUnavailable="선택된 서버 패키지의 공식 Codex 서명을 확인하지 못했습니다. 기존 수정판 서버·클라이언트의 자동 교체는 지원하지 않습니다. 실행 중인 작업을 정리한 뒤 공식 CLI의 서버 패키지로 업데이트해주세요."
    public static let standaloneAttachmentUnavailable="공식 Codex에서는 열린 독립 세션의 숨겨진 대화·초안을 모두 확인할 수 없어 공유 서버로 자동 재연결하지 않습니다. 현재 세션을 유지하며 새 세션은 프로필에서 시작할 수 있습니다."

    static func requireSessionMove()throws {throw AppError.message(sessionMoveUnavailable)}
    static func requireConnectionInventory()throws {throw AppError.message(connectionInventoryUnavailable)}
}
