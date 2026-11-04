# Cooperative native observation proposal

Status: proposed, awaiting the user's managed-build preference. No custom Codex
has been built, installed or connected to user sessions. This proposal does not
relax the account-groups preservation contract or enable migration effects.

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
