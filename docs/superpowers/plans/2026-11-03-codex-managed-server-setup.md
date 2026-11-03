# Managed Codex server first setup and actual discovery

Base f18925f; isolated fix/codex-server-discovery-239. Preserve unrelated notification drafts. No Goal or delegated agents.

- [x] Reproduce actual argv[0] = codex omission with owned PTY/process/Unix sockets. Resolve the current executable from the kernel and retain original start/TTY/UID and exact socket checks.
- [x] Distinguish CLI missing/unsupported, daemon absent, running daemon and unverifiable sockets. For a user-owned dangling link with an absent target, archive/verify its inode and restore exclusively on failure; never overwrite a newly published socket. Prepare with official start; no restart/update/remote-control/bootstrap or credential mutation. Serialize with login/transition and cancel on manager stop. Provide read-only CLI diagnostics.
- [x] Extend the existing native account window with selected-home server status, explicit preparation, loading/error recovery and accurate zero-connected-client guidance. Keep unverified sessions disabled and preserve normal login/transition behavior.
- [x] Verify isolated fake capability/failure cases and an actual official first-start under temporary HOME/CODEX_HOME, actual process discovery, relevant regressions and native functional/visual QA. Build/sign/commit/publish/download/install the matching release, verify original processes and record exact secondary-machine limitations.
