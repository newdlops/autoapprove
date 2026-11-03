# Standalone Goal recovery implementation plan

> Execute inline using superpowers:executing-plans; preserve unrelated main-workspace changes.

**Goal:** Explicit reconnect recovers proven pre-input legacy failures and migrates independent Goal conversations sequentially into the same managed server, retaining separate conversations.

**Architecture:** Preserve the existing per-session identity and pause/exit/launch journal. Recognize only the exact legacy pre-service availability rejection as known no-write. Prefer the already-authorized, exact-window accessibility keyboard path for Goal interruption; use direct input only when keyboard permission is unavailable. Never fall through after any attempted send or erase unknown/partial delivery records. No force killing, Goal DB writes, or conversation merging.

- [x] Reproduce persisted legacy helper-unavailable review through the real engine and serializer; prove repeated reconnect currently never sends Esc. Add transport preference red test.
- [x] Implement narrow legacy no-write recovery and keyboard-first selection; preserve unknown and observed-pause barriers.
- [x] Verify two distinct active Goals in owned PTYs pause, exit and resume under one daemon/home without mixing IDs or duplicating continuation.
- [x] Run appropriate Debug/Release build, Goal/attachment/account checks and owned engine regressions. Request focused source review.
- [ ] Release 0.2.248/build275 with signed DMG/ZIP/checksums, verify public downloads, install locally and preserve real process identities. Record proof limits: actual other-Mac keyboard posting and private journal remain unverified unless directly observed.

Ruling: Add phase-transition audit events after journal persistence so the connected-Mac history can reveal the next actual blocking stage without reading the private journal or serializing a Goal. Logging is best effort and never authorizes a side effect. Missing-stage regression failed before implementation. Source reviewer found no Critical/Important findings in recovery, transport selection or audit addition; no native UI tests were performed by review.
