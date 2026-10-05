# Original TTY input implementation plan

> **For agentic workers:** Execute task-by-task with superpowers:executing-plans. Review the completed change with superpowers:requesting-code-review.

**Goal:** Deliver mobile input to an existing Mac CLI without Accessibility or a duplicate PTY.

**Architecture:** Bundle a narrowly scoped signed LaunchDaemon and an explicit administrator installation flow with root-owned staging and signature verification. Authenticate local XPC peers and submit bounded bytes to the original TTY after verifying source identity and caller ownership. Preserve the existing output path and Mac-only opt-in setup; SMAppService is excluded because this publisher is not notarized.

**Tech stack:** Swift/Foundation XPC, administrator authorization, Security/CryptoKit and Darwin/libproc/TIOCSTI; existing SwiftUI and browser terminal.

**Spec:** ../specs/2026-10-05-original-tty-input.md

## Global constraints

- macOS 14 minimum; no new phone software or external service.
- Keep original PID/start/TTY; no automatic new CLI, copied conversation, terminal resize or window activation.
- Window capture remains explicit opt-in. No Accessibility fallback for Terminal direct input.
- Service setup requires Mac administrator consent; ordinary reads never register or prompt.
- Requests have a UUID, at most 8,000 bytes and a maximum two-second monotonic deadline; no automatic replay.
- Never test input on a user CLI; use an inert, owned fixture only.

## Review focus

- PID/TTY reuse or foreground-job change must invalidate delivery, including changes during a packet.
- Relative paths, symlinks, non-character devices and another user's process must be rejected.
- Timeout after some bytes must produce an uncertain outcome and must never replay.
- Publisher identity must bind both XPC directions and remain stable across app updates.
- Missing/disabled/pending service must present actionable setup status without prompting from browser requests.

### Task 1: Guarded original-device delivery

**Files:** `Sources/CTTYInput/`, `Sources/TerminalInputSupport/`, `Tests/fixtures/original-tty-input-check.c`, `scripts/original-tty-input-check.mjs`, `Package.swift`.

**Interfaces:** `TTYInputIdentity` captures the libproc source identity; `TTYInputRequest`/`TTYInputReply` are bounded Codable packets; C functions read identity and deliver to an already existing TTY with explicit UID/deadline/result parameters.

- [x] Add the failing fixture for exact own-PTY bytes and rejected source/UID/device/deadline cases.
- [x] Run the fixture to confirm the missing boundary fails.
- [x] Implement only the guarded identity and byte-delivery boundary; never create or change a terminal in product code.
- [x] Run disposable user-session and root-foreign-session probes; record any unavailable administrator verification honestly. The installed root service delivered exact bytes to an inert original Terminal.app fixture; the older standalone root probe was not executed.

### Task 2: Signed service, local client and packaging

**Files:** `Sources/AutoApproveTTYService/`, `Sources/TerminalInputSupport/`, `Sources/AutoApproveCore/RemoteTerminal.swift`, `Sources/AutoApproveCore/ApprovalEngine.swift`, `scripts/package-app.mjs`, `scripts/sign-app.mjs`, service plist and focused test scripts.

**Interfaces:** `TerminalInputServiceProtocol` exposes status and a single bounded send; `TerminalInputClient` offers a synchronous bounded delivery adapter for the existing ScreenHostAdapter and observed service availability. `TerminalInputInstaller` prepares a fixed root-owned staging/install script that verifies the publisher-bound helper before launchd registration; only an explicit Mac setup action invokes administrator authorization.

- [x] Write rejection/replay/timeout and original-source adapter tests; run before implementation.
- [x] Authenticate both XPC directions with exact identifiers and own publisher certificate; serialize service writes and prevent UUID replay.
- [x] Package and sign the daemon before its containing app; derive signing requirements from the stable certificate.
- [x] Route Terminal direct keys through this client; keep iTerm2/Orca/editor APIs intact.
- [x] Run build, focused input tests and existing core checks. Do not register the service while testing reads.

### Task 3: Mac setup and actual original-session QA

**Files:** `Sources/AutoApproveApp/ConnectionSettings.swift`, `Sources/AutoApproveApp/TerminalSharingSettings.swift`, relevant browser checks, README and VALIDATION.

- [x] Reuse the existing settings layout for available/pending/disabled/error input-service states; make setup explicitly Mac-only.
- [x] Build/package before any requested system-service authorization. Record the exact action and macOS administrator requirement.
- [x] With consent, install/register the prepared service and verify exact input using only a new inert original Terminal.app fixture, Accessibility off and automatic approval on/off.
- [x] Confirm all previous CLI identities/settings/events survived; confirm managed PTYs remain zero and captures remain opt-in.
- [x] Exercise and inspect actual mobile/tablet/desktop web states; distinguish browser verification from physical-phone testing.
- [x] Obtain independent review, fix important findings and rerun only affected checks before release claims.

Build 53 and its signed root service are installed. All 16 original CLI identities, 5,446 approval records and protected settings survived. Actual App-to-root-XPC input to the inert original Terminal.app fixture passed with 36 exact bytes, automatic approval ON/OFF, no product PTY or Mac window image, and cleanup of the fixture only. Failure rollback and physical-phone Safari/IME remain unverified.

Follow-up findings: the 16 local default-text sources currently provide no cursor coordinates. The user also reported a SentinelOne suspicious `bash` alert at exactly the helper installation time. Signature and file integrity checks passed, but no console Command Line or Indicators are available; the precise detection and false-positive verdict remain unconfirmed. Do not rerun the installation to provoke a detection or change endpoint-security policy. Official SMAppService daemon registration requires notarization; no usable Developer ID signing identity was found in the default user keychains. Cursor behavior and legitimate deployment review remain open before publication.
