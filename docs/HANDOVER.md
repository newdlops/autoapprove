# AutoApprove 작업 인계

최종 갱신: 2026-10-12 (KST), 0.2.76 배포 완료 시점. 새 작업 전 현재 Git 및 실행 상태를 다시 확인한다.

## 현재 상태

- 프로젝트: `/Users/lky/project/autoapprove`, macOS arm64, Swift 패키지. 지침은 [AGENTS.md](../AGENTS.md), 제품 설명은 [README.md](../README.md), 검증 이력은 [VALIDATION.md](../VALIDATION.md).
- 최신 공개 배포: **0.2.76 · 빌드 98**. [GitHub 릴리스](https://github.com/newdlops/autoapprove/releases/tag/v0.2.76), 소스 태그 `v0.2.76`, 태그 커밋 `b622ecfab0db29ff6f1cc634e01dbb60f89c39ef`.
- **검사·패키징·두 Mac 적용·GitHub 게시·공개 다운로드 검증을 완료했다.** 두 Mac 모두 0.2.76/98·업데이트 idle이며 원본 세션·직접 입력 키 20개/3개를 확인했다.
- 설치 파일: `AutoApprove-0.2.76-macOS-arm64.dmg`. SHA-256: `48a93ae346c074ecc3085631fec77f8b0e5e4d1aaa425f8caff3a17c5aeb8685`. GitHub의 DMG와 체크섬을 인증 없이 다운로드해 로컬 검증 파일과 바이트 일치를 확인했다.
- 구현한 요청: `Selected model is at capacity` 오류도 자동으로 작업을 이어가기. 기존 5회 제한을 없애고 30초 → 60초 → 120초 → 240초 → 최대 480초 간격으로 계속 재시도한다. 마지막 간격은 반복한다.
- 0.2.75의 이전 목표(여러 오류 및 blocked Goal 자동 복구)는 완료 처리됐다. 새 목표를 임의로 만들거나 완료된 목표를 재개하지 않는다.

## 사용자 요구와 지켜야 할 동작

- 휴대폰에는 설치하지 않는다. 같은 핫스팟의 Mac이 웹 페이지와 다른 Mac 목록을 제공한다. 기본 TCP 포트는 8765.
- 개인 폐쇄망 사용 방식으로 연결 코드를 요구하지 않는다. 외부 중계 서비스로 대체하지 않는다.
- 휴대폰과 Mac은 **같은 원본 CLI 세션**을 제어한다. 별도 PTY로 옮기거나 기존 CLI를 재시작해서 동기화를 대체하지 않는다.
- 평소에는 텍스트 터미널을 유지하고, 화면 공유는 사용자가 요청할 때만 시작한다. 화면 공유는 보기 목적이다.
- 원본 PID·시작 시각·TTY·전경 프로세스·입력 직전 화면을 확인한다. 전달 결과가 불확실한 입력과 같은 실패 화면은 자동으로 재전송하지 않는다.
- 자동 승인 OFF, 전체 일시정지, 사용자 취소, 작성 중인 초안, 질문 응답 대기를 존중한다. 명시적으로 일시정지한 Goal, 예산/사용량 제한, 완료한 Goal을 자동 재개하지 않는다.
- 이미 잠긴 화면을 해제하지 않는다. 관리자 암호나 macOS 권한 허용은 사용자가 직접 한다.
- Zscaler·SentinelOne·TCC·Gatekeeper·회사 정책을 끄거나 우회하지 않는다. 과거 SentinelOne `suspicious: bash` 경고가 있었고 이후 새 경고는 없다고 사용자가 확인했다. 경고가 생기지 않는다고 보장하지 않는다.
- 유료 Apple 개발자 계정이 없다. 기존 발행자 서명과 정상 입력 보조 서비스를 유지한다.
- **버전을 올렸으면 GitHub 릴리스까지 같은 작업에서 완료한다.** 로컬 빌드나 설치만 하고 종료하지 않는다.

## 0.2.76에서 변경한 내용

| 경로 | 변경 |
|---|---|
| `Sources/AutoApproveCore/ApprovalEngine.swift` | capacity 시도 상한 제거. 마지막 지연 간격 반복. 현재 복구 상태의 `limit`은 0(상한 없음). |
| `Sources/AutoApproveCore/CapacityResume.swift` | 짧은 `Selected model is at capacity` 문구와 단어 중간 줄바꿈을 인식. 모델은 자동 변경하지 않음. |
| `Sources/AutoApproveApp/SessionWindow.swift` | 상한 없는 상태를 `8/0회` 대신 `8번째 시도`로 표시. 기존 구성과 취소 버튼 유지. |
| `Sources/AutoApproveCore/Resources/RemoteWeb/web-version.json` | 0.2.76 / 98. |
| `Tests/AutoApproveCoreTests/{ApprovalTests,CapacityResumeTests}.swift` | 일반 세션과 stalled Goal에서 각각 8회 오류·재개, 마지막 간격 반복, 이전 화면 재전송 방지, 취소 검증. |
| `Tests/fixtures/interruption-pane.c`, `interruption-relay-check.swift` | 실제 PTY/tmux의 capacity 및 capacity-goal 입력·Return·재활성화 검사 추가. |
| `scripts/session-recovery-browser-check.mjs` | 8번째 capacity 재시도·상한 없음·취소 버튼의 3개 화면 크기 검사 추가. |

일반 세션은 `이어서 진행하자.`를, stalled/blocked Goal은 `/goal resume`를 전송한다. 실제 재개가 확인되거나 새 실패가 나타나야 다음 시도를 예약한다. 같은 화면이 오래 남는 것만으로 입력을 반복하지 않는다. 공개 타입의 `exhausted` 값은 구버전 호환을 위해 남아 있다.

## 검증 완료와 다음 확인 항목

현재 완료:

- 수정본 DEBUG 빌드 성공.
- capacity 관련 검사 **3/3 통과**. 새 검사에서 일반 세션과 Goal 각각 8회 전송 및 이전 화면 중복 전송 방지 확인.
- 격리된 실제 PTY/tmux **6개 조건 통과**. capacity 오류의 정확한 입력·Return과 capacity Goal의 `/goal resume` 재활성화 확인.
- Chromium **7개 조건 통과**. 모바일 390×844·태블릿 768×1024·데스크톱 1440×900의 재시도 패널을 별도 시각 확인. 가로 overflow·JavaScript 오류 0건.
- 실제 네이티브 상태 컴포넌트 6개 상태 × 2개 폭(300/520pt) × light/dark를 **24개 이미지**로 렌더링하고 대표 9개 이미지를 시각 확인. 실제 터미널 입력과 권한 요청은 하지 않았다.
- release 빌드와 release PTY/tmux 6개 조건 통과. 서명 패키지의 입력 서비스 메타데이터·상호 서명, 격리 프로필의 웹·MCP·PTY·포트·설정 복원 검사, DMG 마운트·파일 일치·무결성 검사 통과.
- 최종 release Core **208/208 통과**. 로컬 0.2.76/98 설치에서 원본 CLI 20개 PID·시작 시각·TTY, 저장 설정·승인 기록 14,508건, 기존 root 입력 서비스의 프로세스·파일을 보존했다.
- 두 Mac의 0.2.76/98·업데이트 idle, 원본 식별·직접 입력 키 **20개/3개**를 최종 상태 조회로 확인했다. 로컬은 실제 설치 직전 보호 기록과 비교했다. 초기 검사 중 변경된 한 CLI는 앱 재시작 전 기록에 이미 종료 상태와 새 PID로 나타나 배포에 따른 변경과 구분했다.
- 소스 커밋·태그 push·GitHub 정식 릴리스 및 DMG/체크섬 게시 완료. 공개 태그가 위 소스 커밋을 가리키고 다운로드의 크기·바이트·체크섬이 일치함을 확인했다.
- 기존 0.2.75는 전체 핵심 검사 **207/207**, 실제 테스트 전용 PTY/tmux, 웹 3개 크기, 앱 패키지·서명·GitHub 다운로드를 확인했다. 이번 수정본의 결과와 혼동하지 않는다.

다음 실제 사용 확인:

1. 실제 capacity 오류가 발생했을 때 일반 세션/Goal의 다음 재시도 시각과 작업 재개를 관찰한다. 테스트 때문에 사용자 작업을 중단하거나 제공자 오류를 강제로 만들지 않는다.
2. 휴대폰 웹에서 재시도 상태·개별 취소·전체 일시정지·작성 중인 초안 보호를 확인한다.
3. 새로운 누락 오류나 재연결 지연이 보고되면 원본 식별·최신 화면·오류 종류·전송 확인 상태를 읽기 전용으로 조사하고, 해당 경로의 회귀 검사를 추가한다.

아직 실제 제공자의 용량 부족을 강제로 발생시키거나 휴대폰에서 직접 재시험하지 않았다. 합성 화면·테스트 프로세스 검사와 실제 사용 확인을 구분한다.

## 재현 명령과 배포

```sh
swift build -c release
.build/release/autoapprove-checks
node scripts/interruption-relay-check.mjs --release
node scripts/original-tty-adapter-check.mjs
node scripts/session-recovery-browser-check.mjs
node scripts/package-app.mjs release .runtime/releases/0.2.76/capacity-98/AutoApprove.app
node scripts/terminal-input-package-check.mjs .runtime/releases/0.2.76/capacity-98/AutoApprove.app
node scripts/network-package-check.mjs .runtime/releases/0.2.76/capacity-98/AutoApprove.app
node scripts/package-dmg.mjs .runtime/releases/0.2.76/capacity-98/AutoApprove.app
```

위 명령은 이번 검증 기록이다. 다음 버전의 패키징에는 버전·빌드·출력 디렉터리를 모두 바꾼다. 브라우저 QA는 설치된 Playwright 모듈과 Chromium 경로를 `AUTOAPPROVE_PLAYWRIGHT_MODULE`·`AUTOAPPROVE_CHROMIUM_PATH`로 지정해야 한다. 이미지와 시험 데이터는 무시된 `dist/qa/`·`.runtime/`에만 둔다. 네트워크·서명·GUI·시스템 접근이 샌드박스로 차단되면 정식 실행 승인을 사용한다.

이번 배포 자료는 비공개 로컬 `.runtime/releases/0.2.76/capacity-98/`의 `deploy.py`, `verification.json`, `inspect-network.mjs`, `network-{before,after}.json`, `verify-github.mjs`, `github-verification.json`에 있다. 같은 배포의 설치 스크립트를 다시 실행하지 않는다. 다음 버전의 **새 디렉터리**로 복사·수정하고 이전 백업 파일을 덮어쓰지 않는다. 보조 서비스·설정·승인 기록·원본 PID/시작 시각/TTY를 전후 비교하며, 앱 관리 프로세스만 재시작한다.

태그와 배포 명령 예시(이번 버전은 완료; 새 배포 시 버전·커밋·경로 변경):

```sh
git tag -a v0.2.76 <검증한-소스-커밋> -m 'AutoApprove 0.2.76 build 98'
git push --atomic origin main refs/tags/v0.2.76
gh release create v0.2.76 dist/AutoApprove-0.2.76-macOS-arm64.dmg dist/AutoApprove-0.2.76-macOS-arm64.dmg.sha256 --repo newdlops/autoapprove --verify-tag --title 'AutoApprove 0.2.76' --notes-file <릴리스-설명-파일> --latest
```

GitHub 다운로드는 정상 시스템 TLS를 사용하는 `/usr/bin/curl`로 검증한다. 이 Mac의 Node TLS는 Zscaler CA 때문에 실패한 적이 있다. 인증서 검사를 끄지 않는다.

## 환경 및 워크스페이스 주의

- 로컬 상태 API: `http://127.0.0.1:8765/api/network`. 온라인 노드의 버전·업데이트·세션 메타데이터만 읽는다. 전체 화면·사용자 대화·DB를 문서나 배포에 넣지 않는다.
- 마지막 실제 확인은 두 Mac 모두 0.2.76/98, 로컬 원본 CLI 20개와 다른 Mac 원본 CLI 3개, 모두 직접 입력 연결 가능 상태였다. 접속 주소와 세션 수는 변하므로 다시 조회한다. 사용자 세션에 실제 테스트 문자를 전송한 확인은 아니다.
- Wi-Fi와 유선이 함께 연결돼도 LAN 탐색·중계는 해당 인터페이스의 출발 주소를 사용하며 VPN 인터페이스는 제외한다. hotspot 주소는 재연결 후 달라질 수 있다. 휴대폰의 `localhost`는 Mac이 아니다.
- 0.2.73/0.2.74의 입력 서비스 설치 수정은 SMJobBless·상호 서명 검증을 사용한다. 신규 설치는 서명된 패키지 앱과 Mac의 사용자 관리자 승인이 필요하다. 현재 정상 서비스는 재설치하지 않는다.
- 이번 릴리스 소스 커밋은 `b622ecf`이며 문서 완료 기록은 후속 커밋에 남긴다. 이후 작업에서는 먼저 `git status --short`와 `git log`를 확인한다.
- `.codeidx/mcp-control.json`, `.codeidx/mcp-server.json` 및 해당 임시 파일은 **별도 작업의 변경**이다. 덮어쓰거나 이번 릴리스에 새로 포함하지 않는다. 이미 커밋된 VS Code·MCP 설정 변경도 되돌리지 않는다.
- 전체 index를 일괄 커밋하지 않는다. 정확한 작업 경로를 지정한 `git commit --only`를 사용한다. 키체인·서명 비밀·개인 시험 자료·사용자 터미널 내용은 절대 게시하지 않는다.
