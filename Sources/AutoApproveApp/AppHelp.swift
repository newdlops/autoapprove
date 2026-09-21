import AutoApproveCore

/// Shared wording keeps the list, detail view and menu consistent.
enum AppHelp {
    static let connections = "질문·작업 완료 알림 권한과 Terminal 연결, Claude 훅, VS Code 확장의 연결 상태를 확인합니다."
    static let history = "종료된 세션을 포함한 전체 승인 내역을 검색하고 요청 내용과 전달 결과를 확인합니다."
    static let search = "프로젝트 이름·전체 경로, 터미널 제목, Claude Code·Codex, TTY 또는 PID로 실행 중인 세션을 찾습니다."
    static let tty = "터미널 탭의 식별자입니다. 같은 프로젝트를 여러 창에서 실행할 때 구분할 수 있습니다."
    static let pid = "실행 중인 Claude Code·Codex 프로세스의 번호입니다."

    static func pause(_ paused: Bool) -> String {
        paused ? "자동 승인을 켜 둔 세션의 새 권한 요청 처리를 재개합니다."
            : "모든 세션의 새 자동 승인을 멈춥니다. 이미 시작된 터미널 작업은 계속됩니다."
    }

    static func automatic(_ session: AgentSession, paused: Bool) -> String {
        if session.phase == .ended { return "종료된 세션입니다. 실행 중인 세션에서 자동 승인을 설정하세요." }
        if !session.canApprove {
            return session.automatic ? "연결이 끊겨 자동 승인이 대기 중입니다. 끄면 연결 복원 후에도 자동 승인하지 않습니다."
                : "연결 설정에서 Terminal, Claude 훅 또는 VS Code 확장을 먼저 연결하세요."
        }
        if paused { return "전체 일시정지 중입니다. 이 스위치로 세션 설정을 정하고 전체 재개 후 적용합니다." }
        return session.automatic ? "이 세션의 자동 승인을 끕니다. 이후 권한 요청은 터미널에서 직접 확인합니다."
            : "실행·파일 변경 권한을 자동 승인하고, Claude 훅의 명확한 예·아니오 질문에는 ‘예’로 답합니다. 그 밖의 선택 질문은 알림을 눌러 직접 답해주세요."
    }

    static func phase(_ session: AgentSession) -> String {
        if session.automaticWaitingForConnection { return "자동 승인 설정은 켜져 있지만 요청을 받을 연결이 없습니다. 연결 설정을 확인하세요." }
        switch session.phase {
        case .working: return "Claude Code·Codex가 작업을 진행 중인 것으로 감지했습니다."
        case .idle: return "다음 지시를 기다리는 입력 대기 상태로 감지했습니다. 출력이 조용하다는 이유만으로 대기로 판단하지 않습니다."
        case .approval: return "실행·파일 변경 등의 권한 요청을 기다리고 있습니다. 자동 승인 설정과 연결을 확인하세요."
        case .input: return "직접 확인이 필요한 질문입니다. 알림을 누르거나 터미널을 열어 답해주세요. Claude 훅의 명확한 예·아니오 질문은 자동 승인 설정에 따릅니다."
        case .unknown: return "현재 작업 상태를 판별할 근거가 부족합니다. 작업이 멈췄거나 끝났다는 뜻은 아닙니다."
        case .ended: return "도구 실행이 종료되었습니다. 저장된 승인 내역은 계속 확인할 수 있습니다."
        }
    }

    static func reveal(_ session: AgentSession, opening: Bool) -> String {
        if opening { return "선택한 터미널을 열고 있습니다. 잠시 기다려주세요." }
        guard session.canReveal else {
            return session.phase == .ended ? "종료된 세션의 터미널로 이동할 수 없습니다."
                : "이 세션의 터미널 연결을 먼저 설정하세요. VS Code는 확장이 필요합니다."
        }
        return session.terminal == .terminal ? "이 세션의 탭을 앞으로 가져오고 창에 3초 동안 파란 테두리와 프로젝트명을 표시합니다."
            : "VS Code에서 이 세션의 터미널을 선택하고 이름이 포함된 알림을 표시합니다."
    }

    static func channel(_ channel: ApprovalChannel) -> String {
        switch channel {
        case .none: return "세션은 발견했지만 승인 요청을 받는 연결이 없습니다."
        case .hook: return "Claude가 보내는 권한 요청과 작업 이벤트를 직접 받습니다. 일부 요청은 터미널 연결로 확인합니다."
        case .terminalScreen: return "macOS Terminal 화면에서 지원하는 승인 요청을 감지하고 해당 탭에 응답합니다."
        case .vscodeScreen: return "AutoApprove Bridge가 전달한 VS Code 터미널 출력에서 승인 요청을 감지합니다."
        }
    }

    static func result(_ result: AuditResult) -> String {
        switch result {
        case .delivered: return "승인 또는 질문 응답을 전달한 기록입니다. 명령 실행이 성공했다는 뜻은 아닙니다."
        case .review: return "승인 전달에 실패했거나 결과를 확인하지 못했습니다. 상세 내역의 사유를 확인하세요."
        case .manual: return "자동으로 답하지 않고 원래 터미널에서 직접 확인하도록 넘긴 요청입니다."
        case .queued: return "답변을 Codex 메시지 대기열에 등록했습니다. Codex가 받을 차례가 되면 전달되며, 처리 완료를 뜻하지 않습니다."
        }
    }
}
