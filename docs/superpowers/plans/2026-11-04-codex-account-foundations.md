# Codex Account Foundations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Remove the confirmed login-shell bottleneck, make account inspection genuinely observational and independently usable, and establish actual cross-home preservation evidence for the full account-group objective.

**Architecture:** Resolve a bounded literal CLI execution context once, prefer a verified native executable and existing process PATH, and reuse a single fallback shell environment for wrappers. Keep observation independent of account transition mutations and give native UI read and mutation states separate lifetimes. Cross-home session migration remains a separate phase gated on exact conversation/Goal preservation evidence.

**Tech Stack:** Existing Swift/Foundation/SwiftUI, Darwin, CSQLite, Node QA scripts and owned native/PTY/socket fixtures; no dependencies.

**Spec:** docs/superpowers/specs/2026-11-04-codex-account-groups-design.md

## Global Constraints

- Full objective remains login checks, account changes, independent-session merge and split, speed and stability; this foundation milestone is not goal completion.
- Codex 0.166.0 minimum; Apple Silicon Macs; do not hardcode developer homes, PIDs or executable paths in product code.
- Queries must not log in/out, interrupt/restore Goals or turns, start/restart daemons, or enable account transitions.
- Preserve source UUID, history, configuration and Goal identity/budget/usage; do not substitute a fork or reset counters.
- Unknown mutation delivery is observed rather than replayed; unselected sessions retain their account and execution.
- Release verified improvements through matching source/build/signed DMG+ZIP+SHA256/GitHub release/public verification/local install; verify the other Mac when available.
- Preserve unrelated main-checkout drafts and all private credentials/runtime artifacts.

## Review Focus

- GUI PATH versus nvm wrappers and arbitrary startup banners: retain execution compatibility without repeated shell initialization.
- Cancellation and changed process/home/executable while inspecting: stale successes must not become current authorization.
- Readonly account check while automatic switching is enabled: observation alone must have no transition effects.
- Slow/failed lookup while the user selects a different home or begins login: result and loading state must remain scoped.
- Cross-home resume and Goal counters: no shared writable rollout or silently reset Goal may pass as migration.

---

### Task 1: Literal reusable CLI execution context

**Files:** Create Sources/AutoApproveCore/CodexCLIContext.swift; modify CodexManagedServer.swift and AgentAccountServices.swift; tests Tests/fixtures/codex-cli-context-check.swift, Tests/fixtures/codex-native-cli.c, scripts/codex-cli-context-check.mjs.

**Interfaces:** Produces CodexCLIContext with resolved executable/environment and run(_ arguments:[String],timeout:TimeInterval) throws -> CommandResult. Consumes existing CommandRunner, ProcessRecord and CodexServerLocation witnesses.

- [x] Write an owned fixture with a Mach-O fake CLI, a PATH-dependent wrapper and a slow/banner-producing .zshrc; assert native inspection initializes zero shells, wrapper inspection at most one, all three real service commands still run with exact selected home and literal arguments.
- [x] Run the fixture against current production objects and observe the repeated-shell assertion fail.
- [x] Implement native recognition/ownership/path validation and a bounded marker-delimited fallback PATH/executable lookup once per context; preserve only relevant PATH from exact live witnesses. Execute argument arrays directly and propagate cancellation without replay.
- [x] Reuse the context in managed-server inspection/preparation and scoped Codex login status; preserve Claude behavior.
- [x] Verify fixture, existing managed-server cases, native login ownership/path/cancellation cases, Account and Diagnostics filters; commit source and ledger evidence.

### Task 2: Readonly observation separate from transition control

**Files:** Create Sources/AutoApproveCore/CodexAccountInspection.swift; modify ApprovalEngine.swift and CodexSessionAccount.swift; tests in CodexAccountTransitionTests.swift or a focused new account-inspection test file registered in ApprovalTests.swift.

**Interfaces:** Produces a home-scoped inspection result containing connected identity, saved identity when safely available, verified session membership, observed timestamp and partial failure. ApprovalEngine.inspectCodexAccount(home:) async throws returns this result without calling a coordinator advance method.

- [x] Write an injected service/engine regression where saved and server accounts differ and auto transition is enabled; a new inspection must return mismatch with zero interrupt/restart/resume/config writes.
- [x] Observe the old check/control coupling fail in a focused fixture.
- [x] Implement keyed in-flight read coalescing and stale-home/process invalidation. A cancelled reader must not cancel an unrelated consumer or permit an old read to authorize a mutation.
- [x] Keep existing explicit reconnect and automatic transition paths; make their names/entry points distinct from the read API.
- [x] Verify mismatch, missing login, offline/unverified server, two homes, concurrent readers, stop/cancel and existing transition/Goal suites; commit and ledger evidence.

### Task 3: Independently responsive native account UI

