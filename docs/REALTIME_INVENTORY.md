# Real-time inventory and terminal observation

`networkWaitVersion: 1` on the dashboard and node inventory advertises optional
conditional waiting. The initial/unconditional request always returns promptly.
A browser sends `If-None-Match` with `Prefer: wait=15` after a complete inventory.
The server responds on a semantic change or returns empty 304 at the deadline.
`Preference-Applied: wait` confirms acceptance; absent support/capacity retains
the ordinary 2.5-second browser cadence. Successful waits rearm after 100ms.

Local engine publication and peer-read changes wake the existing change-signal
mechanism. A response burst coalesces for at most 80ms; a one-second fallback
also checks time-dependent questions,screen shares and network metadata.
Revisions alone do not force a body: newly encoded identical content retains
its validator and the held request. Gzip representation-specific validators
and original node identity checks are unchanged.

At most eight dashboard waits and eight inventory waits are held per service.
Additional/unconditional clients receive immediate ordinary responses. Ordinary
requests retain their existing connection/traffic slots. A visible dashboard
shares at most eight upstream watches,one per capable peer. Peer waits use
six seconds and a seven-second read budget,without speculative duplicate reads.
Unsupported peers keep ordinary bounded inventory reads. A peer's last verified
presentation can remain visible during the bounded wait; a failure becomes an
offline view. This observation never authorizes terminal input.

The last dashboard waiter releases upstream work after a 250ms grace period,
covering the next-request gap. Hidden/closed browsers cancel their owned wait.
Foreground/online/manual refresh can replace it immediately. Node/route changes,
generation checks,HTTP socket ownership and cancellation still apply. A fresh
GET fallback preserves its wait preference. No POST enters this recovery path.

Terminal change signals now carry a monotonic revision. A completed native
screen cache is reusable only for the same target,generation and source revision.
New screen/cursor/control notifications therefore invalidate the previous
observation without reducing polling intervals. In-flight sharing and unchanged
screen throttling remain in place. Existing wire v3 bit schemas,gzip,PTY raw
bytes and rendered-offset recovery are unchanged.

## Reproduce

Build the matching release Core,then run:

```sh
node scripts/inventory-wait-check.mjs --build=.build/release
node scripts/realtime-check.mjs --build=.build/release
node scripts/realtime-check.mjs --webkit --build=.build/release
```

For a before comparison,pass `--baseline --build=PATH_TO_0.2.180_RELEASE` to
`realtime-check.mjs`,with a separate `--output` directory. It links the same
synthetic fixture against each Core and loads the current frontend. The old
Core has no wait capability and follows the existing polling path. HTTP bytes
include observed request/response headers and bodies,excluding TCP overhead.
Source reads,rendered-list delays,terminal updates,manual refresh and background
recovery are recorded. These are loopback synthetic measurements,not physical
phone/LAN latency or whole-app CPU measurements.
