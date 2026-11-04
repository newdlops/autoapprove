# Native TUI inventory prototype

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
It never builds, installs, launches or deletes a Codex installation.

```sh
node scripts/prepare-codex-native-inventory.mjs \
  --source=/absolute/upstream/codex-rs \
  --output=/absolute/new/prototype
```

From the prepared directory, owned native validation uses Rust 1.95.0:

```sh
cargo +stable test -p codex-tui --features autoapprove-native-inventory native_inventory --jobs 2
cargo +stable build -p codex-tui --features autoapprove-native-inventory --bin codex-tui --jobs 2
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
  compilation or semantic test pass.
- `node scripts/codex-native-inventory-contract-check.mjs` passed 11 checks for
  nonce/PID/admission rejection, invalid/oversized responses, private socket/file
  handling, no-overwrite source preparation and changed-source rejection. This uses synthetic socket replies
  and does not prove the native producer.
- Four native Rust tests cover actual retained App state, draft non-disclosure
  and non-mutation, exclusive socket/nonce delivery, private-parent rejection and
  invalid request/file preservation. The three transport tests passed using the
  actual patched transport source with minimal event-channel types and matching
  direct dependency pins. The App snapshot test and full TUI compile remain
  pending. This does not verify the full upstream dependency graph or actual TUI
  event dispatch.
- Reproduce that isolated transport check with
  `node scripts/codex-native-inventory-transport-check.mjs --source=/prepared/codex-rs`.
  It uses its own Cargo cache and never launches a Codex session. The original
  full-workspace dependency fetch remains a separate job.
- The initial offline baseline could not resolve the official pinned Git
  dependencies. Their existing fetch is retrying Chromium/V8 submodule network
  failures; native build/test results remain pending.

Complete daemon connection/peer census, revision binding, reversible admission
barriers, full pending-state preservation, actual credential/backend attestation
and end-to-end selected migration still need implementation and owned verification.
No production feature completion follows from this diagnostic prototype.

The local reviewed-source import used for the initial experiment excluded a
bubblewrap license symlink. It is suitable only as the recorded source inspection
fixture, not a distributable source package. Use complete upstream source and
preserve license material before any distribution.

Upstream source context in the patch is from OpenAI's Apache-2.0 licensed Codex;
the unmodified upstream license and notice are preserved alongside this patch.
