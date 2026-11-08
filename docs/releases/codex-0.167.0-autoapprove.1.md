# Codex 0.167.0 · AutoApprove subagent approval hotfix 1

AutoApprove가 서브에이전트를 승인한 뒤 부모 TUI에 오래된 승인창이 남아
`Not available in TUI yet for thread …` 오류가 발생하는 Codex TUI 결함을 수정합니다.
처리된 요청의 창을 정확한 스레드·요청 ID로 닫고, 자동 승인과 동시에 들어온
늦은 클릭은 중복 응답 없이 마칩니다.

OpenAI 공식 릴리스가 아닌 AutoApprove 관리 수정본입니다. 공식 Codex 0.167.0
소스에 포함된 승인 UI 처리만 수정하며 승인 정책이나 사용자 질문을 자동으로
바꾸지 않습니다. macOS 14 이상 arm64용 별도 패키지이며 AutoApprove 앱 업데이트와 구분합니다.

패키지의 `install.mjs`에 기존 네이티브 Codex 실행 파일 경로를 지정하면 원본
체크섬 확인, 백업, 수정본 서명 확인 후 원자적으로 교체합니다. `--restore`는
백업을 복원합니다. 이미 실행 중인 TUI는 다시 열어야 적용되며 설치 명령은
서버나 대화를 종료하지 않습니다.

원본 소스·패치 체크섬, 변경 파일, 라이선스, 설치 프로그램이 패키지에 포함됩니다.
새 회귀 테스트 3개를 포함한 관련 네이티브 테스트 43개가 통과했습니다.
서명된 수정본과 공식 서버의 실제 PTY 재현에서 자동 승인, 자식 명령·턴 완료,
부모 승인창 제거와 오류 부재를 확인했습니다. 설치·중복 설치·원본 복원도 검증했습니다.

세부 수정과 재현 방법은 저장소의
[패치 문서](https://github.com/newdlops/autoapprove/blob/codex-0.167.0-autoapprove.1/patches/codex/0.167.0-subagent-approval.md)에 있습니다.
