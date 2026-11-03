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

- [ ] Write an owned fixture with a Mach-O fake CLI, a PATH-dependent wrapper and a slow/banner-producing .zshrc; assert native inspection initializes zero shells, wrapper inspection at most one, all three real service commands still run with exact selected home and literal arguments.
- [ ] Run the fixture against current production objects and observe the repeated-shell assertion fail.
- [ ] Implement native recognition/ownership/path validation and a bounded marker-delimited fallback PATH/executable lookup once per context; preserve only relevant PATH from exact live witnesses. Execute argument arrays directly and propagate cancellation without replay.
- [ ] Reuse the context in managed-server inspection/preparation and scoped Codex login status; preserve Claude behavior.
- [ ] Verify fixture, existing managed-server cases, native login ownership/path/cancellation cases, Account and Diagnostics filters; commit source and ledger evidence.

### Task 2: Readonly observation separate from transition control

**Files:** Create Sources/AutoApproveCore/CodexAccountInspection.swift; modify ApprovalEngine.swift and CodexSessionAccount.swift; tests in CodexAccountTransitionTests.swift or a focused new account-inspection test file registered in ApprovalTests.swift.

**Interfaces:** Produces a home-scoped inspection result containing connected identity, saved identity when safely available, verified session membership, observed timestamp and partial failure. ApprovalEngine.inspectCodexAccount(home:) async throws returns this result without calling a coordinator advance method.

- [ ] Write an injected service/engine regression where saved and server accounts differ and auto transition is enabled; a new inspection must return mismatch with zero interrupt/restart/resume/config writes.
- [ ] Observe the old check/control coupling fail in a focused fixture.
- [ ] Implement keyed in-flight read coalescing and stale-home/process invalidation. A cancelled reader must not cancel an unrelated consumer or permit an old read to authorize a mutation.
- [ ] Keep existing explicit reconnect and automatic transition paths; make their names/entry points distinct from the read API.
- [ ] Verify mismatch, missing login, offline/unverified server, two homes, concurrent readers, stop/cancel and existing transition/Goal suites; commit and ledger evidence.

### Task 3: Independently responsive native account UI

**Files:** Modify CodexLoginSettings.swift, CodexAccountTransitionSettings.swift, CodexAccountsWindow.swift and CodexSessionAccountView.swift; extend existing account preview fixtures/scripts and DESIGN.md.

**Interfaces:** Consumes Task 2 inspection state and Task 1 fast status; separate loadingTargets, loadingServer and mutation state, with current-home generation guards.

- [ ] Extend the owned account UI fixture to hold a server lookup open while login remains operable and to change homes before an older result returns; observe current combined-loading behavior fail.
- [ ] Separate readonly confirmation from reconnect/automatic switching. Display known identity/last successful time, mismatch or partial failure; keep target-specific mutation controls scoped.
- [ ] Preserve system components, account icon, 600×660 scrolling and accessibility names; cover long content, failure, waiting, stale data, active login and cancellation.
- [ ] Exercise actual synthetic native controls and independently inspect light/dark rendering; run relevant Core and UI regressions; commit and ledger evidence.

### Task 4: Cross-home feasibility evidence for the full goal

**Files:** Create an owned-only fixture/script under Tests/fixtures and scripts; update the spec with verified protocol findings and retain private detailed data under .runtime/login-goal.

**Interfaces:** Consumes actual installed 0.166 CLI and generated schema. Produces a machine-readable report proving or contradicting same UUID, independent rollout, effective settings and exact Goal instance/budget/usage/time.

- [ ] Build a failing preservation oracle over two owned homes and a synthetic conversation/Goal with nonzero usage. Never use a user conversation or auth contents.
- [ ] Test documented path resume behavior without inference, background work or credential copying; compare before/after identities and writes.
- [ ] If public import does not preserve required data, record the precise gap and design the version/schema-validated transfer contract before implementing migration. Do not claim this task implements merge/split.
- [ ] Specify two-home durable ownership, selected cohort and recovery interfaces in the next migration plan using the observed result; retain all full-goal acceptance requirements.

### Task 5: Verify, review, release and measure the foundation

**Files:** Relevant tests, docs/releases/v0.2.250.md, web-version.json, VALIDATION.md; private signing/release verification helpers.

- [ ] Freeze source, run Debug/Release builds and appropriate account/Goal/attachment/diagnostic/MCP checks plus new owned fixtures; run the project check command once and investigate any failure.
- [ ] Obtain a fresh whole-branch source review and fix Important/Critical findings through RED→GREEN.
- [ ] Package matching 0.2.250/build277 with the existing publisher; verify all packages, tag/source, four public assets and public download signature/hash/version.
- [ ] Install locally and on the connected Mac, preserving original kernel session identities and existing hooks; measure fresh inspection latency and verify queries do not cause transitions.
- [ ] Record exact verified scope, remaining merge/split/account-selection work and full-goal status; commit/push validation. Do not mark the overall goal complete.

## Execution ruling

The active user goal and explicit continuation authorize the confirmed existing-behavior fixes in Tasks 1–3; the requested goals and already selected preservation behavior are unchanged. No claim is made that an unanswered design question is approval. New cross-home mutation architecture is gated on Task 4 evidence and its reviewed contract. Implementation is inline because these shared engine/UI interfaces are coupled; one independent source review precedes release.

