# Official Codex preservation alternatives

Date: 2026-11-16. Runtime tested: original OpenAI-signed Codex 0.169.0.
Status: official-runtime support boundaries for AutoApprove 0.2.312 build 339.
The user cleared the earlier goal and explicitly accepted that unimplementable
features must be identified as unsupported while the app transitions to official
Codex. The previous all-features blocked audits below are historical evidence,
not a prohibition on the newly authorized support boundaries.

## Current rollout support boundaries

The app must launch unmodified, original OpenAI-signed Codex and retain supported
approval, questions, groups, message delivery, account/login, Goal and profile
restoration paths. Signing and packaging must preserve the original Codex bytes.
Release acceptance includes its matching build, source commit/tag, signed DMG
and update ZIP with checksums, GitHub publication/download verification,
installation and running-version check. This investigation record is not a
release-completion claim; the matching release notes describe verified checks.

The following limitations are now explicit product support decisions:

- Moving every retained conversation of an already-open terminal to another
  account home, including merge/split of that existing session, is unsupported.
  The original runtime does not expose complete retained-root/input ownership
  and admission. Preparation/execution must refuse before server or terminal
  effects; creating login groups and launching sessions in them remain separate.
- Complete per-terminal app-server connection IDs/backend inventories are
  unsupported. Actual server/account observation remains supported through the
  existing local association and official account API.
- Automatically closing/reopening an already-open standalone TUI to enroll it
  in a shared server is unsupported too, including within the same home. Its
  hidden cached inputs are not attested by the visible empty composer. New
  server-backed profiles and reconnecting an already-connected managed cohort
  remain separate supported paths; the standalone session stays untouched.
- Existing modified clients and servers are not automatically replaced. A new
  profile with no saved conversation ID may fall back to the original bundled
  CLI with daemon auto-start explicitly disabled, preserving its selected login
  home. Saved-conversation resumes still require an attested compatible server;
  they never silently use this new-conversation fallback.
- Restoring an arbitrary previously watched child after an inactive-child
  approval is not implemented. The current canonical V2 navigator returns Main;
  its parent draft and approval checks have owned-runtime evidence. Arbitrary
  V1/nickname layouts and ambiguous/clipped labels remain unverified/manual.
- Crash recovery does not automatically replay an uncertain Goal action. Four
  actual controller-death boundaries are verified; fresh observation and a new
  explicit request are required where the original Goal is still active/deferred.

Other conversion/installation limits must be recorded as they are verified.
The user requested the final unimplemented-feature list after the rollout;
these boundaries will be rechecked against the shipped app at completion.

Existing modified managed packages also require a boundary: the official daemon
CLI can execute its selected managed binary while answering a version query.
The official context now verifies the selected current package before daemon
commands. New terminal invocations also attest any selected package and existing
socket peer, except an explicitly standalone invocation that disables daemon
auto-start. A nonofficial selection is refused with an explicit unsupported
automatic-replacement message; it is never used as a fallback. Legacy package
files and active user processes are retained. Fresh official daemon preparation,
original package integrity, actual peer verification, official reconnect choice
and rejection of a fake selected managed executable pass an owned real-runtime
check. That fixture confirms the fake executable never runs and its home config
does not change.
Official child Goal pause/resume and the owned latest-history journal round trip
pass. New-profile standalone fallback also passes an original-runtime PTY check
with a deliberately nonofficial selected cache: the cache never executes and
the selected login home remains intact. No user terminals are used in this test.

## Historical investigation scope

Before the new rollout goal above, the user asked to keep investigating full
preservation of child Goal control and selected cross-home migration. The
investigation records below retain that earlier acceptance context. Unsupported
product decisions for this release are governed by the current boundaries above.

## Official writer exclusion

`CodexOfficialWriterLease` follows the original runtime's
`thread-writer-locks/.coordination.lock` and `<thread UUID>.lock` protocol. It
holds shared directory coordination and exclusive locks for only its selected
threads. It never deletes lock files. It checks original home, directory and
file identities, rejects symlinks and closes an incomplete acquisition fully.
This component is not yet used to authorize migration effects.

Reproduce after building `autoapprove-checks`:

```sh
node scripts/codex-official-writer-lease-check.mjs --codex=/absolute/path/to/original/bin/codex
```

The real official server and independent helper verify that an existing writer
excludes the helper, a held thread cannot resume, unrelated threads remain
usable, a partial acquisition rolls back, release permits resume, fresh official
process cleanup respects the held locks, symlinks are rejected and replaced
inodes invalidate the lease. All homes, processes and data are owned fixtures;
there are no model turns or user terminal actions.

The same test deliberately confirms that `thread/goal/set` can change a paused
Goal while its rollout writer lock is held. Consequently, these locks do not
prove RPC admission exclusion, Goal exclusion, TUI membership, retained drafts,
writer retirement or migration ownership. Do not replace the existing complete
cohort or input barriers with a `complete=true` assertion based on this test.

