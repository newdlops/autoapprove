# Shell-less Codex attachment

The user supplied process metadata proving two standalone Codex processes are direct children of `login` on the same TTY, with no shell ancestor. The user selected same-window replacement tabs on 2026-11-03. Preserve the window and exact conversation; a one-time tab replacement is accepted.

## Approaches

- Reuse the original shell: retain this for sessions with a proven shell, but it cannot handle the supplied login → Codex structure.
- Prepare a replacement tab in the same native window before exit: selected by the user. Reuse the existing verified Terminal tab opener, prove an empty foreground shell, persist its identity, then gracefully exit the idle original and resume the exact UUID/home/cwd against the managed server.
- Reopen an arbitrary new window: rejected because it breaks the requested grouping.

## Contract

No `login` process is treated as a shell. Never terminate the old CLI unless an empty replacement shell is durably identified and both tabs are proved in the same native window. Persist a tab-opening reservation before the effect; an ambiguous opening is never automatically repeated. Exit and resume reservations remain single use. Verify the replacement process, exact shell/TTY, actual server connection and loaded original thread before completion. Keep questions, drafts, active Goals and independent child work waiting. Preserve the normal same-shell path and old journals. Support Terminal first; unsupported hosts stay intact with a specific reason. Future Codex profile commands retain their interactive shell instead of `exec` replacing it. Do not change Claude restoration semantics.

Product changes reuse existing progress/error labels. No new dependency or approval flag. Actual user Terminal manipulation is not a QA shortcut: use app-owned PTYs and injected topology services, plus existing opener tests; report unavailable real native integration verification.

An explicit reconnect may gracefully stop only the exact recognized resident tool-host cohort captured by that request (PID/start, parent, executable, TTY and group), scoped to the original session and home. Automatic discovery does not grant this permission. New children and other work still block. Revoke unused grants on cancellation, return, review and restoration. After exit, retain separate read-only witnesses and wait for actual process disappearance before launch and connection verification.

Replacement preparation requires an empty shell. A Terminal profile that directly starts a program is rejected without exiting the original. This native integration and the other Mac remain unverified; owned PTYs and injected native-window proofs cover engine behavior.
