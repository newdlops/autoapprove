# AutoApprove 작업 인계

최종 갱신: 2026-10-13 (KST), 0.2.79 · 빌드 101. 새 작업 전에 현재 Git 및 실행 상태를 다시 확인한다.

## 현재 상태

- 앱 **0.2.79/101**, Bridge **0.2.9**. 두 Mac 적용, 원본 식별·직접 입력 **이 Mac 19개 / 다른 Mac 4개**. 원본 CLI 재시작 없음.
- 소스 태그·GitHub 정식 릴리스·DMG/체크섬 게시 및 인증 없는 다운로드 바이트 일치 확인. 소스 커밋 `002804fd574b02c23960c589bdaf804b404b2b69`.
- 배포: [v0.2.79](https://github.com/newdlops/autoapprove/releases/tag/v0.2.79). DMG SHA-256 `03c90071b34edbcf9735a71e9c0eefc3080a374437ab8075045eb7e9858f29cc`.

## 0.2.79 줄바꿈 후 제출 복구

- 사용자 보고: 재시도 문구를 입력했지만 Enter가 빈 줄만 추가하고 실제 제출되지 않아 멈추는 경우. 기존 경로는 이를 결과 미확인으로 남겨 더 이상 제출하지 않았다. 이제 확인된 앱 소유 초안에는 **Enter만 재시도**하며 같은 문구를 다시 입력하지 않는다.
- 원본 오류/Goal, 원본 대화 지문, 모델·폴더·경고·라이프사이클 footer, 입력창 전체를 확인한다. 줄바꿈·빈 줄·Codex의 입력 중 shortcut 안내 숨김을 처리하며, 사용자 메모·중복 문구·다른 대화/폴더·실행 중 화면은 자동 제출하지 않는다. 750ms 뒤 다시 확인한 같은 초안에 Return을 보낸다.
- `SessionInterruption.resumeStop/resumeSubmissionCancelled`로 입력 전 소유 근거와 취소를 저장한다. 앱 재시작 후에도 정확한 초안만 제출을 이어간다. 0.2.78의 Goal blocked 미확인 기록은 동일 세션/명령/지문과 감사 기록의 전체 footer가 일치할 때만 복원한다. 근거 없는 이전 미확인 입력은 재전송하지 않는다.
- Terminal은 이미 연결된 정상 직접 입력 서비스를 우선 사용한다. 서비스 미연결 시 기존 Terminal 스크립트를 유지하며 iTerm은 newline 기본값 대신 실제 `CR`을 사용한다. Orca·기존 tmux·소유 PTY·VS Code Bridge에도 Enter만 재시도하는 경로를 적용한다. 새 사용자 PTY를 만들거나 원본 CLI를 옮기지 않는다.
- 첫 미제출 재확인은 3초 간격이며 확정 거절 시 기존 backoff를 적용한다. 이미 작성된 문구는 Enter가 거절돼도 소유 상태를 유지한다. 현재 질문·사용자 입력 우선권·자동 승인 OFF·전체 일시정지·취소·명시적 Goal 정지·원본 PID/시작/TTY/전경 검증을 유지한다. 성공·실제 작업은 이전처럼 복구를 확정한다.

- 구현: `CapacityResume.swift`의 `draftReady/VerifiedResumeInput.complete`, `ApprovalEngine.observeCapacity/restoreLegacyResumeDraft`, 호스트별 `completeResume`. `ResumeSubmissionTests.swift` 6개 검사와 원본 격리 PTY/tmux 18개 조건이 검증한다.

## 0.2.78 오류 복구 경로

- 사용자 목표: **어떤 에러가 나도 다시 재시도를 반복하며 작업을 이어나가야 한다.** `Selected model is at capacity`와 긴 `stream disconnected before completion: An error occurred while processing your request`, 줄바꿈된 모의 request ID를 포함한다. 현재 실제 Codex/Claude 오류 셀의 새 문구도 감지한다. 일반 로그·인용·실행 중인 작업·사용자 초안은 오류 셀로 취급하지 않는다.
- 연결/API 5·15·30·60·120·최대 300초, capacity 30·60·120·240·최대 480초, 인증/설정 60·120·300·최대 600초, blocked Goal 30·60·120·최대 300초. 마지막 간격을 횟수 제한 없이 반복한다. 일반 요청은 `이어서 진행하자.`, 멈춘 Goal은 `/goal resume`다. 모델·인증·결제·설정을 자동 변경하지 않으며 외부 문제가 해결되면 다음 같은 요청으로 계속한다.
- `hasLaterUserMessage == true`인 과거 질문은 재개를 막지 않으며 질문 기록/응답을 삭제하지 않는다. 현재 질문, OFF·초안·일시정지·취소·원본 PID/시작/TTY/전경·입력창 검증은 유지한다.
- 같은 원본 Codex thread에서 새 `failed` turn이 확인되면 동일 화면도 새 실패로 처리한다. 실패 turn을 전송 기록과 함께 저장해 앱 재시작 후 이전 입력을 반복하지 않는다. 실제 새 실패가 이전 미확인 전달을 해소하면 새 요청으로 계속한다. 다른 root·inProgress/completed/interrupted·동일 turn·단순 시간/줄바꿈 변경은 반복 입력의 근거가 아니다.
- `screenChanged/missingTarget/agentMissing` 및 `delivery=not_started`는 새 화면을 요구하고 간격을 늘려 계속 시도한다. CLI 종료 후 확정 미전달도 세 번으로 포기하지 않는다. 입력/복구 연결이 돌아오면 재확인한다. 증거 없는 미확인 쓰기는 반복하지 않고 상태 확인을 계속한다. 정상 종료는 재시작하지 않는다.

- 구현: `CapacityResume.swift`의 현재 오류 셀 감지, `SessionInterruption.resumeTurnIdentity`의 전송 실패-turn 기록, `ApprovalEngine.recoveryDelays/failedTurnAdvanced/retryUnsentCapacity/restartExitedSession`의 반복 복구. Codex turn은 기존 exact-thread 읽기 전용 수집을 재사용한다. 새 7개 Core 검사와 PTY/tmux 14개 조건이 경로를 검증한다.

## 0.2.77 질문 선택·원본 응답 경로 (유지)

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

- 최종 release Core **230/230**, 새 제출 복구 **6/6**, 기존 capacity **4/4**, Goal blocked **4/4** 통과. 전체 초안/숨겨진 안내/줄바꿈·앱 재시작·취소/일시정지/OFF/메모 보호·확정 Enter 거절 4회 뒤 5번째 성공·기존 Goal 감사 기록의 정확한 복원을 검사했다.
- 실제 격리 PTY/tmux **18개 조건** 통과. 추가 4개는 첫 Return이 빈 줄만 만드는 일반 요청/Goal을 두 경로에서 재현하며, 최종 수신 바이트가 문구 한 번+`CR CR`임을 검사했다. 시험 Terminal에서 `do script`는 실제 CR을 보냈고 LF가 아니었음을 확인했다. 사용자 CLI에는 시험 문자를 보내지 않았다.
- 서명된 최종 패키지의 격리 엔진과 실제 Terminal 앱의 별도 시험 창에서도 첫 Return의 줄바꿈 후 자동 복구를 확인했다. 정확한 문구 한 번·Return 두 번·저장된 소유 기록을 검사하고 시험 창/엔진만 종료했다.
- release 빌드·서명/입력 서비스 패키지·격리 웹/MCP/PTY/리소스/포트/설정 복원·DMG 마운트/파일 일치/무결성 검사 통과. 프론트엔드·Bridge 코드 변경 없음, Bridge 0.2.9 포함. 이번에 새 브라우저·시각 검사를 수행했다고 주장하지 않는다.
- 두 Mac **0.2.79/101** 확인. 원본 식별·직접 입력 **이 Mac 19개 / 다른 Mac 4개**, 로컬 원본 CLI **19개** PID/시작/TTY 및 설정·승인 기록 **15,075건** 보존. 기존 root 서비스 프로세스/파일은 재설치하지 않았다.
- 소스 태그·GitHub 정식 릴리스·DMG/체크섬 게시 및 인증 없는 다운로드 바이트 일치 확인. 소스 커밋 `002804fd574b02c23960c589bdaf804b404b2b69`. DMG SHA-256 `03c90071b34edbcf9735a71e9c0eefc3080a374437ab8075045eb7e9858f29cc`.
- 휴대폰 관리 페이지에서 **0.2.79 · 빌드 101**을 확인한다. 실제 upstream 장애를 강제로 만들지는 않았다. 제공자 상태·사용자 정의 제출 키의 모든 조합까지 성공을 보장하지 않는다.

- 회사 Wi-Fi와 핫스팟 교대 연결은 별도 미구현 사항이다. 실제 SSID/라우팅 전환은 하지 않았다.

## 유지할 사용자 요구

- 휴대폰 설치·연결 코드·외부 중계 서비스 없이 같은 핫스팟의 Mac 웹(TCP 8765)과 Mac 목록을 사용한다. 휴대폰의 localhost는 Mac이 아니다.
- 항상 같은 원본 CLI를 제어한다. 별도 PTY 이동이나 CLI 재시작으로 동기화를 대체하지 않는다.
- 평소에는 텍스트 터미널을 유지하며 화면 공유는 요청 시 보기 목적으로만 시작한다.
- 원본 식별·전경 작업·최신 화면·입력 내역을 확인한다. 미확인 입력이나 새 실패 근거가 없는 동일 화면은 자동 재전송하지 않는다.
- 자동 승인 OFF, 전체 일시정지, 취소, 초안·질문 대기를 존중한다. 명시적으로 일시정지/완료한 Goal과 예산·사용량 제한은 자동 재개하지 않는다.
- 이미 잠긴 화면을 해제하지 않는다. 관리자 암호·macOS 권한은 사용자가 직접 승인한다.
- Zscaler·SentinelOne·TCC·Gatekeeper·회사 정책을 끄거나 우회하지 않는다. 이전 suspicious:bash 이후 새 경고가 없었다는 사용자 보고는 경고 없음의 보장이 아니다.
- 유료 Apple 계정 없이 기존 발행자 서명·정상 입력 서비스를 유지한다. 0.2.73/0.2.74 설치 호환 수정의 SMJobBless·상호 서명 검증은 유지한다.
- **버전을 올렸으면 같은 작업에서 GitHub 릴리스까지 완료한다.**

## 재현 및 배포

0.2.79의 최종 release 전체 검사는 230/230 통과했다. 최적화 컴파일과 병행한 debug 전체 검사에서는 기존의 짧은 타이밍 검사 두 개가 실패해 228/230이었다. 컴파일 완료 후 release 전체 검사와 입력 거절 검사의 독립 재검사가 통과했다. 최적화 빌드는 919초 걸렸다.

GitHub 업로드 후 공개 전환 때 네트워크 오류가 발생했으나, 두 파일이 남은 초안을 확인한 뒤 게시를 완료했다. 두 Mac의 버전·원본 입력 검증은 업데이트 직후의 기록이다. 게시 중 다른 Mac이 목록에서 사라졌으므로 다음 작업에서 현재 LAN 상태를 다시 확인한다.

```sh
swift build -c release
.build/release/autoapprove-checks
node scripts/interruption-relay-check.mjs --release
node scripts/terminal-question-browser-check.mjs --release
node scripts/codex-queue-transport-check.mjs
npm --prefix extensions/vscode test
npm --prefix extensions/vscode run package
node scripts/package-app.mjs release .runtime/releases/0.2.79/submit-101/AutoApprove.app
node scripts/terminal-input-package-check.mjs .runtime/releases/0.2.79/submit-101/AutoApprove.app
node scripts/network-package-check.mjs .runtime/releases/0.2.79/submit-101/AutoApprove.app
node scripts/package-dmg.mjs .runtime/releases/0.2.79/submit-101/AutoApprove.app
```

이번 패키지 경로는 완료 기록이다. 다음 배포는 **새 버전·빌드·새 디렉터리**를 사용한다. Swift 빌드 중 Swift 소스를 바꾸지 않는다. 브라우저 검사는 설치된 Playwright/Chromium 경로를 `AUTOAPPROVE_PLAYWRIGHT_MODULE`·`AUTOAPPROVE_CHROMIUM_PATH`로 지정한다. 샌드박스로 차단된 네트워크·서명·시스템 접근은 정식 실행 승인을 사용한다.

이번 비공개 자료는 `.runtime/releases/0.2.79/submit-101/`의 `deploy.py`, `verification.json`, `network-{before,after}.json`, `verify-github.mjs`, `github-verification.json`이다. 설치 스크립트를 다시 실행해 백업을 덮어쓰지 않는다. 앱 관리자만 재시작하고 원본 CLI·정상 root 서비스·설정·기록은 전후 비교한다. 살아 있는 앱 소유 PTY가 있으면 종료 승인 전 업데이트하지 않는다.

태그는 검증한 소스 커밋에 만들고 main·태그를 push한 뒤 `gh release create`로 DMG·체크섬을 게시한다. 공개 태그·두 파일·다운로드 바이트를 확인한다. 이 Mac의 Node TLS는 Zscaler CA로 실패한 적이 있으므로 정상 시스템 TLS의 `/usr/bin/curl`을 사용하며 인증서 검사를 끄지 않는다.

## 워크스페이스 주의

- 로컬 `http://127.0.0.1:8765/api/network`에서 버전·업데이트·세션 식별·입력 키만 읽는다. 사용자 대화·전체 화면·DB·서명 키체인을 문서나 릴리스에 포함하지 않는다.
- Wi-Fi/유선 동시 연결에서도 LAN 인터페이스 출발 주소를 사용하고 VPN 인터페이스는 제외한다. 핫스팟 주소는 재연결 후 달라진다.
- `.codeidx/mcp-control.json`, `.codeidx/mcp-server.json`, 해당 임시 파일과 `.vscode/settings.json`은 별도 작업 변경이다. 덮어쓰거나 이번 릴리스에 포함하지 않는다.
- Git 전체 index를 일괄 커밋하지 않는다. 정확한 작업 경로의 `git commit --only`를 사용한다. 먼저 `git status --short`·`git log`를 확인하고 unrelated 변경을 보존한다.