The exact original implementation is
[`rollout/src/writer_lock.rs`](https://github.com/openai/codex/blob/rust-v0.169.0/codex-rs/rollout/src/writer_lock.rs).

## Child Goal lifecycle through original public attachment

The original V2 app-server still rejects direct child Goal mutation. However,
public `thread/resume` can attach to a parent-owned child and invoke the native
idle lifecycle. After restoring the exact paused Goal row to active, this hook
starts normal automatic Goal work without a parent message or child turn input.

The production `ApprovalEngine.changeCodexSubagentGoal` now selects this official
resume implementation and the matching pause implementation. Reproduce the
combined owned test after building `autoapprove-checks`:

```sh
AUTOAPPROVE_WEBSOCKET_MODULE=/absolute/path/to/ws \
node scripts/codex-child-goal-transition-check.mjs \
  --codex=/absolute/path/to/original/bin/codex \
  --parent-goal-control --local-goal-resume-probe \
  --resume-via-attach-probe --engine-resume --engine-pause
```

Pause first defers native automatic Goal continuation without changing the
active Goal row. It interrupts only the observed turn and waits for native
accounting to settle. A whole-row compare-and-set then changes that same Goal to
paused and removes the deferral. Public attachment while paused clears cached
active accounting. Resume clears that cache while still paused, durably reserves
its state change, restores the same Goal to active and invokes public attachment
again. Version, schema, original executable, connected server process, selected
home, socket lifetime and complete Goal state are checked around local writes.

The combined original 0.169.0 test passed with a busy parent. It verifies both
actual engine actions, unchanged parent turn count, accounting of the interrupted
active interval, no automatic work or new usage during the paused interval,
automatic continuation after resume, and cold-server Goal/history retention.
Repeating each request ID, including after engine recreation, returns its stored
result without dispatching another lifecycle action. The Terminal association is
a synthetic adapter around owned real server sessions; physical Terminal.app
delivery and a real user's account are not exercised.

Separate real-runtime state tests cover SQL rollback on cancellation and socket
replacement, stale/schema rejection, competing compare-and-set operations and
process death before/after SQL application. They do not establish every lifecycle
race. In particular, an already-admitted continuation or explicit input can race
pause; a changed observed turn is rejected without interrupting its replacement.
Pause-stage crash recovery and complete concurrent lifecycle coverage remain
release requirements. No parent model cooperation is needed by the new route.

The original runtime's
[`ext/goal/src/api.rs`](https://github.com/openai/codex/blob/rust-v0.169.0/codex-rs/ext/goal/src/api.rs)
serializes normal mutations under a runtime permit and applies explicit runtime
effects. Its
[`ext/goal/src/extension.rs`](https://github.com/openai/codex/blob/rust-v0.169.0/codex-rs/ext/goal/src/extension.rs)
reads persisted Goal state at turn start. Preserve those semantics when assessing
this alternative; a successful local SQL update alone is insufficient.

## Approval reflow

The production approval navigator now joins fully visible wrapped V2 labels,
child footer labels and picker rows. Ellipsized or ambiguous identities remain
ineligible. Synthetic parser/navigation checks pass, as does a real original
80-column TUI with two children: child approval executes, the primary conversation
is restored and its exact unsent draft survives. Physical Terminal.app keyboard
delivery and arbitrary prior-child views are not covered by that test.

## Durable source retirement without a patched server

An additional original 0.169.0 feasibility test passed:

```sh
node scripts/codex-official-retirement-check.mjs --codex=/absolute/path/to/original/bin/codex
```

After public `thread/archive` unloads one known fixture conversation, retaining
its exact archive inode outside `sessions` and `archived_sessions` blocks public
resume by ID, resume by old path and unarchive in both the existing original
server and a new original process. The original shared server stays alive, and
the unrelated loaded thread and Goal stay unchanged. Returning the original file
and using public unarchive/resume restores the same UUID, nonempty history and
Goal. Exactly one synthetic model turn is used to materialize history.

Public Goal lookup also resolves the rollout, so it is unavailable while that
file is withheld. The exact stored Goal row remains unchanged. A future product
implementation must obtain migrated Goal observations from their recorded
destination rather than claiming the old source API remains readable.

This is evidence for a durable retirement alternative. The script knows its
entire owned scope; its file rename is not production migration authority. A
complete TUI inventory, input admission and binding to the selected migration
coordinator remain required before user data changes. The storage implementation
and its crash recovery are described below.

### Storage implementation and crash recovery

`CodexOfficialRetirement` now implements the storage primitive against an
existing `CodexMigrationJournal` reservation. It verifies the selected official
writer-lock scope, exact Goal slot, original rollout inode/hash/timestamps and
anchored private directory identities. The caller must supply its live authority
checkpoint. Intent and attempt records are durable before the exclusive rename;
neither the original nor a conflicting destination is overwritten. `observe`
only checks facts, and `load` can reconstruct the immutable intent from the
journal and selected source if the caller died before saving prepare's result.

The strengthened real original-runtime check passes:

```sh
node scripts/codex-official-retirement-check.mjs \
  --codex=/absolute/path/to/original/bin/codex \
  --swift-retirement --crash-retirement
```

It verifies competing/repeated requests apply each rename once, rejected
checkpoint/scope/terminal reservations, an original-path collision, a symlink,
replacement of retained data with identical bytes in a different inode and a
hardlink. Five independent owned conversations exercise process exit after
prepare, before/after withdrawal rename and before/after abort-return rename.
Fresh processes recover the correct physical state. Attempts whose rename did
not occur remain for review; an observed completed rename is never repeated.
The original shared server and unrelated Goal survive all cases. Nonzero Goal
usage (37 tokens, 19 seconds), exact identity and history survive the normal
retirement/return case.

`returnOriginal` is abort compensation, requiring proof that destination
activation has not occurred. It is not account migration back to the source:
that operation must transfer the destination's newer history and accounting.
The storage primitive is now integrated with the migration journal as described
below. Complete selected-client runtime observation and admission are still not
wired to it. No user-session migration, release or installation is claimed by
the storage test.

### Latest-history round trip through the journal

The journal now accepts a versioned official retirement reference. It records
the immutable intent digest, retained original inode and original native archive
location. Existing version-1 archive evidence remains supported. Independent
retired backups and the existing Goal/history return transactions can consume
this official evidence without silently treating a missing native archive as a
deleted conversation.

`CodexOfficialArchivePublication` reserves a separate step that publishes the
latest verified replacement into the absent native archive slot. This is not
abort return of the old original. The same source/destination writer scopes,
Goal result and journal reservation are rechecked. A previous attempted rename
is observed and never repeated. Official 0.169.0 native restoration is admitted
only after this publication has been verified; legacy version guards remain.

The real original-runtime A→B→A check now passes:

```sh
AUTOAPPROVE_CODEX_BIN=/absolute/path/to/original/bin/codex \
node scripts/codex-cross-home-preservation-check.mjs \
  --probe-0.169 --restore-goal --archive-source --check-settings \
  --check-retirement --return-original-home --official-retirement
```

B creates newer history before returning to A. The same UUID, full latest
history, Goal instance, exact millisecond timestamps, budget and increased usage
(37→73 tokens, 19→29 seconds) survive. Nondefault reasoning, service tier,
instructions, disabled-plugin IDs and workspace roots survive and reach a real
loopback inference request. Both shared fixture servers remain alive during the
movement; their unrelated Goal/thread state is retained.

Adding `--crash-native-acks --publication-ack-loss` exits the owned controller
after the durable archive-publication rename and then loses the unarchive and
resume acknowledgments separately. Fresh controllers reconcile each boundary;
the publication rename, public unarchive and public resume each occur once.
An independent check with `--crash-native-acks --return-cleared-goal
--check-cleared-slot` confirms a deleted Goal is not resurrected during return
or later resume. The legacy rollout-return crash check still passes all five
owned process boundaries.

These tests construct their complete one-root scope explicitly. They validate
the storage/journal/native-restoration path, not arbitrary existing TUI
membership, cross-account real authentication, selected-client bridge adoption
or complete product migration. `productMigrationEnabled` remains false.

## Existing direct clients: verified adoption limit

Latest public release was rechecked on 2026-11-16 with the GitHub release API:
`rust-v0.169.0`, published 2026-11-13 08:37:05 UTC. This audit concerns that exact
original release and does not claim to describe a future official version.

The direct-client probe passes its negative assertions:

```sh
node scripts/codex-official-retained-reconnect-check.mjs \
  --codex=/absolute/path/to/original/bin/codex --direct-adoption-probe
```

An original TUI connects directly to the original source server. It retains two
distinct Unicode drafts in separate conversations. The fixture renames only its
owned listening socket and starts a relay at the old socket pathname. A new
probe connection reaches the destination server, proving the replacement works.
The existing TUI does not connect to that relay: its native PID/lifetime and old
connection remain. Changing the pathname does not retarget that connected socket.

The fixture then clears only the visible Beta draft so it can enter `/quit`.
The Alpha draft remains untouched in its separate retained conversation. After
clean exit, a fresh original TUI uses the same source home, original server and
saved conversation. History is restored, but the hidden Alpha draft is absent.
Neither draft was submitted; the only model requests are the two fixture seeds.
The source shared server and its unrelated Goal stay intact. This counterexample
rules out treating an ordinary clean restart as complete retained-state migration.

The positive control still passes in the current script: a TUI that starts
behind the owned relay retains both drafts when that relay changes homes. That
control does not adopt an already-direct client and cannot be substituted for
the user's requirement about arbitrary already-open state.

Further exact-version source checks:

- The local Unix WebSocket loops have no autonomous heartbeat/idle-disconnect
  timer. They answer incoming pings; a stopped client is not safely adopted by
  waiting for a documented local heartbeat expiry. The remote-control heartbeat
  is a different transport and is not a local-client solution.
- Initialize declares client name/title/version and capabilities, with no
  existing-connection replacement identifier.
- SIGCONT job control restores terminal modes and viewport. It does not replace
  the app-server target. The inspected TUI signal hooks expose no target-change
  or complete retained-state export operation.
- The startup recovery draft is explicitly task-local memory, not a global
  recovery file; it is not an export of all retained conversations.
- The available Codex TUI connector tools provide task/worktree/history actions,
  with no complete retained-state export/import or per-client target replacement.

The historical blocked audit treated process-preserving adoption with arbitrary
local state as necessary. The released-contract audit below supersedes that
inference; the negative experiment does not by itself prove the actual requested
migration feature impossible. Full release/install remains unfulfilled.

## Released-contract audit after goal resume

The base release source at `0f2fe867f6c9ad51d1b5785ec1ecfda2b8cbb62a`
defines `CodexMigrationClient.blocked` as draft, question, queued input or
independent work. `CodexSessionMigrationCoordinator.request` rejects any selected
blocked client before it creates a journal reservation. Its reconnect path
requires an empty composer, exits the original CLI and resumes in the same
terminal. It does not promise to move hidden drafts or preserve the native PID.

Consequently, the earlier block based on failure to restore a hidden draft after
restart imposed a stronger condition than the released feature. The actual
preservation contract is retained: leave unsafe originals untouched, establish
complete selected and unselected client membership and input eligibility,
preserve the same conversation/Goal/settings for eligible moves, and confirm
reconnection in the original terminal. Unknown scope must not be declared
complete, nor may all official moves be replaced with permanent refusal. The
complete official observation/admission replacement is still required.

The optional official TUI session logger was also inspected. It is enabled only
at startup, records most inbound events as variant names without their fields
and does not export all retained inputs. It has not been enabled in the product
or treated as a complete ownership producer.

## Unified official Goal entry points

The remaining `autoapprove/thread/goal/control` call has been removed from
`AutoApproveCore`. Both the request-ID-aware app path and the compatibility
service entry now select the same original-runtime pause/resume implementation;
wait remains an attested read-only lifecycle operation. The app still reserves
its outer request receipt before dispatch. The compatibility entry keeps its
existing call shape and stores resume intent in the selected AutoApprove state
directory.

Both real original-runtime checks pass after the change:

```sh
AUTOAPPROVE_WEBSOCKET_MODULE=/absolute/path/to/ws \
node scripts/codex-child-goal-transition-check.mjs \
  --codex=/absolute/path/to/original/bin/codex \
  --parent-goal-control --local-goal-resume-probe \
  --resume-via-attach-probe --engine-resume --engine-pause
```

The second run adds `--compatibility-entry`, forces the engine to use the older
service entry and directs all compatibility state into the private fixture root.
Both verify a busy parent stays unchanged, the same Goal pauses/resumes, paused
time is not charged, repeated requests and recreated engines dispatch once,
automatic continuation works and cold official history/accounting remain.

## Official child Goals during account transitions

The separate global-account adapter gap was reproduced against an owned original
0.169 daemon: `quiesce` attempted `thread/goal/set` for a real V2 child and the
server rejected it with `-32600`. The account observation now retains the child's
exact Goal identity and its root, immediate parent and root working directory.
This optional lineage field preserves decoding of older transition journals.
Quiescence and continuation select the already-proven original child lifecycle,
while ordinary roots retain their existing public Goal and turn operations.

Before each child mutation, the adapter checks the selected account/server,
ancestry, reserved turn, Goal UUID, objective, budget and nondecreasing counters.
It does not send child user input or a parent message. Pending input/background
jobs are checked separately after Goal activation, because an active Goal masks
those blockers in the ordinary summary. Cancellation is propagated into the
detached child lifecycle operation.

Real-runtime verification exposed two additional integration conditions:

- An ordinary observation socket has one eight-second operation deadline. It
  can expire while asynchronous native abort/accounting is settling. These two
  multi-step account adapters now opt into an eight-second deadline per RPC;
  approval capture remains disabled and ordinary observation defaults remain.
- After a daemon restart, an unloaded child summary omits the live-only
  `canAcceptDirectInput` field. A saved V2 owner is checked through its persisted
  ancestry and paused Goal before attachment. Once loaded, the child must again
  explicitly disallow direct input. A missing live capability is not accepted.

This check passes against the original signed complete package:

```sh
AUTOAPPROVE_WEBSOCKET_MODULE=/absolute/path/to/ws \
node scripts/codex-child-goal-transition-check.mjs \
  --codex=/absolute/path/to/original/bin/codex \
  --daemon-package=/absolute/path/to/original/package \
  --complete-package --account-goal
```

The fixture uses the actual production account observe/interrupt/resume adapters,
a real V2 child, native daemon restart and loopback inference. It checks paused
time is not charged, the same Goal UUID/objective/budget and counters survive,
autonomous continuation starts, parent turn IDs remain unchanged, stale parent,
turn and Goal reservations are skipped without changing the paused Goal, and an
already active Goal is not dispatched again. Synthetic login metadata stays in
the private fixture home; no real credentials or user terminals are involved.
It does not prove a complete selected-client migration, a new credential login,
the full coordinator with real TUI witnesses, pause-stage crash recovery or all
already-admitted input races. Those broader requirements remain outstanding.

After these integration changes, the real manual engine pause/resume check also
passes with a busy parent, one dispatch across repeated requests/recreated
engines and cold history retention. The root account transport regression passes
its 13 interruption cases without consuming original approval callbacks. The
offscreen continuation plus lost-acknowledgement regression passes with one Goal
and one ordinary continuation and no repeat on restored coordinator state. The
final build, Goal identity check and diff/script syntax checks pass. The installed
application remains 0.2.311 build 338; this is not a released feature-preserving
official-runtime migration yet.

## Exact-version alternative paths inspected

Original 0.169.0 still implements `accountSession/list` as one managed login,
with workspace switching inside that login. It is not per-client selection of
another saved account (`app-server/src/request_processors/account_processor/
workspace_switching.rs`). Thread resume has no selected-account or new-home
binding (`app-server-protocol/src/protocol/v2/thread.rs`).

The TUI reconnect path uses its retained `AppServerTarget`; it does preserve
cached thread input states in-process, but it does not expose a request to
replace the target of one arbitrary existing client (`tui/src/app/reconnect.rs`).
The current additional-backend registrar only adds the Cloud connection to the
initial backend under its feature gate (`tui/src/lib.rs`), so that code is not
an existing UI for attaching another local account home. `/export` exports
conversation Markdown, not a complete retained TUI state snapshot.

## Retained input through a stable local relay

The owned original-TUI experiment now passes:

```sh
node scripts/codex-official-retained-reconnect-check.mjs --codex=/absolute/path/to/original/bin/codex
```

One unmodified official TUI starts through a private Unix byte relay. It opens
two independent persisted conversations and retains a different unsent Unicode
draft in each. The fixture archives and retains only those two known source
rollouts, copies their histories to another original server's home and switches
only that TUI's relay target. Native reconnect retains the original native TUI
PID, parent PID, start time and executable. Opening both conversations again
confirms both previously offscreen drafts remain exact. Their UUIDs and histories
are retained, neither draft is submitted, and exactly the two seeding model turns
occur. The source shared server and its unrelated Goal remain unchanged.

The experiment also reproduced loss of renamed thread titles with rollout-only
copying. Thread names are metadata-store state. The fixture now copies each
observed name with public `thread/name/set` and verifies it in the destination;
it does not weaken the title assertion to accept first-message fallback names.

This is a viable input-preservation building block for a client already behind
an owned relay. It does not prove arbitrary existing direct-client adoption,
complete retained membership, shared-client conflicts, ephemeral side state,
voice/queued-input recovery, production bridge attestation or crash-safe route
switching. The production selected-migration path is still unchanged. Do not
claim full feature preservation or publish a limited migration from this proof.

## Remaining release requirements

Complete selected-client retained-state ownership, input admission, settings and
Goal preservation, recovery and round-trip migration still require an official
replacement. The existing private producer and lifecycle paths remain in source
until replacements preserve their behavior. Full regression, matching release
build, commit/tag, GitHub DMG and signed update ZIP with checksums, download
verification and local installation/running-version checks remain outstanding.

## Existing-client scope: catalogue and hidden inputs

An additional original 0.169.0 TUI check passes:

```sh
node scripts/codex-official-retained-reconnect-check.mjs \
  --codex=/absolute/path/to/original/bin/codex --overview-ownership-probe
```

It first verifies that two independent conversations have distinct unsent drafts
and restore them through normal command-center navigation. A third root is never
opened by this TUI, yet appears in the same command-center catalogue. The owned
byte relay observes original TUI requests without changing or answering them and
retains only request method and thread UUID. The third root receives no TUI
`thread/resume` or `thread/fork` request.

The fixture then hides the first draft-owning root while the second is displayed.
The hidden root disappears from the command center, stays in the server loaded
set, and its public history does not expose the unsent draft. Two native resume
paths differ:

- `/resume` followed by selecting that exact root restores its hidden draft.
- After navigating away again, direct `/resume <UUID>` displays its history with
  an empty composer instead of restoring the known draft.

The original TUI process/lifetime, unrelated paused Goal and exactly two seeding
model turns remain. No draft is submitted. This confirms a hidden input state
exists outside the visible overview and that the native picker can recover it;
it does not establish a complete per-client ownership list. Direct resume must
not be treated as a read-only inspection of previously cached inputs.

The inspected native sources explain the distinction. `HideAgentsOverviewThread`
only changes the local hidden set; command-center rows include discovered server
history. `apply_resume_picker_selection` captures/restores saved session input,
while direct-ID resume enters `resume_target_session` without that picker wrapper.
The existing-view clean-input checks, complete selected/unselected membership and
admission requirements remain in force; no completeness flags have been inferred
from this experiment.

The initial development run also exposed managed daemons being created in the
throwaway homes, consistent with live AutoApprove's Codex process discovery.
Those specific test daemons were stopped. Accepted runs use a byte-identical,
OpenAI-signed server copy under an owned fixture basename, as already done for
the TUI, and assert no managed-daemon PID files appear. The original two-draft
cross-home relay experiment also passes after this isolation correction. The
installed app and user terminals were not changed.

## Newer official source audit

GitHub was rechecked: the latest stable release is still `rust-v0.169.0`; a newer
official prerelease, `rust-v0.171.0-alpha.7`, is available. Its source archive was
read without building, installing or executing the prerelease. The archive's Git
PAX commit is `73c4af9125a8d5e9aabe5aa900eecf70214ba856`; SHA-256 is
`005cc2b19bce1f5164706204012f01f0a37f647a0b73444d4f374fefe9433df7`.

The inspected request schema provides no local TUI retained-input inventory.
The new MCP statusline-provider code is a staged resource reader; production
source contains no calls to its snapshot reader. Its `StatuslineState` projects
one displayed conversation's ID, model, workspace, usage, permissions and run
state, with no cached root set or retained draft/queue inventory. The internal
`owns_thread_for_routing` helper still reads in-memory TUI stores rather than
exposing an external census. These source observations do not prove prerelease
runtime parity and have not justified a runtime upgrade.

The missing existing-client scope/input observation remains a concrete obstacle
to a fully verified official-runtime migration. The owned relay proof is useful
for an already-enrolled client, but does not upgrade an arbitrary already-running
direct client. No existing feature has been removed or declared complete, and
release/installation remain unfinished.

## Previous blocked audit

The objective remains using original official Codex while preserving the existing
features. The same missing complete client-scope/input admission prerequisite has
persisted through the account-adapter implementation, the owned scope/picker
experiment and the subsequent source/contract revalidation. Earlier independent
Goal and storage work made progress, but it does not supply this missing fact for
an arbitrary already-running direct TUI.

The released coordinator requires complete selected/unselected membership and
rejects a selected client with drafts, questions, queued input or independent
work. A rollout lock, stored subtree, loaded list, visible catalogue or current
UUID does not prove those conditions. Original 0.169 runtime experiments and the
inspected 0.171 alpha source do not provide the required external TUI inventory
and admission primitive. The already-enrolled relay preserves native input, but
has not adopted arbitrary existing direct clients or established their scope.

This audit does not reintroduce the superseded stronger requirement to keep a
native PID alive or carry hidden drafts across the released exit/relaunch path.
The obstacle is establishing the actual released eligibility and selection
conditions before invoking that path. Declaring incomplete observations complete,
dropping selected migration, using the modified runtime again or silently limiting
adoption would not satisfy the unchanged objective.

No supported implementation path meeting the full current contract remains
established. Continuing requires an official observation/admission facility or an
explicitly agreed change to the existing-client migration contract. No such
contract change has been approved. Preserve the working changes and evidence;
the goal was recorded blocked, not complete. The user has subsequently resumed
it; the next blocked audit starts afresh rather than reusing the prior count.

The source HEAD is still `0f2fe867f6c9ad51d1b5785ec1ecfda2b8cbb62a` and the
installed app is still 0.2.311 build 338. Version increase, matching release
build/source commit/tag, GitHub DMG and signed update ZIP/checksums, download
verification and local reinstall/running-version verification remain undone.

## Resumed investigation: cooperative enrollment

The user resumed the goal and explicitly clarified the selection contract:
when a terminal retains conversations A and B, moving it to another login group
must move both A and B to the new account. Moving only the displayed B while
leaving A on the original account is not the requested behavior.

The newer official source was inspected for an in-process target-change route.
`BackendSessions` preserves per-backend parked input, but its production startup
registrar adds the Cloud backend, not an arbitrary new local login home. Backend
switching selects an already registered backend. Ordinary reconnect reconnects
the retained `AppServerTarget`; the native daemon menu runs a shared daemon
restart, rather than retargeting one live client. This is a source audit, not an
execution or installation of the prerelease.

A narrower enrollment primitive now passes against original 0.169.0:

```sh
node scripts/codex-official-retained-reconnect-check.mjs \
  --codex=/absolute/path/to/original/bin/codex --cooperative-adoption-probe
```

The fixture starts an original TUI with a direct connection, verifies distinct
drafts in A and B, and explicitly verifies all three known server conversations
are idle with empty queues/background-terminal lists. It starts a replacement
original server on the same home, stops only the original owned idle server,
then inserts a byte relay at the original endpoint. Native reconnect registers
the already-running TUI through the relay without changing its PID/lifetime.
Both drafts, public Goal state and history survive; exactly two seeding model
turns occur. No live user server, credentials or terminal is used.

The captured reconnect request set references displayed B (`thread/resume`,
`thread/read`, history/background queries). It contains no explicit request for
retained offscreen A, nor the unrelated catalogue root, before the fixture starts
further navigation. Native picker/navigation later confirms that A's draft still
exists. Thus this enrollment does not itself export the retained root set.

This positive result supersedes any blanket assertion that enrollment of an
existing direct TUI is impossible. It requires a coordinated same-home restart
of an explicitly idle source. It proves neither safe enrollment during unrelated
active work, a complete per-client scope, nor moving A and B to a different
account. The shared-server and complete-input requirements for selected account
migration remain. No product completeness flag or feature reduction was added.

The fresh resumed blocked audit starts at this resumed run, rather than reusing
the previous blocked count. This turn made progress through a new owned-runtime
result and the user's explicit all-conversation selection clarification. The
remaining full-scope/admission condition is still unresolved; the goal is active
and incomplete.

### Follow-up audit under the all-conversation requirement

The original 0.169.0 connection schema and account processor do not provide a
selected-client account replacement. `InitializeParams` supplies client metadata
and capabilities, while `InitializeResponse` reports the server's existing home.
`ConnectionSessionState` has transport and capability state, with no independent
authentication manager. The process constructs the thread manager and account
processor from the shared authentication manager and a process-scoped thread
store. `AccountSessionsSwitchParams.account_id` explicitly selects a workspace
within the active login. Its handler pauses admission, unloads threads for a
workspace switch, updates that shared authentication manager and broadcasts the
account update. It cannot stand in for moving one selected terminal to another
saved login/home while preserving unrelated clients.

The screen-driven alternatives were checked against their exact source too.
`agents_overview.rs` filters locally hidden roots from rendered rows. Its hidden
set is removed for an individually selected/resumed root; there is no complete
hidden-root export in that code. The separate agent picker and keyboard cycle
filter `picker_excluded_threads`. Their metadata refresh is scoped to the
current root's descendants and the navigation cache is cleared during thread
state reset. Consequently, reaching the end of those visible menus does not
attest every retained root or input. This source audit extends the existing
owned hidden-draft experiment; no new runtime or physical Terminal check was
performed in this follow-up.

No product migration authority, completeness flag or account-switch fallback
was added. The same prerequisite remains unresolved for the second consecutive
turn of the fresh resumed audit. The earlier blocked-run count remains
historical. Source changes and test evidence are preserved, and the installed
application and published releases remain unchanged.

### Fresh resumed blocked audit

The third resumed turn revalidated the actual migration entry points and owned
runtime results. `ApprovalEngine.codexMigrationObservation` still resolves the
private `CodexNativeRuntimePair.resolveCensus` for both homes before claiming
complete observations. `CodexNativeDisplayedConnection` requires the modified
native TUI/server producer identities and supplies retained references and input
facts. `CodexSessionMigrationCoordinator` still requires complete selected and
unselected clients, unchanged membership, no conflicting ownership and eligible
inputs. No official replacement for those required observations/admission has
been implemented.

The three owned experiment logs explicitly report
`completeClientOwnershipProven: false`. Cooperative enrollment does not reference
offscreen A before further navigation; the positive relay test supplies its own
two-root scope. Neither proves the required A+B scope for arbitrary existing
terminals. GitHub's release API was queried again: the stable release remains
`rust-v0.169.0` and the newest listed prerelease remains
`rust-v0.171.0-alpha.7`; no newer release changes the inspected prerequisite.
The installed plist still reports 0.2.311 build 338 and source HEAD is still
`0f2fe867f6c9ad51d1b5785ec1ecfda2b8cbb62a`.

The original objective and explicit A+B requirement remain unchanged. The first
fresh resumed turn produced a useful cooperative-enrollment result but retained
the same missing scope/admission prerequisite; the next two turns found no
qualifying replacement. This is the fresh three-turn recurrence, independent of
the earlier blocked audit. No live process or job is awaiting completion.

The goal is blocked on complete selected-terminal retained-root/input observation
and admission available with the unmodified official runtime. An official
capability or another verified source of the same complete guarantees is needed
to continue this critical path. The user has not authorized a reduced contract.
The partial implementation and evidence are preserved. Full production migration,
remaining lifecycle/navigation parity, release validation, matching build,
source commit/tag, GitHub signed DMG and update ZIP with checksums/download
verification, installation and running-version check are all still outstanding.
No completion or deployment is claimed.

## Further resume: pause crash boundaries and post-persistence authority

The user resumed the unchanged objective again. A whole-connection route change
was reconsidered: original connection cleanup removes subscriber bookkeeping,
while core thread lifetimes and cached TUI input are separate. That does not
establish complete selected/unselected ownership or authorize moving unknown
retained roots. No lazy, current-root-only or future-client-only migration was
substituted for the explicit all-A+B requirement.

Another required official-runtime lifecycle gap was investigated with real
controller process deaths. The existing production engine fixture now supports
four owned pause checkpoints:

- `deferred`: persistent automatic continuation deferral exists; native interrupt
  has not been sent.
- `settled`: native interrupt/accounting has completed; Goal status is still
  active and continuation is deferred.
- `paused`: the exact Goal row is paused and its deferral removed; the final
  native idle/accounting hook has not been invoked.
- `confirmed`: the native lifecycle succeeded; the outer app action receipt has
  not yet saved its result.

Reproduce one checkpoint after building `autoapprove-checks`:

```sh
AUTOAPPROVE_WEBSOCKET_MODULE=/absolute/path/to/ws \
node scripts/codex-child-goal-transition-check.mjs \
  --codex=/absolute/path/to/original/bin/codex \
  --parent-goal-control --local-goal-resume-probe \
  --resume-via-attach-probe --engine-resume --engine-pause \
  --pause-crash=paused
```

The fixture checks the actual nonzero controller exit and persisted Goal/deferral
state. After recreating the app, repeating the old request ID returns its
reserved receipt without dispatch. Where the Goal is still active, the fixture
reads fresh state and sends one distinct, explicit pause request. Where it is
already paused, it sends no further pause. A second app recreation still cannot
replay the original uncertain request. Subsequent original Goal resume, paused
time exclusion, monotonic accounting, busy parent history and cold-server
history/Goal retention are checked.

This is **not automatic repair** of an uncertain receipt: the original receipt
remains reserved, and the two earlier checkpoints require the fresh explicit
request used by the fixture. It does not prove account-transition crash recovery,
power loss, every crash instruction or already-admitted input/continuation races.

The production pause path now rechecks authority after persistent Goal state
changes and before its final native lifecycle RPC. The account adapter supplies
a separate paused-state authority check, because its pre-pause Goal revision
intentionally includes active status. The latter verifies the same server,
parent lineage, stopped turn, paused Goal revision and nondecreasing accounting.
Reusing the active-state check after the mutation would reject a valid paused
Goal, so the two phases retain distinct expectations.

The owned complete-package account adapter regression also passes after this
change: native daemon restart, same child Goal/budget/accounting, unchanged parent
turns, exclusion of paused time and no repeat of an already-active resume. No
real credentials or user terminals are exercised. The related Goal identity
check, build, JavaScript syntax and whitespace checks pass. An unintended full
check run from an unsupported help argument was stopped; it is not counted as
passing validation.

This resumed turn made implementation and real-runtime verification progress.
The full selected-client migration prerequisite is still unresolved. Release,
installation and running-version acceptance remain outstanding; the application
has not been replaced by this work.

## Follow-up: original watched child is not in the approval frame

The next turn revalidated original disconnect bookkeeping. Removing a connection
removes its live subscriptions, but those are not a complete set of retained TUI
inputs or roots. This supplies no replacement for the unchanged all-A+B scope
and input-admission requirement.

An owned original 0.169.0 TUI now reproduces the separate previously unverified
prior-view navigation issue:

```sh
AUTOAPPROVE_WEBSOCKET_MODULE=/absolute/path/to/ws \
node scripts/codex-subagent-live-check.mjs \
  --codex=/absolute/path/to/original/bin/codex \
  --tui=/absolute/path/to/original/bin/codex \
  --swift-navigation --with-sibling --start-in-sibling-view \
  --expect-primary-return-from-sibling \
  --screen=/private/tmp/owned-prior-view.txt
```

The fixture uses the native Subagents picker to select the exact earlier sibling
UUID before releasing the other child's pending command. Its captured prior
frame shows the disabled child composer and `/root/earlier_sibling` footer. The
approval overlay identifies `/root/approval_fixture`, and its rendered frame has
no prior-view footer. The production Swift navigator approves the owned command
and returns to Main, confirming that the earlier sibling view is not restored.
`--expect-primary-return-from-sibling` deliberately asserts this known incorrect
outcome. Omitting it retains the desired prior-view acceptance check, which the
current production implementation does not satisfy.

The first fixture preparation attempted keyboard cycling with a nonempty parent
draft; the original TUI kept the composer instead. That run ended with its owned
timeout and cleanup. Preparation now selects the exact sibling through the native
picker with an empty parent composer. This new case does not claim simultaneous
parent-draft preservation; its report explicitly sets that field false. Earlier
parent-draft tests remain separate evidence. The later reproduction completed
with a real child command, original TUI and the production navigator; no physical
user Terminal or real account was accessed.

An inferred Main return is therefore not proof of arbitrary prior-view parity.
An old observed footer alone also cannot prove that no intervening view change
occurred. No guessed return target, fallback census or further product change was
added from this investigation. The same complete official retained-state/input
prerequisite has now remained unresolved for two turns of this fresh resumed
run. The previous turn made a required Goal implementation improvement; this
turn has no qualifying product migration progress. The goal remains active and
incomplete, with no release or installation performed.

### Latest resumed run: blocked audit completed

The next continuation found the same mandatory prerequisite unchanged for its
third consecutive turn. Current `ApprovalEngine` still calls the private native
connection census before asserting complete client/thread observations; the
native connection parser still requires modified TUI/server producer identities.
The migration coordinator still requires full selected/unselected membership,
eligible inputs and exclusion of shared owners. It cannot be completed by moving
only a known root or by treating the reconnect/request subset as complete.

The GitHub release API was checked again: stable `rust-v0.169.0`, newest listed
prerelease `rust-v0.171.0-alpha.7`. No newly published official release supplies a
new candidate capability beyond the already inspected versions. No new runtime
test was needed to restate the same existing limits, and no test/job is pending.
Source HEAD remains `0f2fe867f6c9ad51d1b5785ec1ecfda2b8cbb62a`; the installed
plist remains 0.2.311 build 338. The current whitespace check passes.

This latest run is counted independently of earlier blocked runs: (1) the Goal
post-persistence authority improvement and four owned crash outcomes advanced a
required lifecycle component while full retained scope/admission remained
missing; (2) disconnect revalidation and the owned prior-view defect did not
provide that missing capability; (3) current source/release revalidation again
provides no qualifying implementation route. The third turn is no progress.

The objective, all-A+B selection and unrelated-client preservation are unchanged.
The goal is blocked on a verified mechanism that provides complete retained
scope/input admission using the unmodified official runtime. The original-view
parity gap is also still open. The user has not authorized a reduced contract.
Earlier Goal implementation and runtime test evidence are preserved, but they
cannot prove full selected-client migration or complete feature parity. Matching
release build/validation, source commit/tag, signed DMG and update ZIP plus their
checksums, publication/download verification, installation and running-version
acceptance remain unperformed for this work. No completion is claimed.
