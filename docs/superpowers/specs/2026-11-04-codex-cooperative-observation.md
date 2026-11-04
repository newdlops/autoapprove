# Cooperative native observation proposal

## Official-only route revalidation · 2026-11-04

The official repository's latest release still resolves to
[`rust-v0.166.0`](https://github.com/openai/codex/releases/tag/rust-v0.166.0)
(published 2026-10-29T19:47:53Z), matching the inspected native source. No newer
stable release was available to substitute for the missing client producer.

The current [official API overview](https://learn.chatgpt.com/docs/app-server#api-overview)
describes persisted thread reads and the in-memory loaded-thread list separately.
It does not establish that either list inventories a TUI's retained local state.
The source-backed counterexamples below therefore still govern migration.

Two additional exact-version API candidates were inspected rather than assumed
to solve that gap:

- `remoteControl/client/list` takes an environment ID and returns registered
  device/client display metadata. Its response has no native process identity,
  thread membership, retained draft/replay state or admission barrier. It is not
  a local TUI ownership census. See
  [`protocol/v2/remote_control.rs`](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/app-server-protocol/src/protocol/v2/remote_control.rs).
- The daemon recovery handoff snapshots persistent root IDs and resumes runtimes
  with cold-resume semantics. It does not export all selected TUI-local state or
  transfer a chosen client between credential homes. See
  [`daemon_thread_recovery.rs`](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/app-server/src/daemon_thread_recovery.rs).

The no-fork wording in the account-group design was an implementation proposal,
not an explicit user prohibition on isolated source preparation. Treating it as
requiring permission before any prototype work was overly restrictive. The open
managed-build preference can steer distribution, but source-only preparation and
owned tests can proceed under the requested integration goal. Do not install an
extension, replace existing clients, or represent an official-only list as
complete membership without the required preservation and review evidence. This
is not an automatic-approval rejection. Full selected-session migration remains
incomplete; its requirements are unchanged.

Status: isolated source prototype in progress; distribution preference remains
open. The [source patch and preparation tools](../../../patches/codex/README.md)
connect a private read-only diagnostic socket to actual TUI App stores. Native
library tests passed 4/4 and the standalone TUI binary built with the pinned
dependency graph. An owned embedded TUI/PTY probe verified repeated event-loop
reads and exact unsent-draft preservation on a fresh repaint while preserving all
19 original controller session identities. No custom Codex is installed or
connected to user sessions. Daemon peer coverage and migration remain unverified;
this does not relax preservation gates or enable migration effects.

An additional owned shared-Unix-server probe now verifies an actual offscreen
navigation branch: a loopback-materialized root received a real unsubscribe ACK,
then remained represented in the TUI's retained overview input after its local
channel/navigation entries were removed. Overview selection restored its exact
unsent draft. The server still listed that root as loaded. A separate direct
`/resume` return did not restore the draft, so same-ID resume alone remains
insufficient preservation evidence. These are one-client observations; complete
peer census, independent voice/replay state and migration barriers remain open.

## Why both sides are required

The inspected official version is 0.166.0, commit
`6ff1e1ca3b30fc8b914720681fcf5fe62e95f856`. The source archive SHA-256 used for
this inspection is
`f4693ca48d5b3ffaf7b13c3c490481c0d7a68ad29f945753fea9cc08a570db72`.
The source-only import excluded the archive's bubblewrap LICENSE symlink;
it is not a complete distributable source package.

The official [app-server documentation](https://developers.openai.com/codex/app-server)
describes `thread/read` as a read without subscription and `thread/loaded/list`
as the server's in-memory list. The native owned probe now independently verifies
that reading materialized history is followed by `notSubscribed` on the same
connection. No inference or subscription is implied by that read.

The exact-version TUI also retains state outside current subscriptions:

| Source in `codex-rs/tui/src/` | Observed behavior |
| --- | --- |
| `app/voice_owner.rs`, `detach_current_thread_for_navigation` | Unsubscribes eligible threads and aborts their listeners without deleting their channel or navigation entries. |
| `app/thread_routing.rs`, `abort_thread_event_listener` | Removes the listener task, not the cached thread channel. |
| `app/session_lifecycle.rs`, replay fallback | Can populate a replay-only channel from `thread/read` after live attach fails. |
| `app/agents_overview.rs` | Retains input states separately from the currently displayed widget. |
| `app/app_server_thread_ownership.rs` | Routing ownership is a union of primary, channel, side and navigation membership. |

Therefore, a server-only subscriber census would still miss relevant local
state. This is a source-backed conclusion, not a claim that the new native probe
executed those TUI navigation branches. The existing clean three-root TUI test
also does not exercise all these branches.

## Proposed observation boundary

Use two cooperating producers. Neither returns a bare `complete=true` assertion.

1. The daemon records its own startup identity and topology revision, every
   connection's generation and native peer identity, initialization state, and
   explicit per-thread subscriber relations. A connection without sufficient
   native identity or an unsupported client remains an unknown member.
2. Each capable TUI answers an inventory request on its event-loop boundary.
   It enumerates primary and active IDs, channels, navigation, side conversations,
   retained input stores, voice owners/replay, temporary requests, pending titles,
   and pending thread/worktree transitions. It distinguishes live subscriptions,
   replay-only state and unsaved state. Unknown or unsupported stores invalidate
   migration eligibility rather than disappearing from the affected set.
3. A diagnostic coordinator binds both answers to one request nonce, the exact
   daemon/process/connection generations and the selected client's kernel
   PID/start/TTY. Re-read topology after client responses. New, removed or changed
   connections, incomplete responses, stale generations or unsupported clients
   produce an incomplete result. The observer itself must be distinguished from
   actual user clients without treating an arbitrary client-supplied name as proof.

Negotiation must explicitly advertise the extension and its schema version.
The `autoapprove/*` namespace below is proposed, not an existing official API:

- `autoapprove/ownership/read`: a bounded local diagnostic request returning
  daemon identity, topology revision, connection relations and per-client
  observation status.
- `autoapprove/clientInventory/read`: a server-initiated request only to a
  client that advertised the matching capability. Its reply includes the nonce,
  connection generation, local state revision, affected IDs, relation kinds and
  blocking reasons.

Return identifiers, relation kinds and state flags for discovery. Do not export
draft text, history, attachment contents, tokens or credentials in this census.
Any later preservation export needs a separate private transfer contract.
Keep transport local to the existing user-owned private socket; do not expose
these methods directly on the LAN diagnostic endpoint.

## Observation is not a migration lock

Two matching reads only prove an observation interval. They do not prevent the
user from editing a draft or a client from starting a new thread afterward.
Do not bind a successful census directly to termination, archive or import.
Effect-producing preparation additionally needs a native reversible admission
barrier covering the selected clients, affected threads and new children, plus
fresh account/backend evidence. This proposal does not implement that barrier.

Shared ownership must remain explicit. A thread with an unselected subscriber,
replay owner or unsaved-state owner cannot be moved by silently excluding that
client. Ephemeral side state with no verified export path retains its original
client and blocks migration.

## Existing clients and distribution

Updating a daemon does not inject a new capability into an already running
unmodified TUI. Such a client must remain visibly unsupported for the complete
census. Do not claim it was upgraded from a matching version string or server
connection. A bootstrap path must preserve all relevant state before replacing
the TUI; otherwise keep it running and require a separately agreed transition.

An opt-in managed build must be installed alongside the official CLI, identify
its source and patch digest, preserve a rollback path and be verified on Apple
Silicon Macs. Never overwrite npm/Homebrew packages, replace the user's default
CLI, alter current auth storage or restart user sessions merely to try this
proposal. Real account/SSO isolation, full state preservation, group selection,
round-trip migration and release verification remain required.

## Acceptance evidence before binding

- Actual TUI observations covering offscreen replay, navigation after unsubscribe,
  ephemeral side conversations, independent voice state, saved drafts, pending
  input/questions and a changed membership during collection.
- Two real clients sharing one thread, including a client with only retained
  replay state; all owners remain represented.
- Unsupported existing clients, PID reuse, daemon restart, connection replacement,
  reconnect during collection, omitted stores and version mismatch yield no effects.
- Observation requests leave native subscriptions, Goals, turns, queues, drafts,
  credentials and the installed app unchanged.
- Separate tests prove preparation barriers and subsequent preservation effects;
  census tests alone cannot authorize those effects.
