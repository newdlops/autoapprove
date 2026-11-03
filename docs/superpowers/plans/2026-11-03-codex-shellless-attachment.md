# Shell-less Codex Attachment Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan inline, task by task.

**Goal:** Connect login → Codex sessions with a prevalidated replacement tab in the same window.
**Architecture:** Extend the persisted attachment state with preparation and ambiguous-tab reservations. Inject replacement-shell creation/validation through the existing screen adapter. Reuse TerminalProfileTabOpener and retain the existing original-shell path.
**Tech Stack:** Swift, Foundation, existing Terminal automation/AX, SQLite, app-owned PTYs.
**Spec:** ../specs/2026-11-03-codex-shellless-attachment-design.md

## Global Constraints

- Apple Silicon Mac, macOS 14+, official Codex 0.166.0+.
- Preserve exact conversation/home/cwd and window grouping; user approved one-time tab replacement.
- No repeated ambiguous tab/exit/launch input; no forced exit of active work, Goal, draft or question.
- Preserve unrelated changes and finish matching build, commit, release assets, public verification and installed-version/process check.

## Review Focus

- Direct login → CLI ancestry must not fabricate a shell.
- Missing permission, wrong window or busy replacement leaves the original CLI alive.
- App restart during tab preparation must not duplicate tabs.
- A different TTY requires exact replacement shell and same-thread connection proof.
- Future restore commands must retain a real interactive shell, including after CLI exit.

## Task 1: Persisted replacement preparation

Files: Sources/AutoApproveCore/CodexSessionAttachment.swift; Tests/AutoApproveCoreTests/CodexSessionAttachmentTests.swift.
- [x] Add failing tests for prepare-before-exit, replacement identity persistence, opening ambiguity and busy/wrong replacement.
- [x] Add optional original login identity and replacement marker, preparation/reservation phases and an optional preparation service returning ProcessRecord.
- [x] Preserve backward decoding and single-use exit/launch behavior; run attachment checks.

## Task 2: Engine and Terminal integration

Files: Sources/AutoApproveCore/ApprovalEngine.swift; TerminalAdapter.swift; new CodexReplacementTab.swift; Tests/fixtures/codex-session-engine-check.swift; scripts/codex-session-engine-check.mjs.
- [x] Reproduce no-shell blocking using a real direct-owned CLI PTY and injected login ancestry.
- [x] Provision a distinct owned shell PTY through injected adapter services; assert prepare 1, exit 1, resume 1 and actual same-thread server connection.
- [x] Add native Terminal adapter creation using the existing same-window opener and empty shell proof; revalidate grouping before exit.
- [x] Update original-exit vs replacement-launch TTY guards and hold both streams through verification.
- [x] Exercise wrong window, busy shell, ambiguous opening and restart: original survives and no replay.

## Task 3: Future restoration and release

Files: Sources/AutoApproveCore/TerminalSessionProfile.swift; Tests/AutoApproveCoreTests/TerminalProfileTests.swift; release docs/version/VALIDATION.md.
- [x] Test and remove Codex-only `exec` from restoration commands; retain Claude behavior.
- [x] Run Debug/Release account, attachment, profile/opener and actual-owned-PTY checks; review the final diff.
- [ ] Package matching version, publish DMG/signed ZIP/checksums, re-download verify and install via existing updater.
- [ ] Verify running version, original kernel PID/start/TTY preservation and hooks; publish final validation record.

## Execution ledger

- User selected same-window tab replacement; the spec records that decision and the already authorized preparation-before-exit flow. No additional approval is needed for these implementation details.
- No real user Terminal input is used as QA; unavailable real native integration remains an explicit limitation.
- Ruling: retained separate-job protection for automatic attachment after review. An explicit reconnect may authorize only the exact recognized tool-host PID/start/executable/TTY/parent/process-group cohort captured at that action, scoped to original session/home. Clear grants after exit/review and on engine restoration; new hosts or other descendants block. Existing reconnect flow already discloses background work shutdown; add specific visible tool-host wording. This avoids treating names as idle evidence while supporting the user-requested explicit stop/reconnect action.

- Cancellation, timeout and every explicit request return revoke unused grants. A consumed grant becomes a read-only shutdown witness, which blocks launch until each original PID/start identity has actually disappeared. The slow-shutdown and canceled-request regressions were reproduced before the fixes.
- Default profiles that start a program instead of an empty shell remain unsupported for replacement preparation; preserve the original session and explain failure. Native Terminal replacement was not exercised on a user session.