**Files:** Modify CodexLoginSettings.swift, CodexAccountTransitionSettings.swift, CodexAccountsWindow.swift and CodexSessionAccountView.swift; extend existing account preview fixtures/scripts and DESIGN.md.

**Interfaces:** Consumes Task 2 inspection state and Task 1 fast status; separate loadingTargets, loadingServer and mutation state, with current-home generation guards.

- [x] Extend the owned account UI fixture to hold a server lookup open while login remains operable and to change homes before an older result returns; observe current combined-loading behavior fail.
- [x] Separate readonly confirmation from reconnect/automatic switching. Display known identity/last successful time, mismatch or partial failure; keep target-specific mutation controls scoped.
- [x] Preserve system components, account icon, 600×660 scrolling and accessibility names; cover long content, failure, waiting, stale data, active login and cancellation.
- [x] Exercise actual synthetic native controls and independently inspect light/dark rendering; run relevant Core and UI regressions; commit and ledger evidence.

### Task 4: Cross-home feasibility evidence for the full goal

**Files:** Create an owned-only fixture/script under Tests/fixtures and scripts; update the spec with verified protocol findings and retain private detailed data under .runtime/login-goal.

**Interfaces:** Consumes actual installed 0.166 CLI and generated schema. Produces a machine-readable report proving or contradicting same UUID, independent rollout, effective settings and exact Goal instance/budget/usage/time.

- [x] Build a failing preservation oracle over two owned homes and a synthetic conversation/Goal with nonzero usage. Never use a user conversation or auth contents.
- [x] Test documented path resume behavior without inference, background work or credential copying; compare before/after identities and writes.
- [x] If public import does not preserve required data, record the precise gap and design the version/schema-validated transfer contract before implementing migration. Do not claim this task implements merge/split.
- [x] Specify two-home durable ownership, selected cohort and recovery interfaces in the next migration plan using the observed result; retain all full-goal acceptance requirements.

### Task 5: Verify, review, release and measure the foundation

**Files:** Relevant tests, docs/releases/v0.2.250.md, web-version.json, VALIDATION.md; private signing/release verification helpers.

- [x] Freeze source, run Debug/Release builds and appropriate account/Goal/attachment/diagnostic/MCP checks plus new owned fixtures; run the project check command once and investigate any failure.
- [x] Obtain a fresh whole-branch source review and fix Important/Critical findings through RED→GREEN.
- [x] Package matching 0.2.250/build277 with the existing publisher; verify all packages, tag/source, four public assets and public download signature/hash/version.
- [x] Install locally and on the connected Mac, preserving original kernel session identities and existing hooks; measure fresh inspection latency and verify queries do not cause transitions.
- [x] Record exact verified scope, remaining merge/split/account-selection work and full-goal status; commit/push validation. Do not mark the overall goal complete.

## Execution ruling

The active user goal and explicit continuation authorize the confirmed existing-behavior fixes in Tasks 1–3; the requested goals and already selected preservation behavior are unchanged. No claim is made that an unanswered design question is approval. New cross-home mutation architecture is gated on Task 4 evidence and its reviewed contract. Implementation is inline because these shared engine/UI interfaces are coupled; one independent source review precedes release.

## Next migration plan — owned Goal preservation gate

This section is the next bounded feasibility plan, not authorization to migrate user conversations. The full account-group spec remains binding. Keep inline execution and the existing isolated worktree; preserve the shipped 0.2.250 source tag.

### Task 6: Exact Goal row preservation in two owned homes

**Files:** Create `Sources/AutoApproveCore/CodexGoalTransferStore.swift` and `Tests/AutoApproveCoreTests/CodexGoalTransferTests.swift`; extend `scripts/codex-cross-home-preservation-check.mjs` and the check registry.

**Interfaces:** `CodexGoalTransferSnapshot: Codable, Sendable` contains canonical home/database identity, CLI/schema fingerprint, thread UUID, exact typed Goal row and capture digest. Internal `CodexGoalTransferStore.capture(home: String, threadID: String) throws -> CodexGoalTransferSnapshot?` reads a quiescent owned source. Internal `restore(_:toHome: String, expectedSchema: String) throws` performs insert-only destination transaction; no production IPC/UI entry point yet.

