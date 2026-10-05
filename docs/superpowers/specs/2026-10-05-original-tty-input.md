# Original TTY input without Accessibility

## Intent

The mobile browser must type into the CLI already running on the Mac. Preserve its PID, start time and TTY; selecting a session must never launch a duplicate CLI or resume a copy of the conversation. Normal viewing remains text and terminal effects. Mac window images are explicitly opt-in. The phone requires neither installation nor an external service.

The user has rejected Accessibility-based input after repeated permission failures. Existing Terminal.app sessions are the immediate priority. Approval of one-time Mac administrator consent is a pending preference; prepare the implementation without registering a system service until that constraint is resolved.

## Evidence and alternatives

A disposable macOS 26.4 PTY probe transmitted 14 exact bytes containing Korean, emoji, Left and Return using TIOCSTI from its own controlling session. A same-user process outside that controlling session received EACCES. Apple's XNU `tty.c` documents a superuser exception. Root delivery still needs an actual disposable-fixture verification; source inspection is not an end-to-end result.

Terminal.app exposes `do script`, but no raw-byte/no-Return input API in its installed scripting dictionary. iTerm2, Orca and VS Code/Cursor already have their own input APIs. A shared PTY/multiplexer is an alternative for future CLI launches, but cannot adopt an already running Terminal.app PTY through a supported API. The user's previous objections rule out silently relaunching or copying those existing sessions.

## Proposed architecture

Add a small signed LaunchDaemon installed with explicit administrator authorization into root-owned `/Library/PrivilegedHelperTools` and `/Library/LaunchDaemons`. Current SDK headers require notarization for SMAppService LaunchDaemons; this project's self-signed publisher cannot use that route. The installer stages and verifies the exact publisher-bound helper signature before making it executable as root. The app sends bounded input requests over local XPC; the daemon uses TIOCSTI on the selected original TTY. It does not own or create a CLI, run commands, take screenshots, resize a terminal, move focus, or change terminal modes. Existing screen output and other hosts' direct APIs remain in use.

Both XPC peers must satisfy a signing requirement for an exact allowed binary identifier and the same publisher certificate. The daemon accepts the signed app (`local.autoapprove.mac`) and its packaged CLI (`local.autoapprove.helper`); both clients require the exact service identifier (`local.autoapprove.tty-input`). Derive the certificate from each peer's own valid signature; never accept an unsigned/ad-hoc application or merely a matching bundle name. The daemon binds every connection to its kernel-supplied non-root caller UID. The listener rejects unmatched incoming peers before its delegate. Clients reject unmatched incoming replies, so a status probe must succeed with the trusted service's root UID before input is enabled; a probe can reach an untrusted service without making its reply trusted. See Apple's [connection signing API](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:)) and [listener signing API](https://developer.apple.com/documentation/foundation/nsxpclistener/setconnectioncodesigningrequirement(_:)).

Each request contains a UUID, a maximum two-second continuous-clock deadline (including system sleep), immutable source PID/start seconds/start microseconds/process group/TTY device identity, the exact `/dev/ttys<digits>` path and at most 8,000 input bytes. Freeze that complete process/device lifetime when binding the original input stream, rather than capturing a new target for each key. Open only a character device with O_NOFOLLOW, O_NOCTTY and O_NONBLOCK. Require the device owner and the source's real/effective UID to equal the authenticated caller, device numbers to match, and the source group to remain the TTY foreground group. Recheck identity during delivery. Admit at most one packet across all connections and execute it on one worker; reject busy submissions immediately so XPC connection queues do not wait for device writes. Never read or consume the source's input or output.

Expired, changed, missing, foreign-user, non-foreground or invalid targets receive no input. Duplicate request IDs must not write twice. A timeout, disconnection or failure after delivery begins is an uncertain/partial outcome; do not automatically replay. TIOCSTI discards the line discipline's return value and macOS input queues are bounded. Restrict this path to a noncanonical CLI input mode, recheck mode while sending and throttle using read-only FIONREAD queue pressure below 512 pending bytes. Exercise a stopped/delayed reader beyond 1,024 bytes. A successful reply reports bytes submitted to the original TTY; do not imply application-level consumption or an output acknowledgment.

## Product behavior

Terminal's direct mobile typing uses this service and no Accessibility fallback. The Mac connection settings offer an explicit input-service setup/status control with pending administrator approval, available, disabled and error states. Browser GET/SSE requests only observe status and must not install/register services or request permissions. Setup remains a Mac-only action. Other hosts continue to use their existing native APIs.

Service registration/restart must not close original terminals. Do not change global security settings, TCC records, sudo configuration or SIP. The installed 0.2.43/52 app remains running until the replacement is ready and owned PTYs are freshly confirmed absent. Do not advertise a GitHub release as solving input until the actual original-fixture bytes have been verified.

## Acceptance

- An inert original Terminal.app fixture receives UTF-8, cursor/control keys and Return exactly, with Accessibility off and automatic approval both on and off.
- Original PID/start/TTY and every pre-existing user CLI remain unchanged; no additional managed PTY is created.
- Invalid identities, foreign UID, changed foreground jobs, deadlines, duplicate IDs, canonical mode, delayed-reader queue pressure and partial failure are exercised.
- System registration is absent during ordinary reads and before explicit setup consent.
- Default mobile/tablet/desktop terminal viewing performs no window capture and has no overflow; setup status/errors are usable in the existing visual language.
- Signing, Swift build/core checks, relevant input/stream/browser tests and the installed-app fixture are recorded separately from physical-phone testing.
