# Codex account transition implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** 외부 로그인 변경 뒤 작업을 하나씩 정상 중단하고 모두 대기하면 공통 서버를 전환해 기존 대화 연결을 유지한다.

**Architecture:** CODEX_HOME별 coordinator가 주입된 RPC·공식 CLI 서비스와 비공개 journal을 사용한다. 현재 서버와 별도 stdio 조회 프로세스의 안정된 계정 키를 비교한다. ApprovalEngine은 전환 동안 Codex 입력을 억제하고 기존 연결 설정에 상태·설정을 노출한다.

**Tech Stack:** Swift 6 (language 5), Foundation, SwiftUI, CryptoKit, existing user-owned Unix WebSocket RPC.

**Spec:** docs/superpowers/specs/2026-11-02-codex-account-transition-design.md

## Global Constraints

- 공식 관리형 로컬 서버 0.166.0 이상, 홈별 독립 처리. 저장 인증 직접 읽기·토큰 복사 금지.
- 사용자 TUI 종료·키 입력·새 프롬프트·thread/resume 금지. 정확한 threadId/turnId로 정상 중단.
- 부분 조회·unknown·queue·백그라운드 작업·활성 Goal은 restart 허용 조건이 아니다.
- side effect 전에 영속 reservation. 불확실한 요청은 자동 재전송하지 않는다.
- 기본 꺼짐, 자동 승인과 독립. 기존 native UI 유지. 생산 서버를 QA로 재시작하지 않는다.
- 미완료 알림 수정은 보존. 소스 커밋·전체 검사·동일 빌드·GitHub 릴리스·설치까지 완료.

## Review Focus

- 재로그인 중 일시 로그아웃과 같은 계정 토큰 갱신이 작업을 중단하지 않아야 한다.
- interrupt 승인과 실제 종료 사이 지연, 새 turn 또는 loaded 대화 발생은 안전하게 보류해야 한다.
- 앱 재시작·두 번째 로그인 변경·timeout에도 interrupt/restart를 반복하지 않아야 한다.
- CLI 교체 또는 다른 CODEX_HOME 서버로 바뀌면 잘못된 서버에 명령하지 않아야 한다.
- 기존 TUI의 새 socket 연결과 정확한 대화 증거가 없으면 완료를 주장하지 않아야 한다.

### Task 1: Serial coordinator and durable reservations

**Files:** Create Sources/AutoApproveCore/CodexAccountTransition.swift and Tests/AutoApproveCoreTests/CodexAccountTransitionTests.swift. Modify ApprovalTests.swift registration.
**Interfaces:** Produces Codable CodexAccountTransitionState; @MainActor CodexAccountTransitionCoordinator with async check(), enabled, held, injected CodexAccountTransitionServices (observe, interrupt, restart, verify) and save closure.

- [ ] Write tests for serial interrupt → observed idle → next interrupt → fresh barrier → single restart → verified reconnect; delayed ack, same account, signed out, queue/background/goal blocking, changed turn/membership, stale socket, errors, overlapping checks, restored reservation, second account change, save failure.
- [ ] Build/run `autoapprove-checks --filter 'Account transition'`. Expected: assertion failures with minimal scaffolding.
- [ ] Implement transitions, before-effect persistence, error hold, bounded wait and cancellation of unsubmitted transition. Uncertain effects never automatically repeat.
- [ ] Run filtered checks. Expected: all pass. Commit coordinator and tests.

### Task 2: Local RPC and managed daemon adapter

**Files:** Create Sources/AutoApproveCore/CodexAccountTransitionServices.swift; Tests/fixtures/codex-account-transition-transport.swift; scripts/codex-account-transition-check.mjs.
**Interfaces:** Consumes Task 1 service types. Produces CodexAccountTransitionServices.live, strict metadata/thread snapshot parsing, server target discovery/verification.

- [ ] Write failing fixtures for accountSession/list and exact turn/interrupt, all loaded pagination, malformed data, queue/background/goal barriers, socket identity, owned stdio metadata query and restart arguments. Assert forbidden resume/input methods absent.
- [ ] Implement bounded owned CLI stdio metadata query, existing secure Unix RPC, managed version/owner validation, fresh barrier before side effects and official restart once.
- [ ] Run transport fixture and coordinator filter. Expected: pass. Characterize isolated official CLI without production auth/session mutation. Commit adapter and tests.

### Task 3: Engine hold and native settings

**Files:** Modify ApprovalEngine.swift, ConnectionSettings.swift; create CodexAccountTransitionSettings.swift and engine/UI fixtures.
**Interfaces:** Consumes coordinator status/hold. Produces persistent opt-in toggle and check/cancel controls, 30-second periodic checks of active homes and 2-second draining confirmation.

- [ ] Write failing integration checks proving hold blocks automatic approval/error recovery/progress and remote messages while preserving configured automatic flags; same account and signed out do not hold. Verify default-off persistence and recovered journals.
- [ ] Integrate engine lifecycle and common input guards; cancel automatic jobs before drain, recheck at dispatch. Add standard SwiftUI toggle, progress, counts, reason and accessible controls.
- [ ] Run affected filters and build. Expected: pass. Render synthetic native states, exercise controls and inspect loading/error/success/overflow/focus. Commit integration.

### Task 4: Review and release

**Files:** matching version metadata, release notes and packaging artifacts.
**Interfaces:** whole feature range from 706a389.

- [ ] Run full core suite and transport/engine/native checks. Expected: no failures.
- [ ] Request one fresh-context whole-branch review; fix important findings with regression checks, rerun affected/full checks.
- [ ] Build matching app/CLI/helper, signed DMG and update ZIP with SHA-256. Publish source/tag/release and verify public redownload. Install and verify running version retaining original CLI identities.
