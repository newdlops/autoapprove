# Codex Login Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline, followed by one fresh whole-branch review.

**Goal:** Correct empty-conversation account inspection and let the user start Codex login inside AutoApprove.
**Architecture:** Classify exact official RPC rejection, retaining the fresh idle barrier. Reuse AgentAccounts jobs for native login, with per-job scoped services and shared exclusion. Native settings polls a typed local snapshot; remote envelopes cannot access its owner.
**Tech Stack:** Swift, SwiftUI, private PTY, JSON-RPC, installed Codex 0.166.0.
**Spec:** ../specs/2026-11-03-codex-login.md

## Global Constraints
No production account changes or Codex restart as QA. Preserve interruption reservations. Official device URL allowlist. Existing automatic-transition opt-in. Release 0.2.232/build259 with DMG/checksum and signed ZIP/checksum.

## Review Focus
- Idle-to-active race must reject an empty-turn exception.
- Unrelated -32600 and wrong-thread errors must fail closed.
- Native challenges must remain inaccessible to remote owners.
- Native and remote simultaneous login must not launch two jobs.
- Selected home and executable must survive spaces and shell metacharacters literally.

### Task 1: Empty conversation inspection
- [x] Extend Unix transport fixture for exact unmaterialized rejection, active race, other code/message/thread; run RED.
- [x] Add typed RPC error and strict idle fallback, retaining all barriers; run GREEN and isolated official daemon inspection.

### Task 2: Native login
- [x] Add failing tests for native scoped login, remote isolation/shared exclusion/cancel/private TTY; observe RED.
- [x] Reuse job loop with per-job service and native owner; scoped CLI launch uses literal arguments/environment; run GREEN.
- [x] Add native settings login section using current system styling, selected home, code/copy/open/cancel/status; inspect synthetic native rendering/interactions.

### Task 3: Verification and publication
- [x] Run relevant/full checks and release build; one independent whole-branch review; fix important findings with RED→GREEN. Debug652/652, release633/633, transition13/13, login6/6; one Important fixed before effects.
- [ ] Bump matching metadata, commit, sign/package/check, push/tag/release; verify four public assets and installed running app, original sessions retained.
