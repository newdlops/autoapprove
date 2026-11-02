# Codex post-transition continuation implementation plan

> Use superpowers:executing-plans inline, then one fresh whole-branch review. Base: 0ecf7f6.

**Goal:** A verified account switch reconnects the original sessions and continues only the work this switch interrupted, without making the user clear a spurious review or click every session.

**Architecture:** Keep the existing durable stop/restart coordinator. Permit read-only verification of a reserved restart after a temporary discovery gap or app restoration; never resend a reserved restart. Add a durable resuming phase after account/server/history/process verification. Capture original root-thread metadata and Goal identity before stopping. Reserve each continuation before dispatch, restore an originally active Goal with its existing objective/budget, or start one continuation turn for an originally running ordinary conversation. Idle/previously paused/completed work remains untouched. Unacknowledged continuations never replay.

**Approach:** Automatic continuation is the user's requested behavior. A bulk manual button would retain the extra handoff they reported; merely hiding the error would leave work stopped. Keep the existing native progress layout and add a clear continuation state, without another confirmation flow.

**Evidence:** Live journal had a five-process restart reservation marked review because discovery temporarily returned no target; this blocks all generated and manual Codex input. Four no-effect unsupported journals were absent from the current one-server/five-process inventory. Their stored turns/list errors remain displayed although current loaded-thread history reads all succeed. The user manually cancelled the review during diagnosis. Official source confirms Goal activation can start an idle turn, so do not also submit a continuation prompt for that Goal.

**Constraints:** Preserve the original PID/start/TTY, conversation, cwd/model and drafts. No user account/server mutations as QA. Use owned same-account fixtures and a local synthetic model. Existing cancellation and uncertain-effect journals remain durable. No shared-session account isolation in this change. Changes to native UI use ui-design-workflow and existing controls; no new design system.

## Review focus

- Discovery gaps within the 120-second reconnect window and restored restart reservations must not cause a repeated stop/restart.
- Only actually reserved work from a new continuation-enabled transition may resume; old journals and initially idle/paused threads must not acquire authorization.
- Changed account/server/process/turn/Goal, queued inputs and replacement goals must prevent an automatic write.
- Partial continuation, cancellation, persistence failure and lost acknowledgement must not duplicate a Goal activation or prompt after restoration.
- Goal resume must preserve usage/objective/budget, ordinary continuation must retain the original thread/config/draft, and stale unsupported entries must disappear without deleting effect reservations.

- [x] Task 1: RED/GREEN engine reconnect-discovery gap, restored read-only restart verification, deadline failure and no-effect stale-journal cleanup. Files: CodexAccountTransition.swift, ApprovalEngine.swift, CodexAccountTransitionTests.swift.
- [x] Task 2: RED/GREEN durable per-thread continuation state and narrow live RPC Goal/ordinary continuation, with original metadata, eligibility and all barriers. Files: CodexAccountTransition.swift, CodexAccountTransitionServices.swift, new CodexAccountContinuation.swift and dedicated tests/transport fixture.
- [x] Task 3: Native continuation progress/cancellation copy and preview; owned official active Goal + ordinary work + initially idle/paused control, retained original identities and freshly repainted drafts. Run functional and visual checks separately.
- [x] Task 4: Whole Debug/Release suites, one independent whole-branch review with one TDD fix pass, signed 0.2.235/build262 release, public re-download, native update installation and original-session check.
