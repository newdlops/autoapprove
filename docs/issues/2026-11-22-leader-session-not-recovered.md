## 제목
세션을 다시 시작하거나 AutoApprove 를 업데이트한 뒤, 그룹장 세션이 그룹 구성원으로 복구되지 않는다 (get_session_groups 가 groups: [] 를 돌려준다)

## 증상
- 그룹장 자리로 쓰던 Claude Code 세션을 다시 시작(새 세션 ID)하면 `get_session_groups` 가 `groups: []` 를 돌려준다. `get_group_status` 도 `groups: []`, `assign_group_task` 는 "현재 세션은 이 그룹의 구성원으로 확인되지 않았습니다." 로 거절된다.
- AutoApprove 화면에서 세션을 갱신하고, AutoApprove 를 0.2.353(빌드 380)에서 0.2.360(빌드 387)로 올린 뒤에도 같다.
- `reconnect_group_member(groupID, memberID[, conversationID])` 를 그룹장 memberID 로 두 번 불렀지만 "현재 세션의 그룹과 구성원을 확인해주세요. get_session_groups로 다시 조회할 수 있습니다." 로 실패한다. 이 도구는 이 세션의 그룹 목록에 그룹이 이미 들어 있어야 쓸 수 있어서, 목록이 비어 있으면 복구에 쓸 수 없다.

## 같은 시점의 진단 (`get_diagnostics`)
- 권한(손쉬운 사용, 키 입력, Terminal 직접 입력): 모두 ok
- 관리형 Codex 서버: running, 연결된 세션 0개
- 세션 그룹 메시지 전달: "그룹 1개 · 수신 미확인 0건 · 전달이 막힌 구성원 없음"
- 그룹과 다른 구성원은 정상이고, 재시작한 이 세션만 그룹에 연결되지 못한다.

## 재현 순서
1. 그룹 하나를 만들고 그룹장 세션 A 와 구성원 세션 여러 개를 연결한다.
2. 세션 A 를 종료하고 같은 작업 폴더에서 새 Claude Code 세션 B 를 연다(이전 대화를 이어 갈 수 있는 상태).
3. 세션 B 에서 `get_session_groups` 를 부른다 → `groups: []`.
4. AutoApprove 화면에서 세션 갱신, AutoApprove 업데이트 후에도 같다.

## 기대 동작
- 세션 B 가 같은 memberID 의 그룹장 자리를 이어받거나, 화면에서 그룹장 자리를 세션 B 에 다시 연결할 수 있어야 한다.
- 또는 `reconnect_group_member` 가 그룹 목록이 비어 있어도 memberID 로 대상을 찾아 현재 세션 ID 로 갱신해야 한다.

## 원인 추정 (확인하지 못함)
- 그룹 파일에 저장된 그룹장 구성원의 대화 UUID(runtimeID)가 이전 세션 것이라, 새 세션이 그 구성원과 일치하지 않는다.
- 업데이트 전부터 떠 있던 MCP 서버 프로세스가 새 버전과 다를 수 있다(`/mcp` 재연결은 아직 해 보지 않았다).
- 이전에 같은 증상에서 MCP 환경 변수 `LC_ALL=en_US.UTF-8` 을 넣고 그룹 파일의 runtimeID 와 비교해 해결한 적이 있다(한글 로케일에서 구성원 인식 실패). 이번에도 해당하는지는 확인하지 못했다.

## 환경
- AutoApprove 0.2.360(빌드 387, api 1), 이전 0.2.353(빌드 380). macOS 26.4(arm64)
- Claude Code CLI, 그룹 구성원 12명(Claude Haiku, Sonnet, Opus, Fable 혼합)

## 요청
- 재시작한 세션을 그룹장으로 다시 연결하는 방법(화면의 버튼이나 도구)을 제공해 주세요.
- `get_session_groups` 가 비어 있을 때 사용자에게 원인(그룹 파일의 대화 UUID 불일치 등)과 해결 방법을 알려 주는 진단 메시지를 더해 주세요.
