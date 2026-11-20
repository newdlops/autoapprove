# 포커스 탈취 방지 조사

2026-11-20 조사. Claude Code가 computer use로 화면을 조작할 때 사용자의 키보드 포커스와 마우스를 빼앗지 않게 하는 방법을 찾으려고, 같은 기능을 제공한다고 소개하는 해줘 데스크탑(Haejoe Desktop)을 분석했다. AutoApprove에 비슷한 기능을 넣을지 판단할 때 이 문서를 참고한다.

## 조사 범위와 방법

- 대상: 해줘 데스크탑 0.16.802, macOS arm64 패키지(`com.thekeunpie.haejoe.local`). 공개 저장소 `thekeunpie-hash/haejoe-desktop` 에는 README, 보안 안내, 변경 이력, 이미지만 있고 소스코드는 없다.
- 방법: 설치 프로그램을 실행하지 않았다. `install.sh` 와 설치 패키지를 내려받아 `pkgutil --expand` 로 풀고, 안에 든 JavaScript 런타임(`Contents/Resources/local-orchestrator`)을 읽었다. 코드는 난독화(minify)되어 있어서, 일부 동작은 문자열과 함수 이름으로 추정했다.
- 해줘 데스크탑은 비공개 상용 제품이다. 이 문서에는 동작 방식만 적었고, AutoApprove에 넣을 때에도 코드를 옮기지 않고 아래 명세를 바탕으로 직접 구현한다.

## 해줘 데스크탑의 동작 방식

### 1. PreToolUse 훅으로 포커스를 빼앗는 호출을 막는다

`src/hooks/noFocusStealGuard.cjs` 가 Claude Code의 `PreToolUse` 훅으로 등록된다. 설치 단계(`haejoe-local setup apply`)가 `~/.claude/settings.json` 에 이 훅을 추가하고, 기존 파일은 `.bak-before-haejoe-hook` 접미사로 백업한다.

- 훅이 검사하는 도구(matcher): `Bash|PowerShell|Write|Edit|MultiEdit|NotebookEdit`, Windows-MCP 도구(`mcp__.*windows-mcp__.*`), computer use 도구(`mcp__.*computer-use__.*`).
- 막는 대상:
  1. 셸 명령이나 새로 쓰는 코드에 `SetForegroundWindow`, `SetCursorPos`, `SendInput`, `mouse_event`, `keybd_event`, `AppActivate`, `SwitchToThisWindow`, `BringWindowToTop`, `SendKeys` 가 들어 있는 경우. heredoc 본문도 검사하고, `rg`, `grep`, `git` 처럼 검색만 하는 명령은 예외로 둔다.
  2. 위 API 이름을 숨기려는 실행 방식: PowerShell `-EncodedCommand`, `Invoke-Expression` 으로 다른 곳에서 읽은 문자열 실행, `[scriptblock]::Create`, 파이프로 PowerShell에 스크립트 넘기기.
  3. Windows-MCP의 Click, Move, Type, Shortcut, Scroll, Drag, App 도구와, computer use의 입력 도구(click, type, key, mouse_move, drag, scroll).
- 도구 호출을 막을 때는 "GUI 작업은 화면 밖에서 한다"는 거부 사유를 Claude에게 돌려주고, 자사 도구(`haejoe_desktop_*`, `haejoe_preview_page`, `haejoe_browser_*`)를 대신 쓰라고 안내한다.

검사 목록은 대부분 Windows API다. macOS에서 이 훅만 가져와 쓰면, 훅은 computer use의 클릭과 입력을 전부 막기만 한다.

### 2. 실제 작업은 화면 밖 경로에서 한다

실제로 포커스를 지키는 기능은 훅이 아니라, 훅이 대신 쓰라고 안내하는 화면 밖 실행 도구에 있다.

- ABUA: 에이전트 전용 브라우저 프로필을 사용자의 Chrome 프로필과 분리해 두고, 그 프로필로 화면 밖에서 웹 작업을 한다.
- ACUA: 백그라운드에서 데스크탑 앱을 자동으로 조작한다. macOS 코드는 `AXUIElement`(11곳), `CGEventPost`(1곳), `CGWindowListCreateImage`(1곳), `screencapture`(2곳)를 사용한다. 손쉬운 사용 API로 창 요소를 직접 조작하고, 창 단위로 화면을 캡처하는 방식으로 추정한다. 세부 구현은 난독화 때문에 확인하지 못했다.

