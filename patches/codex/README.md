# Native TUI and server inventory prototypes

This source-only, opt-in patch targets Codex 0.166.0, upstream commit
`6ff1e1ca3b30fc8b914720681fcf5fe62e95f856`. It is not installed by AutoApprove,
does not replace the official CLI, and does not enable session migration.

The previous design's no-fork preference was an implementation proposal, not an
explicit user prohibition on preparing isolated source experiments. Prototype
preparation and owned tests can proceed. Shipping or replacing user clients is a
separate reviewed decision; an unanswered preference is not installation consent.

## What is connected

With Cargo feature `autoapprove-native-inventory` and the explicitly supplied
`AUTOAPPROVE_NATIVE_INVENTORY_SOCKET`, a TUI listens on an exclusive Unix socket
inside a private, user-owned directory. Without the feature or environment
variable, no inventory listener starts.

One bounded local request supplies a nonce. The native App event loop answers
from its actual retained stores, including navigation without a listener,
side-thread and parent relations, replay caches, retained input states, current
composer/protected-prompt/queue flags and pending lifecycle operations. It exports
no draft, attachment, transcript, Goal, account or credential content. Catalog
references are separate from input/routing state.

The listener accepts only the current user's peer, bounds request/response size
and duration, and never replaces an existing socket/file. Its event bypasses
user-input logging. The snapshot is a diagnostic observation, not a lock:
`membershipComplete` and `admissionGranted` are always false. A PID/nonce check
alone is not daemon peer/backend attestation.

## Reproduce the source preparation

Obtain and review the exact upstream source separately. The preparation command
expects its `codex-rs` directory, checks pinned lock/toolchain/source preimages,
copies to a new output, applies the reviewed patch and checks every postimage.
The pinned release manifest says 0.166.0 while its lockfile's 170 local workspace
entries still say 0.0.0. Preparation normalizes only those local version fields,
checks the exact resulting lock hash and preserves every registry/Git dependency
byte. The same mismatch was reproduced in unmodified upstream source; no external
dependency update is authorized by this normalization.
It never builds, installs, launches or deletes a Codex installation.

```sh
node scripts/prepare-codex-native-inventory.mjs \
  --source=/absolute/upstream/codex-rs \
  --output=/absolute/new/prototype
```

From the prepared directory, owned native validation uses Rust 1.95.0:

For owned debug builds, prefix Cargo commands with
`env CARGO_INCREMENTAL=0 MACOSX_DEPLOYMENT_TARGET=14.0 CARGO_PROFILE_DEV_DEBUG=0 CARGO_PROFILE_TEST_DEBUG=0`.
This matches the app's macOS 14 baseline and avoids accumulating multi-gigabyte
incremental compiler caches. An initial peer-enabled binary link failed when the
prototype cache filled the disk; only that owned cache was removed before retry.

```sh
cargo +stable test -p codex-tui --lib --features autoapprove-native-inventory native_inventory --locked --jobs 2
cargo +stable build -p codex-tui --features autoapprove-native-inventory --bin codex-tui --locked --jobs 2
# Optional full CLI for the owned second-client resume check:
cargo +stable build -p codex-cli --features codex-tui/autoapprove-native-inventory --bin codex --locked --jobs 2
```

Only use the resulting binary in a fresh owned test home/PTY, with private socket
parent and no user credentials. Native execution must also isolate the test TUI
from production AutoApprove discovery/control before starting it. Do not attach
it to existing user sessions merely to test this patch.

The local diagnostic consumer requires the test TUI's independently known PID:

```sh
node scripts/codex-native-inventory-read.mjs \
  --socket=/private/test-directory/inventory.sock --expected-pid=12345
```

## Current evidence and remaining work

- The patch was reproduced from clean pinned source, with all 10 postimages
  checked. Rustfmt parsed/formatted the changed Rust files; that is not a Rust
  compilation or semantic test pass by itself.
- `node scripts/codex-native-inventory-contract-check.mjs` passed 21 checks for
  nonce/PID/admission rejection, invalid/oversized responses, private socket/file
  handling, no-overwrite source preparation, changed-source rejection and exact
  local-only lock normalization. This uses synthetic socket replies
  and does not prove the native producer.