- [x] Write an owned fixture assertion requiring destination goal/get and DB row to equal the original goal_id/objective/status/token_budget/tokens_used/time_used_seconds/created_at_ms/updated_at_ms, including tokens37/time19/budget1234 and paused status. Observe public resume alone fail this oracle.
- [x] Capture actual owned goals DB schema/version and all columns. Add tests rejecting unknown versions/columns, non-regular/symlink-replaced DBs, changed source digest, malformed UUIDs and any existing destination Goal; no replace/upsert or goal/set fallback.
- [x] Implement typed exact snapshot and insert-only restore before destination thread loading. Use bounded SQLite transactions and compare source/destination file identities before commit. Persist no auth, rollout content or raw DB data to public inventory.
- [x] Extend the actual 0.166 probe to restore before resume, compare exact DB rows plus public goal/get, nonempty history, effective settings and independent rollout. Transfer back to a third owned home and verify exact Goal identity/counters again. Existing unrelated destination thread/Goal/server must remain unchanged without daemon restart.
- [x] Run the new `Goal transfer:` filter, actual owned preservation script, existing Account/Goal suites and commit evidence. If public runtime cannot observe the restored row without disturbing unselected sessions, record that precise gap and keep production migration unavailable.

### Task 7: Two-home ownership journal and recovery contract

**Files:** Create `Sources/AutoApproveCore/CodexMigrationJournal.swift`, `Sources/AutoApproveCore/CodexSessionMigration.swift` and `Tests/AutoApproveCoreTests/CodexSessionMigrationTests.swift`; extend AuditStore with a migration journal and register checks.

**Interfaces:** `CodexSessionMigrationRequest` identifies exact selected client cohort, all its threads/children, source/destination identities and intended account/workspace. `CodexSessionMigrationState` persists stage, writer ownership, snapshots and unknown-delivery observations. `CodexSessionMigrationCoordinator.prepare(_:)`, `advance(id:)`, `cancel(id:)` consume injected observation/transfer/launch services; production service binding remains gated.

- [x] Prove the shared journal first: exact two-home mirrors, sorted physical-home locks, central compare-and-swap revision, private atomic files, partial-write repair, restart ownership and terminal-only release. Reserve and attempted markers must be distinct; no native effect is allowed unless central and both mirrors agree.
- [x] Add the internal prepare-only cohort gate: typed account/workspace and backend identities, exact client PID/start/TTY and child-thread membership, input/configuration barriers, independent reverse-request locks, reserved versus prepared revisions, fresh post-reservation verification and cancellation-ignoring observer recovery. Seven coordinator tests and eight journal tests pass. Actual ownership stays at the source; no native effect or UI/IPC binding is provided.
- [ ] Establish native per-client ownership evidence for every selected/offscreen/child conversation and shared subscribers. Inspect the installed 0.166 protocol before implementing effect-producing adapters; cwd or one visible conversation is not complete membership proof.
  - Native three-connection evidence and ephemeral side-fork test now exist in `scripts/codex-client-ownership-check.mjs`; see `docs/superpowers/specs/2026-11-04-codex-client-ownership-evidence.md`. Loaded IDs permit shared subscribers; a side fork is outside the root's parent/session tree. This disproves those shortcuts and does not complete the ownership gate. A native producer must explicitly establish client-side relations before setting completeness flags.
- [ ] Verify the existing current-login reconnect path with an owned real TUI and managed server: an active Goal pauses, the same client/cohort reconnects, only interrupted work continues once, and previously waiting work stays waiting. Synthetic account metadata must not be claimed as real authentication.
- [ ] Write injected RED tests for two clients owning one conversation, changed selected membership, drafts/questions/queued/background work, Goal identity change, non-independent credentials/server backend and reversed-home concurrent requests; all must reject with zero termination/import/launch effects.
- [ ] Implement deterministic canonical-home lock order and a durable two-home journal before effects. Source close/flush verification must precede independent import. For a live shared server, persist an explicit archive intent and verify loaded absence plus rollout writer closure; unsubscribe acknowledgement alone is insufficient. Unknown archive delivery must be observed, never replayed; only one writer may be launched. Persist selection/destination mappings so app restart and saved restoration cannot relaunch the old owner.
- [ ] Test crashes before/after every journal/import/launch boundary. Unknown launch delivery must query for exact ownership and never replay or automatically relaunch the source. Cancel before effects releases locks; after effects it preserves known ownership for review.
- [ ] Add exact retired-owner receipts and destination mappings before supporting A→B→A. The direct-return oracle must retain newer73 tokens/29s over the known retired37-token copy, preserve a backup, reject unrelated/changed target rows, and keep a cleared source Goal absent rather than resurrecting the old target Goal. Do not bypass this by always making new homes.
- [ ] Verify nondefault reasoning/tier/instruction/plugin settings with native response/runtime evidence; matching default fields is insufficient.
- [ ] Use owned clients and two real servers to prove unselected destination sessions keep their kernel identities/account/Goal. Then obtain the next architecture/source review before binding this coordinator to user sessions.

Remaining full-goal work after these gates: saved-account/workspace/SSO handling with actual credential isolation, selected-session group UI and durable mappings, exact-source Goal pause/one continuation, actual selected merge/split round trip, human-completed authentication where needed, release/install and cross-Mac verification. These requirements are not discharged by the 0.2.250 foundation release.

