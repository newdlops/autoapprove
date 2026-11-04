# Native Codex client ownership evidence

Date: 2026-11-04. CLI: `codex-cli 0.166.0`.
Scope: Task 7 of the account foundation plan. This is an ownership feasibility
check, not a completed migration or authentication feature.

## Reproducible native test

After building the Debug Core objects:

```sh
node scripts/codex-client-ownership-check.mjs \
  --codex=/absolute/path/to/native/codex \
  --build=.build/debug \
  --output=.runtime/codex-client-ownership
```

The test requires that exact CLI version, creates an anonymous private temporary
home, starts one ordinary Unix app-server and a loopback synthetic Responses
provider, and verifies the server peer PID on all three client connections. It
does not launch a TUI, use the user's daemon, copy credentials, inspect user
conversations or change the installed app. Cleanup stops only its own processes
and removes its own temporary home. The provider receives exactly one synthetic
turn. Its JSON report contains schema field names and booleans, not conversation
content, accounts, paths or thread IDs.

Observed on the installed native CLI:

1. A starts a thread. B sees it in `thread/loaded/list`, but B's
   `thread/unsubscribe` returns `notSubscribed`.
2. After one local synthetic turn materializes the rollout, B resumes the same
   UUID while A is still subscribed. Both connections independently receive an
   `unsubscribed` acknowledgment. An unrelated observer sees the thread remain
   loaded after A leaves and before B leaves.
3. A creates an ephemeral `thread/fork`, matching the TUI's side-conversation
   fork mode. The fork has a different UUID, `ephemeral=true`, and
   `forkedFromId` equal to the root. Its `parentThreadId` and `sessionId` do **not**
   equal the root UUID. Both root and side remain loaded together.
4. B reads the materialized root with `thread/read(includeTurns=true)` and
   receives nonempty history. B's following `thread/unsubscribe` still returns
   `notSubscribed`. Only its later `thread/resume` creates a subscription. This
   proves that a client can receive replay history without appearing in a
   subscriber census; it does not itself execute the TUI replay path below.

Therefore, neither a server-wide loaded list nor a root's parent/session tree
is a complete per-client ownership inventory. The native side-thread relation
must not disappear when producing the coordinator's selected cohort. Conversely,
`forkedFromId` alone does not prove that a regular persisted fork is still owned
by the source client; another client may have opened it independently.

A separate anonymous raw-protocol probe also reproduced `-32600` with message
`no rollout found for thread id …` when resuming a newly started empty thread.
After materializing one local turn, resume succeeded. This explains that owned
probe's failure only; it does not identify the user's earlier login/Goal failure
as having the same cause. The reusable test materializes history before resume
and does not retry unknown RPC delivery.

## Exact-version source and protocol inspection

Official tag `rust-v0.166.0` resolves to commit
`6ff1e1ca3b30fc8b914720681fcf5fe62e95f856`.

- [Server thread state](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/app-server/src/thread_state.rs)
  keeps connection-to-thread and thread-to-subscriber maps internally. These
  internal methods are not a public ownership-list API.
- [TUI routing ownership](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/tui/src/app/app_server_thread_ownership.rs)
  includes the primary thread, event channels, side threads and agent navigation.
  Reading only the currently visible UUID does not enumerate those stores.
- [TUI side handling](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/tui/src/app/side.rs)
  retains side-thread ownership in memory and sets an ephemeral fork config.
  [The native fork call](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/tui/src/app_server_session.rs)
  uses `thread/fork` for that presentation.

The installed generated request schema advertises no local PID-to-subscribed-
threads inventory. Initialize exposes home/platform/user-agent metadata, not a
client PID inventory. The generated Thread schema describes `originator` as
recorded origin, independent of the current executor/client. `sessionId` is a
session-tree identity. `thread/attachmentOwner/list` concerns resource attachment
owners; `remoteControl/client/list` concerns remote-control clients. None is
evidence for complete local TUI ownership. Native anonymous
`server/diagnostics` returned process memory and gauges, not subscriber maps.
This is a statement about the inspected interfaces, not proof that no future
official observation path can exist.

## Retained TUI state after unsubscribe

Inspection of the complete exact-version source adds a second reason why a
daemon-only subscriber API would be insufficient:

- [Navigation detach](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/tui/src/app/voice_owner.rs)
  calls `thread_unsubscribe` and aborts eligible thread listeners, while retaining
  the channel/navigation stores.
- [Listener abort](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/tui/src/app/thread_routing.rs)
  removes the listener task rather than the cached channel.
- [Replay fallback](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/tui/src/app/session_lifecycle.rs)
  can hydrate a replay-only channel from `thread/read` after live attachment fails.
  Input states are also retained separately in the agents overview.

These are source observations. The native probe verifies read-without-subscribe;
the clean three-root TUI test does not verify all these navigation branches.
The [cooperative observation proposal](2026-11-04-codex-cooperative-observation.md)
therefore requires both daemon connection relations and a capable TUI's complete
local inventory. It is pending a managed-build decision, and no custom CLI has
been built or installed. A daemon update alone cannot upgrade running old TUIs.

## Consequence for the migration producer

Do not set `completeClients` or `completeThreads` from cwd, loaded IDs,
`originator`, one visible root, or a parent/session tree. The prepare-only
coordinator's injected completeness flags are still assertions by its producer;
unit tests cannot prove the native producer correct.

Before native effect adapters or user binding, establish a complete observation
path for existing clients and all affected side/child/offscreen conversations,
including shared subscribers and unsaved ephemeral state. Track side ownership
as an explicit client relation rather than treating every historical fork as a
live child. A currently unpreservable side conversation must retain its original
client and block migration until it is resolved. Do not silently exclude it or
terminate it. Any future managed transport observer must also handle existing
clients and is not itself implemented or authorized by this evidence document.

The public and installed local product remains 0.2.251. The remote update is
waiting for the user to open the lid. A clean owned three-TUI probe now proves
existing-home Goal pause, original client/draft retention and one continuation
service call per interrupted conversation, including after coordinator restore.
Production AutoApprove is stopped for this opt-in probe; a live process guard
refuses startup or aborts on controller arrival/inspection failure. This does not
establish arbitrary existing-client membership or real authentication. Controlled
root-only A→B→A and native effect recovery evidence is recorded in the foundation
plan. Actual account isolation/SSO, complete native client inventory, cross-home
user-client binding and selected-group UI remain unproven.