- Four native Rust tests cover actual retained App state, draft non-disclosure
  and non-mutation, exclusive socket/nonce delivery, private-parent rejection and
  invalid request/file preservation. The three transport tests passed using the
  actual patched transport source with minimal event-channel types and matching
  direct dependency pins. The full native TUI library subsequently compiled and
  passed all four filtered tests with the pinned dependency graph and `--locked`.
  The standalone `codex-tui` binary also built successfully.
- Reproduce that isolated transport check with
  `node scripts/codex-native-inventory-transport-check.mjs --source=/prepared/codex-rs`.
  It uses its own Cargo cache and never launches a Codex session.
- The initial offline baseline lacked pinned Git dependencies. The subsequent
  fetch progressed through Chromium/V8 despite transport retries, then ended
  because the local package version metadata required lock normalization.
  Unmodified upstream source reproduced that error. After the exact local-only
  correction, the full TUI tests and standalone binary build passed with `--locked`.
- `Tests/fixtures/codex-native-inventory-live.py` ran the built binary in its own
  PTY with `--no-daemon`, an empty private home and a loopback model fixture.
  Repeated real App event-loop reads retained the primary identity and an unsent
  draft; a fresh resize repaint retained the exact draft and inventory exported
  none of its text. No inference request was submitted. All 19 original controller
  session identities remained present, and the test TUI was excluded from product
  discovery. One external startup request was blocked by the fixture proxy.
  The first probe omitted `--no-daemon` and exited because the standalone binary
  has no complete daemon package; that failed attempt is not migration evidence.
  This proves embedded TUI observation only, not daemon-connected peer coverage,
  actual offscreen unsubscribe/replay lifecycles, Goal continuation or login change.

The same fixture subsequently connected the actual TUI to an owned, unmodified
0.166.0 app-server on the standard private Unix socket. The server's live thread
ID and cwd matched the TUI snapshot; repeated reads preserved the draft with no
inference or unsubscribe request. This directly launches the shared server and
does not exercise the managed daemon supervisor.

With `--navigation`, the fixture materialized an owned thread using only a
loopback synthetic provider (two requests including background title work),
parked its unsent draft through the native overview and created another thread.
An owned wire proxy observed the actual `thread/unsubscribe` request and success
response. The old thread disappeared from local listeners/channels/navigation
while remaining in `overviewInput` with `hasDraft=true`; its text was not exported.
Selecting it through the overview restored the exact draft on a fresh repaint.
All 19 original controller identities remained intact. The unsubscribed runtime
remained server-loaded, so loaded IDs cannot replace subscriber or retained-input
ownership evidence.

Before the input-preservation fix, a distinct direct `/resume <ID>` return restored the conversation but did not
restore the parked draft in this exact upstream version. That attempt failed the
preservation gate; the overview result did not make it pass. The optional
overlay fix and its direct-resume revalidation are recorded below.

The optional full CLI also built successfully with the same source patch and
pinned dependency graph. With `--navigation --peer-cli=/absolute/target/debug/codex`,
the fixture copies it under a non-agent basename before starting a second owned
TUI via `resume`. Both native producers reported the same primary root. After
the first TUI navigated away and received an actual unsubscribe ACK, it retained
the original root's unsent draft while the second TUI still reported that root.
The union excluding catalog-only references therefore had two sampled owners of
the original conversation. Overview return restored the first TUI's exact draft;
both trial clients were cleaned up and all 19 original controller identities
remained present. This is evidence from two independently queried clients, not a
daemon-attested census of all peers or proof of two live subscriptions.

Run the owned checks with an independently known local controller node UUID:

```sh
python3 Tests/fixtures/codex-native-inventory-live.py \
  --tui /absolute/prototype/codex-rs/target/debug/codex-tui \
  --server /absolute/reviewed-0.166.0/bin/codex \
  --expected-node YOUR_LOCAL_CONTROLLER_UUID \
  --output /absolute/private/check-output
# Add --navigation for the loopback-only turn, unsubscribe and overview return.
# Omit --server for the embedded read-only probe.
```

The optional server is copied into the private fixture with a basename excluded
from production agent discovery. No real daemon or user session is stopped. The
wire proxy retains only owned unsubscribe metadata; it is not native peer
attestation. These tests do not prove complete multi-client ownership, independent
voice/replay preservation, Goal continuation, real credentials or migration.

