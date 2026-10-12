# AutoApprove 작업 인계

최종 갱신: 2026-10-12 (KST), 0.2.77 · 빌드 99. 새 작업 전에 현재 Git 및 실행 상태를 다시 확인한다.

## 현재 상태

- 사용자 요청: 질문 목록의 ‘실행 중인 Codex의 로컬 서버를 찾지 못했습니다’ 오류를 해결하고 허가·불허 외의 선택형 질문도 웹에서 답한다.
- 앱 **0.2.77/99**, Bridge **0.2.9**. 이 Mac에 적용했으며 원본 식별·직접 입력 키는 **이 Mac 20개**다. 사용자 원본 CLI는 재시작하지 않았다. 다른 Mac은 현재 연결 해제여서 0.2.77 적용·원본 연결을 확인하지 못했다. 같은 네트워크에 재연결하면 LAN 자동 업데이트를 확인한다.
- 로컬 검증·이 Mac 설치를 완료했다. 소스 커밋·태그 push·GitHub 게시 및 공개 다운로드 확인을 마무리해야 한다.
- 게시할 배포: [v0.2.77](https://github.com/newdlops/autoapprove/releases/tag/v0.2.77). 설치 파일 `AutoApprove-0.2.77-macOS-arm64.dmg`, SHA-256 `a01638fe4c553975164305565d6c83903761720fb81e5ddc6d5795a693a28731`.
- project `/Users/lky/project/autoapprove`, macOS arm64·Swift 패키지. [AGENTS.md](../AGENTS.md), [README.md](../README.md), [DESIGN.md](../DESIGN.md), [VALIDATION.md](../VALIDATION.md)를 따른다.
- 이전 capacity 자동 이어가기(0.2.76)의 5회 제한 제거와 최대 480초 반복 간격, 0.2.75의 blocked Goal 복구는 유지한다. 완료된 기존 목표를 임의로 재개하거나 새 목표를 만들지 않는다.

## 이번 변경의 연결 경로

| 경로 | 동작 |
|---|---|
| `CodexQueue.swift`, `QuestionReply.swift` | 실행 중 프로세스가 소유한 서버의 실제 지원 여부를 확인한다. 서버가 있으면 기존 대기 입력 경로를 유지하고, 없으면 원본 메시지 경로를 사용한다. |
| `ApprovalEngine.swift` | 최신 질문·대화·원본 PID/시작 시각/TTY·화면을 검증한다. 답변 전 저장된 sending 예약과 세션 입력 잠금, 자동 응답 취소/일시정지/초안을 유지한다. |
| `TerminalChoiceQuestion.swift`, `RemoteTerminal.swift` | 일반 번호 메뉴를 현재 프레임의 선택지로 제공한다. 현재 질문·선택지·선택 위치를 확인하고 한 번만 입력한다. |
| `TerminalDeviceInput.swift`, `ManagedPTY.swift` | Terminal의 실제 CLI 키 바인딩과 기존 소유 PTY 입력을 사용한다. 새 PTY를 만들거나 원본을 옮기지 않는다. |
| `Resources/RemoteWeb/app.js` | 라디오/명시적 복수 선택, 직접 답변, 초안/포커스, 전송/오류/미확인 상태와 queue 기능 지원 안내를 제공한다. |
| `extensions/vscode/src/{extension,screen}.ts` | Bridge 0.2.9가 choice 지원을 등록한다. 현재 렌더링 화면·generation·만료·일회 전송을 확인해 기존 Terminal 객체에 전달한다. |

Codex 0.162.1의 설치된 문자열과 공식 구현을 확인했다. 기본 `Question 1/2`·`tab to add notes` 화면은 **숫자로 선택하는 순간 다음 질문으로 진행**하므로 Return을 추가하지 않는다. 일반 확인 메뉴는 이동과 Return 한 번을 보낸다. 메모 편집/불완전 메뉴/알 수 없는 바인딩에는 추측 입력하지 않는다. 승인 메뉴는 기존 자동 승인 경로로 처리한다.

대기 입력 목록·삭제 미지원은 전체 질문 연결 실패가 아니다. 기존 서버 미발견 문구는 소켓 접속 전 실패였으므로 그 정확한 과거 상태만 재시도 가능하게 복원한다. 실제 전달 후 시간 초과·부분 입력·프로세스 재시작 중 sending 기록은 uncertain으로 보존하며 자동 재전송하지 않는다.

## 검증 및 실제 사용 확인

- release Core **216/216**, Bridge **17/17**, 새 브라우저 **8개**, 기존 웹 **17개**, Unix 소켓 **8개**, 실제 격리 PTY/tmux **9개 조건** 통과.
- 모바일·태블릿·데스크톱 렌더링과 다음 질문·미확인/완료 상태를 별도 확인. QA 데이터와 이미지는 무시된 `dist/qa/`에만 둔다.
- 서명·입력 서비스 메타데이터·앱 리소스·격리된 웹/MCP/PTY·DMG 검증 완료. 로컬 원본 CLI 20개, 저장 설정·승인 기록 14,591건, 기존 root 서비스 보존. 다른 Mac은 현재 연결 해제여서 0.2.77 적용·원본 연결을 확인하지 못했다. 같은 네트워크에 재연결하면 LAN 자동 업데이트를 확인한다.
- 실제 휴대폰에서는 페이지를 새로고침해 **0.2.77 · 빌드 99**를 확인하고 일반 선택형 질문·다음 질문을 시험한다. 제공자의 질문을 강제로 만들거나 사용자 세션에 테스트 문자를 보내지 않았다.
- VS Code의 선택 메뉴 입력은 Bridge **0.2.9** 등록 후 사용한다. 기존 창·CLI를 강제로 재시작하지 않는다. 숫자 메뉴가 아닌 자유 답변과 알 수 없는 키 바인딩 화면은 원본 입력을 유지한다.
- 다른 Mac의 주소·세션 수는 바뀐다. 고정 IP·세션 수를 가정하지 말고 온라인 상태·버전·입력 키를 다시 확인한다.

## 유지할 사용자 요구

- 휴대폰 설치·연결 코드·외부 중계 서비스 없이 같은 핫스팟의 Mac 웹(TCP 8765)과 Mac 목록을 사용한다. 휴대폰의 localhost는 Mac이 아니다.
- 항상 같은 원본 CLI를 제어한다. 별도 PTY 이동이나 CLI 재시작으로 동기화를 대체하지 않는다.
- 평소에는 텍스트 터미널을 유지하며 화면 공유는 요청 시 보기 목적으로만 시작한다.
- 원본 식별·전경 작업·최신 화면·입력 내역을 확인한다. 미확인 입력과 같은 실패 화면은 자동 재전송하지 않는다.
- 자동 승인 OFF, 전체 일시정지, 취소, 초안·질문 대기를 존중한다. 명시적으로 일시정지/완료한 Goal과 예산·사용량 제한은 자동 재개하지 않는다.
- 이미 잠긴 화면을 해제하지 않는다. 관리자 암호·macOS 권한은 사용자가 직접 승인한다.
- Zscaler·SentinelOne·TCC·Gatekeeper·회사 정책을 끄거나 우회하지 않는다. 이전 suspicious:bash 이후 새 경고가 없었다는 사용자 보고는 경고 없음의 보장이 아니다.
- 유료 Apple 계정 없이 기존 발행자 서명·정상 입력 서비스를 유지한다. 0.2.73/0.2.74 설치 호환 수정의 SMJobBless·상호 서명 검증은 유지한다.
- **버전을 올렸으면 같은 작업에서 GitHub 릴리스까지 완료한다.**

## 재현 및 배포

```sh
swift build -c release
.build/release/autoapprove-checks
node scripts/interruption-relay-check.mjs --release
node scripts/terminal-question-browser-check.mjs --release
node scripts/codex-queue-transport-check.mjs
npm --prefix extensions/vscode test
npm --prefix extensions/vscode run package
node scripts/package-app.mjs release .runtime/releases/0.2.77/questions-99/AutoApprove.app
node scripts/terminal-input-package-check.mjs .runtime/releases/0.2.77/questions-99/AutoApprove.app
node scripts/network-package-check.mjs .runtime/releases/0.2.77/questions-99/AutoApprove.app
node scripts/package-dmg.mjs .runtime/releases/0.2.77/questions-99/AutoApprove.app
```

이번 패키지 경로는 완료 기록이다. 다음 배포는 **새 버전·빌드·새 디렉터리**를 사용한다. Swift 빌드 중 Swift 소스를 바꾸지 않는다. 브라우저 검사는 설치된 Playwright/Chromium 경로를 `AUTOAPPROVE_PLAYWRIGHT_MODULE`·`AUTOAPPROVE_CHROMIUM_PATH`로 지정한다. 샌드박스로 차단된 네트워크·서명·시스템 접근은 정식 실행 승인을 사용한다.

이번 비공개 자료는 `.runtime/releases/0.2.77/questions-99/`의 `deploy.py`, `verification.json`, `network-{before,after}.json`, `verify-github.mjs`, `github-verification.json`이다. 설치 스크립트를 다시 실행해 백업을 덮어쓰지 않는다. 앱 관리자만 재시작하고 원본 CLI·정상 root 서비스·설정·기록은 전후 비교한다. 살아 있는 앱 소유 PTY가 있으면 종료 승인 전 업데이트하지 않는다.

태그는 검증한 소스 커밋에 만들고 main·태그를 push한 뒤 `gh release create`로 DMG·체크섬을 게시한다. 공개 태그·두 파일·다운로드 바이트를 확인한다. 이 Mac의 Node TLS는 Zscaler CA로 실패한 적이 있으므로 정상 시스템 TLS의 `/usr/bin/curl`을 사용하며 인증서 검사를 끄지 않는다.

## 워크스페이스 주의

- 로컬 `http://127.0.0.1:8765/api/network`에서 버전·업데이트·세션 식별·입력 키만 읽는다. 사용자 대화·전체 화면·DB·서명 키체인을 문서나 릴리스에 포함하지 않는다.
- Wi-Fi/유선 동시 연결에서도 LAN 인터페이스 출발 주소를 사용하고 VPN 인터페이스는 제외한다. 핫스팟 주소는 재연결 후 달라진다.
- `.codeidx/mcp-control.json`, `.codeidx/mcp-server.json`, 해당 임시 파일과 `.vscode/settings.json`은 별도 작업 변경이다. 덮어쓰거나 이번 릴리스에 포함하지 않는다.
- Git 전체 index를 일괄 커밋하지 않는다. 정확한 작업 경로의 `git commit --only`를 사용한다. 먼저 `git status --short`·`git log`를 확인하고 unrelated 변경을 보존한다.