## AutoApprove에 넣는다면

AutoApprove는 이미 손쉬운 사용 권한과 키 이벤트 게시 권한을 받아 두었고, 마우스 활동 설정(`MouseActivitySettings`)도 갖추고 있다. 아래는 제안이며, 아직 어느 것도 검증하지 않았다.

1. **사용자 활동에 따라 막는 훅**: 사용자가 최근 몇 초 안에 마우스나 키보드를 썼다면 computer use 입력 도구를 `PreToolUse` 훅에서 거부하고, 유휴 상태일 때만 허용한다. 해줘처럼 무조건 막는 방식보다 computer use를 쓸 수 있는 시간이 늘어난다. 거부할 때에는 이유와 다시 시도할 시점을 Claude에게 알려 준다.
2. **포커스를 옮기지 않는 조작 경로**: 클릭 대신 AX API의 `AXPress`, 입력 대신 `AXSetValue` 처럼 창을 앞으로 가져오지 않는 동작을 MCP 도구로 제공한다. 앱마다 손쉬운 사용 지원 수준이 달라서 모든 앱에서 동작하지는 않는다.
3. **특정 프로세스에만 키 보내기**: `CGEventPostToPid` 로 대상 프로세스에만 키 이벤트를 보낸다. 백그라운드 이벤트를 무시하는 앱이 있으므로 앱별로 확인해야 한다.
4. **창 단위 캡처**: 화면 전체 대신 대상 창만 ScreenCaptureKit이나 `CGWindowListCreateImage` 로 캡처해, 창을 앞으로 가져오지 않고 상태를 확인한다.
5. **웹 작업 분리**: 웹 작업은 사용자 브라우저가 아니라 별도 프로필의 헤드리스 브라우저에서 한다.

## 해줘 데스크탑 설치 과정에서 확인한 사항

아래 방식은 AutoApprove의 설치와 업데이트를 설계할 때 피해야 할 사례로 참고한다.

- 설치 패키지에 서명이 없다(`pkgutil --check-signature`: `no signature`). 앱은 adhoc 서명이고 TeamIdentifier가 없다.
- `install.sh` 와 postinstall 스크립트가 `xattr -cr`, `xattr -dr com.apple.quarantine` 으로 격리 속성을 지워 Gatekeeper 검사를 건너뛴다.
- 설치 스크립트와 자동 업데이트가 SHA-256을 비교하지만, 해시와 설치 파일을 같은 서버에서 받는다. 서버가 탈취되면 바뀐 설치 파일을 걸러 내지 못한다.
- LaunchAgent(`com.thekeunpie.haejoe-local`)를 `KeepAlive`, `RunAtLoad`, `ProcessType=Interactive` 로 등록해 상주시킨다.
- Claude 세션을 `--permission-mode bypassPermissions` 로 실행하는 코드와, 같은 모드로 예약 작업을 등록하는 코드가 있다.
- 작업 목표와 지시문을 사용자 동의(`accept`)를 받은 뒤 원격 서버(`/api/local/brain/call`)로 보내고, 텔레메트리를 `/api/local/telemetry` 로 보낸다. 동의 화면에는 `local-only` 선택지가 있다.

## AutoApprove 자체 점검에서 나온 사항

같은 날 AutoApprove 저장소도 함께 읽었다.

- `ApprovalEngine.networkIsolated` 의 기본값이 `false` 라서, 처음 실행하면 같은 네트워크에서 로그인 없이 터미널을 보고 제어하는 웹페이지가 열린다. 확인 창에는 공용 네트워크에서 켜지 말라는 경고가 있지만, 기본값을 격리(`true`)로 두고 사용자가 직접 웹 접속을 켜게 하는 편이 안전하다.
- 앱은 자체 인증서(`AutoApprove Local Code Signing`)로 서명되어 Gatekeeper 평가에서 `rejected` 가 나온다. 자동 업데이트는 SHA-256과 기존 앱의 게시자 서명을 모두 확인한다.