Complete daemon connection/peer census, revision binding, reversible admission
barriers, full pending-state preservation, actual credential/backend attestation
and end-to-end selected migration still need implementation and owned verification.
No production feature completion follows from this diagnostic prototype.

## Optional native server observation

`0.166.0-native-server-inventory.patch` adds a separate, opt-in server producer.
Prepare both patches with `--with-server-inventory`; preparation verifies all 32
final source postimages, the two patch digests and the same local-only lock correction.
The server overlay extends two TUI files after checking their exact TUI-phase
postimages. The original source and all other preimages remain pinned separately.
The first reproduction detected Git skipping a Git-style patch inside the
ignored nested fixture; the final patch uses the same unified-diff format as the
TUI patch and was reproduced successfully. Existing output trees are never reset.

With the server Cargo feature `autoapprove-native-inventory` and explicit private
`AUTOAPPROVE_NATIVE_SERVER_INVENTORY_SOCKET`, the actual server transport loop
answers nonce-bound reads from its connection map and the `ThreadStateManager`
subscription stores. This includes uninitialized transport connections, native
connection IDs, initialized-client IDs, per-connection thread IDs and per-thread
subscriber IDs. Client-declared names/versions are labeled untrusted. It exports
no transcript, draft, Goal, account or token content and exposes no new LAN RPC.
A contended subscription snapshot times out after 100 ms; local socket requests
retain the two-second/1 MiB bounds, private ownership and exclusive binding checks.

These stores are not yet bound to collected client inventories, pending transport
events or one topology revision. Every response therefore has `consistentRevision`,
`membershipComplete` and `admissionGranted` false, including successful reads.
This is a server-side observation component, not permission to migrate a client.

```sh
node scripts/prepare-codex-native-inventory.mjs \
  --source=/absolute/upstream/codex-rs --output=/absolute/new/prototype \
  --with-server-inventory
# From the newly prepared source:
cargo +stable test -p codex-app-server --lib \
  --features autoapprove-native-inventory native_inventory --locked --jobs 2
cargo +stable build -p codex-cli --bin codex --locked --jobs 2 \
  --features codex-tui/autoapprove-native-inventory,codex-app-server/autoapprove-native-inventory
# Read only an owned server with its independently known PID:
node scripts/codex-native-inventory-read.mjs --server \
  --socket=/private/test-directory/server-inventory.sock --expected-pid=12345
```

The owned live fixture's `--server-inventory` option requires this producer and
checks its real subscriber sets before navigation, after unsubscribe and after
return. Combine it with `--navigation --peer-cli=...` to require two actual TUI
clients. The full native server library compiled with `--locked` and passed all
five filtered tests: actual two-client subscription changes and read non-mutation,
uninitialized transport inclusion without attestation, and the three private IPC
boundary tests. The full CLI then built with both optional features and `--locked`.
The owned two-TUI live check also passed: the actual server reported two subscribers
before navigation, one after the first client unsubscribed, and two after overview
return. Both clients still retained the original root after unsubscribe, including
the first client's offscreen draft; its exact draft returned on a fresh repaint.
All 19 original controller identities survived cleanup. Two loopback synthetic
inference requests were served and two external startup requests were blocked.
The short-lived observer RPC connections can close asynchronously; the fixture
waits up to five seconds for its owned setup to settle, without claiming revision
consistency. No managed supervisor, native peer attestation, real auth, admission
barrier or migration was verified. The 21 passing Node checks separately prove
consumer/bootstrap boundaries only.

### macOS process-instance identity extension

The optional server overlay now captures the kernel `LOCAL_PEERTOKEN` on accepted
Unix streams and decodes it with the SDK's libbsm accessors. It records PID,
effective UID/GID and audit PID version. The latter identifies the process
instance without treating a PID alone or a client-declared version as identity.
The TUI inventory also reports its own `TASK_AUDIT_TOKEN` identity. TCP/remote
connections and unsupported platforms receive no manufactured identity.

The actual macOS kernel identity test passed, and all 11 Unix socket tests passed
with the peer event delivered before ordinary application messages. The explicit
feature-off test also passed. The five full server inventory tests passed again
with the new event. The full CLI and standalone TUI then built successfully with
incremental caching disabled and the macOS 14 deployment target.

