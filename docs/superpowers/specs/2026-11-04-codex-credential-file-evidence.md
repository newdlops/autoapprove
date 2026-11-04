# Credential file independence evidence

Scope: internal storage evidence for account groups, not a completed login or
session migration feature. Installed/public AutoApprove remains 0.2.251.

## Native storage and the observer

Official 0.166.0 source, commit
`6ff1e1ca3b30fc8b914720681fcf5fe62e95f856`, implements the file backend at
`CODEX_HOME/auth.json`. Its
[file loader and saver](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/login/src/auth/storage.rs)
open that path normally; the saver truncates an existing file. Different path
strings therefore cannot prove that two file backends are independent.

`CodexCredentialFile` captures only resource metadata. It preserves the selected
home path and its physical directory identity, then checks the fixed `auth.json`
leaf through the opened directory. It records a present file's device/inode,
size and nanosecond modification/change timestamps, or witnessed absence.
`verifyCurrent` rejects changed files, aliases, homes, permissions and presence.
`requireIndependent` rechecks both observations and rejects the same physical
home/file. Hard links, symlink credential leaves, nonregular files, files not
owned by the user and group/world-accessible credential files reject.

The observer never reads credential bytes, copies tokens, logs in, changes
permissions or modifies either home. It uses `O_EVTONLY`, verifies the leaf type
before opening, and includes `O_NONBLOCK` to avoid a special-file replacement
blocking inspection. Tests exposed a FIFO wait without the last two protections;
the bounded final implementation rejects the FIFO before opening it.

## Reproducible checks

```sh
swift build -j 2
.build/debug/autoapprove-checks --filter 'Credential file:'
AUTOAPPROVE_CODEX_BIN=/absolute/path/to/native/codex \
  node scripts/codex-auth-file-isolation-check.mjs
```

Add `--check-session-switch` to verify the account-session identity boundary.
Each owned server lists one current managed login. Re-selecting its current
workspace preserves its credential witness, loaded thread and exact paused Goal;
trying the other server's login session ID is explicitly rejected with -32600
and leaves those values unchanged. This tests a no-op and a rejected selection,
not a successful different-workspace exchange or a real account change.

Five real-filesystem cases cover present/absent independent slots, aliased and
replaced homes, retargeted selected aliases, linked/public/special entries,
changed/deleted/replaced credentials and metadata serialization without secrets.

The native probe pins 0.166.0, creates two private temporary homes and launches
ordinary stdio servers with an explicit file-storage override and a minimal
environment. Only synthetic unusable tokens are written to those owned homes.
Each server reports its own synthetic account. Logging out A removes A's file
and invalidates only A's witness. B's file bytes, inode, witness and runtime
account remain unchanged. A's restart with new synthetic metadata also leaves
B unchanged. The report contains booleans, not account IDs, paths or tokens.
All servers and homes are cleaned up by the probe. Background HTTP requests are
served/rejected by a loopback fixture; this is not real service authentication.

## What is still unproven

File identity is not an attestation of a running AuthManager's selected backend.
Do not derive a migration endpoint's credential isolation from this resource
witness alone. Effective configuration read later is also insufficient evidence
of what an arbitrary existing process selected at startup. The controlled native
probe pins that startup and observes the native logout effect; it does not supply
a general runtime backend observer for existing user servers.

Keyring, automatic fallback, ephemeral or externally supplied credentials still
need their own runtime-backed evidence. Matching synthetic account metadata is
not proof of real ChatGPT authentication, workspace/SSO or model/plugin access.
A matching observation is not a write barrier: revalidate under the eventual
native preparation contract before effects. Full client ownership, real account
separation, group UI/mappings and cross-Mac release gates remain open.
