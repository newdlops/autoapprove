# Real PTY Terminal Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline; implement and verify each task before the next.

**Goal:** Give the phone browser a real terminal attached to a Mac-owned PTY, without installing anything on the phone.

**Architecture:** A small C boundary creates a controlling PTY and execs a login shell. A bounded Swift manager owns processes, raw output offsets, input ordering, resize and libvterm screen state. Existing LAN HTTP forwarding carries those bytes to a locally bundled xterm.js interface. Detected Codex/Claude processes on these exact PTYs use the existing approval engine.

**Tech Stack:** Swift, Darwin forkpty, libvterm 0.3.3, xterm.js 6.0, plain JavaScript and the existing Network.framework server.

**Spec:** [DESIGN.md](../../../DESIGN.md), actual PTY terminal 0.2.41.

## Global Constraints

- Preserve existing sessions and unrelated working changes.
- No phone installation, CDN, external relay or changes to VPN settings.
- PTY input must work without Accessibility permission, including while automatic approval is on.
- Reuse the existing UI and 44px touch controls; minimum width 320px.
- Never replay an uncertain input, silently restart a user CLI or claim an existing Terminal PTY was adopted.

## Review Focus

- A browser disconnect must preserve its process and recover the current screen without replaying historical terminal query replies.
- Mixed UTF-8 byte boundaries and terminal control sequences must remain exact.
- Two browser writers must not interleave input; duplicate request IDs and out-of-order packets must not write twice.
- Resizing or typing must invalidate an approval prepared from the previous screen.
- Exit and cleanup must target only the PTYs created by this app.

## Tasks

- [x] Add an isolated HTTP test that requests a PTY; verify the current server fails with 404.
- [x] Implement `ManagedPTY` (spawn, bytes, screen, resize, exit) and `ManagedPTYManager` (bounded inventory, stream ID, sequential inputs, writer lease, cleanup). Verify echo, ANSI, cursor, signals and isolation with a real test PTY.
- [x] Add `/api/pty`, `/api/pty/output`, `/api/pty/input`, `/api/pty/resize`, `/api/pty/close` with existing origin checks, peer forwarding and durable receipts. Identify exactly owned TTYs in discovery; add the PTY screen adapter for automatic approvals.
- [x] Bundle xterm.js and fit addon with licenses. Add the terminal creation dialog, direct screen input, special keys, resize, reconnection and ended states. Keep the existing mirror path available for old clients.
- [x] Run real PTY browser interactions and screenshots at 390×844, 768×1024 and 1440×900; inspect overflow, focus, loading/error/ended states and original colors separately.
- [x] Run core and relevant browser regressions, review the final implementation, package and install the new version with preserved app data, and publish the authorized GitHub release. Published `v0.2.41` (build 48) from `43955b2`; installation, latest-release metadata and artifact digest verified. See [VALIDATION.md](../../../VALIDATION.md).

## Real-time streaming and automatic attach

The user tested the local build and asked to remove latency and the separate PTY-opening step before publication.

- [x] Push output from PTY read events over a persistent SSE connection, with bounded writes, peer streaming, writer-lease changes, final-output drain and cancellation on web OFF. Keep the JSON endpoint compatible.
- [x] An explicit selection of a supported live Codex/Claude session immediately attaches to its continuation. Repeated selections, simultaneous browsers and reload reuse the same exact PTY rather than starting another CLI. Initial dashboard loading does not start a model.
- [x] Verify one-click attach, same process after reload, real stream latency/request counts, old-client fallback and dead foreground-group-leader cleanup; rerun affected regressions and inspect the final UI captures.
- [x] A closed PTY must leave active session lists/counts immediately, retain its final screen in an already open browser, and stay ended when the original selection is revisited. Verify explicit close, natural exit, delayed discovery/screen results and visible ended-screen reload before final packaging.