The owned fixture's `--direct-server` mode bypasses its wire proxy and compares
the daemon's recorded subscriber identity, the TUI's self identity and kernel
credentials on the independently queried private TUI socket. In contrast,
`--expect-proxy-peer` requires the daemon to report the actual proxy process,
not either TUI, despite forwarded client names. Both live checks passed with two
real TUIs: direct peers matched all three identity sources, and proxy peers were
correctly distinguished. Subscriber counts remained two/one/two across navigation
and return, exact drafts were restored, and all 19 original controller identities
survived cleanup. Both are owned observation tests; the daemon still reports
`clientInventoryBound=false` and grants no admission, credential switching or
selected-session effects. This does not prove a complete peer census, a consistent
cohort revision, executable attestation, real SSO or migration.

The local reviewed-source import used for the initial experiment excluded a
bubblewrap license symlink. It is suitable only as the recorded source inspection
fixture, not a distributable source package. Use complete upstream source and
preserve license material before any distribution.

Upstream source context in the patch is from OpenAI's Apache-2.0 licensed Codex;
the unmodified upstream license and notice are preserved alongside this patch.

### Runtime-start pause lease (separate optional control)

The server overlay also contains an explicitly enabled control endpoint. It is
separate from both read-only inventory sockets. Building with
`codex-app-server/autoapprove-native-transition` and setting
`AUTOAPPROVE_NATIVE_TRANSITION_SOCKET` enables it; default builds do not.
The endpoint requires an owner-only parent, native same-user kernel credentials,
the exact server generation and `server-all-runtimes` scope. It supports only
`pause`, `status`, `renew` and `release`, with a connection-bound lease and a
30-second monotonic expiry. Owner loss, server teardown and invalid or expired
requests release the pause. A second owner cannot acquire the existing lease.

This holds the actual server's runtime-start admission guard. Existing work
continues until explicitly stopped; Goal status, credentials and accounts are
not changed by the endpoint. It does not authorize selected-session migration,
provide a complete census, or prove callback/SSO quiescence. Different native
server instances have independent admission guards. Eight native lease tests
and five inventory tests passed; an upstream auth-revision proof regression also
passed with an explicit 32 MiB Rust test stack. The initial broader filter run
failed from stack overflow and is not a successful verification.

Both source patches reproduce 32 final postimages from the pinned upstream tree;
the local-version-only lock normalization still changes 170 entries with no
external dependency changes. Live control verification is recorded separately
from these source and unit checks.

The full CLI and standalone TUI built with the transition feature enabled and
`--locked`. The owned two-TUI live fixture then passed with `--server-inventory
--direct-server --navigation --peer-cli=... --admission`: new runtime starts
were rejected while the lease was held, an existing active Goal required an
explicit native Goal pause and turn interrupt, and its exposed paused Goal
fields remained unchanged after release. A separate real backend and its Goal
were unaffected. The original TUI's exact unsent draft survived a fresh repaint
after the whole sequence; native subscriber counts remained two/one/two across
navigation. All 19 original user session identities survived fixture cleanup.
Five loopback synthetic inference requests were served; rejected input never
reached the provider. This proves the owned pause/interrupt sequence, not a real
credential switch, exact full persistent Goal row preservation, or resume-once.

### Preserve parked input during explicit resume

The server overlay now also fixes the TUI's explicit prepared-resume path.
Previously it retained input only for a displayed external-writer view, ignoring
input parked by overview navigation. It now copies the exact destination's
retained input and consumes that parked entry only after successful attachment.
An active live turn uses the same in-flight preservation rule as overview return;
the patch does not auto-submit the restored queue.

The pre-fix owned direct-resume probe reproduced the missing draft again. The
native integration test passed all nine configured/explicit/runtime/remote cwd
combinations with distinct displayed and parked destination drafts; preparation
kept the displayed draft, and activation restored only the destination draft.
The adjacent missing-cwd metadata regression passed. Both binaries built, and
the owned two-TUI direct-resume plus admission probe passed: exact draft on fresh
repaint before and after Goal pause/interrupt/release, two/one/two subscribers,
separate backend unaffected and all 19 user session identities retained after
cleanup. The fixture accepts only the exact native `-32600`/`no active turn to
interrupt` race after Goal pause and still requires independently observed idle.
It does not end its held provider response until native idle is proved. This
fix and its tests do not establish real account switching or visual layout QA;
no browser viewport or manual terminal visual signoff is claimed.
