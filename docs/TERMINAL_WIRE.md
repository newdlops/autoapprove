# Terminal wire versions 2 and 3

This is the output transport for existing terminal snapshots and managed PTYs.
Source identity checks,permissions and committed PTY offsets retain their existing
semantics. Inputs can negotiate the persistent channel below; existing HTTP input
remains the compatibility path. Neither transport creates a terminal session.

## Persistent input channel

Version 0.2.190 adds `GET /api/input/socket?node=…`, using WebSocket subprotocol
`autoapprove-input.v1`. The same Host/Origin checks and public gateway cookie apply.
No credential enters the URL. The handshake requires an Origin, version 13 and a
16-byte WebSocket key. Client frames must be masked and have no extension bits;
fragmentation and interleaved control frames are bounded and validated.

Each binary message starts with `41 49 01`, one kind byte and a UInt32 big-endian
sequence, followed by at most 16,001 payload bytes. WebSocket supplies the length.
Kinds are bind(0), ready(1), PTY input(2), native input(3), cumulative ACK(4),
failure(5), ping(6) and pong(7). A ready message with payload `[1]` is the
authenticated bridge greeting; empty ready confirms the binding. Ping/pong use
sequence zero and echo an eight-byte monotonic timestamp.

Bind has sequence zero and a JSON identity: native mode uses sessionID, streamID
and revision; PTY mode uses ptyID, streamID, clientID and sequenceBase. The owner
validates the binding without writing input. Each subsequent input increments
the channel sequence by exactly one. PTY input is at most 16,000 raw bytes and
uses `sequenceBase + sequence` at the existing writer. Native input starts with
the index in `[characters,enter,escape,interrupt,up,down,left,right,backspace,delete,
home,end,tab]`, followed by UTF-8 text for characters only (at most 8,000 bytes).
Every write still revalidates the source generation and permissions.

The browser allows at most 16 outstanding messages and 64,000 payload bytes.
It sends the first event immediately and coalesces subsequent bursts for up to
4 ms. The receiver serializes input across asynchronous writes, reserves the
sequence before delivery and acknowledges only success. A socket does not write
the HTTP receipt archive per key. It never retries a failed or uncertain write.
Only acknowledged idle channels reconnect automatically, retaining the PTY
sequence. Unsent input remains separate from uncertain outstanding input.
Unsupported upgrades may fall back to HTTP before any input is sent.

The 443 relay negotiates features with `X-AutoApprove-Relay: 2`: legacy connectors
still receive hello `[1]`; new peers receive `[1,3]` (input sockets and compression).
Relay kinds 7/8/10 carry socket data/close/credit. Browser socket IDs and exact
upload credit survive Durable Object hibernation in socket attachments. Kind 9
carries a UInt32 big-endian original length and one complete gzip member, only
when it saves bytes for an output chunk of at least 1,024 bytes. Its declared and
decoded size must agree and stay at most 32 KiB. HTTP credit counts decoded bytes;
queued decoding participates in backpressure and preserves DATA/END order.
Interactive replies have priority over queued bulk output. While an input socket
is active, bulk chunks are limited to 8 KiB. Old relay code stays compatible.

Reproduction: `node scripts/input-channel-check.mjs` and
`node scripts/cloudflare-relay-wire-check.mjs` cover protocol bounds/faults;
`scripts/cloudflare-worker-check.mjs --socket --browser --pin --latency=100`
exercises the real local Worker, native gateway and private terminals with an
added 100 ms in each connector direction. Omit `--socket` for the HTTP comparison.
These checks do not measure physical phones or the public Cloudflare path.

## Negotiation and compatibility

`terminalWireVersion` advertises the highest supported version (2 or 3). The
browser requests the minimum supported by its gateway and owning Mac,using
`wire=2` or `wire=3`. Version 3 retains version 2 support. The response media
types are `application/vnd.autoapprove.terminal-v2` and
`application/vnd.autoapprove.terminal-v3`. Without negotiation,the server retains
`text/event-stream` and the browser retains native `EventSource`. A negotiated
fetch also accepts an SSE response; a v3 fetch accepts a v2 response too. A
gateway forwards only a version allowed by the request and preserves the
authenticated owner's response format. Existing gzip streaming remains per
connection,with an incremental flush after each logical event.

## Envelope

Each record is `41 41 02` (v2) or `41 41 03` (v3),one mode byte,a canonical unsigned base-128 varint
payload length,and exactly that many payload bytes. The payload limit is
2,000,000 bytes. Length and integer decoding reject noncanonical continuation,
overflow,truncation and unsupported modes. A partial record at EOF is an error.

| Mode | Event |
| --- | --- |
| 0 | screen |
| 1 | alive |
| 2 | output |
| 3 | failure |
| 4 | heartbeat,empty payload and no dispatched event |

Bit 7 on modes 0–3 means the entire payload is UTF-8 JSON. Unsupported Encodable
representations use this whole-value fallback with the existing JSONEncoder.
This preserves legacy JSON behavior for representations such as unsafe JS
integers rather than rounding them in the typed decoder. The heartbeat is the
five bytes `41 41 02 04 00` or `41 41 03 04 00`.

## Typed payload

A UInt32 little-endian presence mask precedes the values for its set bits in
ascending bit order. The mask is followed by a varint extra-field count and
that many typed string-key/value pairs. Duplicate fields and nonstring keys
are errors. Absent fields,null and false are distinct.

The Swift encoder reuses the fixed-field mask for duplicate detection and walks
only its set bits in ascending order. Extra names retain string-based duplicate
checks. This does not change the wire bytes or apply 32-bit arithmetic to
sequence or PTY offset values.

These bits are fixed for version 2. Add future fields through the extras map;
changing the order or assigning another mask bit requires a protocol version.

| Bit | Field | Bit | Field |
| --- | --- | --- | --- |
| 0 | sessionID | 12 | question |
| 1 | screen | 13 | screenPatch |
| 2 | revision | 14 | screenCopy |
| 3 | observedAt | 15 | appearanceUnchanged |
| 4 | keys | 16 | ptyID |
| 5 | inputReason | 17 | offset |
| 6 | appearance | 18 | data |
| 7 | cursor | 19 | reset |
| 8 | streamID | 20 | columns |
| 9 | nativeDisplay | 21 | rows |
| 10 | outputReason | 22 | exitCode |
| 11 | sequence | 23 | canInput |

Each typed value starts with a byte whose high nibble is the tag. The low nibble
is an inline count or unsigned magnitude from 0 through 14. A low nibble of 15
uses a following canonical varint instead. Integer magnitudes represent `n`
for unsigned values and `-n-1` for negative values. Typed integers must fit the
JavaScript safe-integer range. Bitwise operations apply to bounded bytes and
flags;large sequence/offset values are accumulated without 32-bit truncation.

| Tag | Value |
| --- | --- |
| 0 | null;low nibble must be zero |
| 1 / 2 | false / true;low nibble must be zero |
| 3 / 4 | unsigned / negative integer |
| 5 | finite Float64 little-endian,8 bytes;low nibble zero |
| 6 | UTF-8 string,count in bytes |
| 7 | array,count in values |
| 8 | object,count in string-key/value pairs |
| 9 | raw canonical Base64 bytes;default decoder reconstructs the string |
| 10 / 11 | lowercase / uppercase hex,count in raw bytes,at most 256 |
| 12 / 13 | lowercase / uppercase UUID,16 bytes;low nibble zero |
| 14 / 15 | lowercase / uppercase RGB,3 bytes,restoring `#`;low nibble zero |

UTF-8 is decoded strictly. The receiver also limits nesting to 64 and decoded
value nodes to 100,000,and applies a 2,000,000-byte string budget. Unknown extra
keys remain ordinary own enumerable properties,including names such as
`__proto__`. Screen patch/copy and cursor offsets retain their UTF-16 units.

## Version 3 compact snapshots

The root mask,field order and v2 typed values are unchanged. V3 adds five
fixed schemas in previously invalid Float64 low nibbles. A v2 decoder still
rejects these values. The encoder uses them only for matching native DTO types;
other objects retain ordinary typed objects or whole-value JSON fallback.

| Byte | Snapshot | Body,in order |
| --- | --- | --- |
| `51` | attribute run | unsigned offset,length,flags; optional typed fg,bg strings |
| `52` | cursor | control byte; unsigned offset,padding |
| `53` | appearance | color-presence byte; optional typed foreground,background strings; unsigned run count; run bodies without `51` prefixes |
| `54` | screen patch | typed baseRevision; unsigned baseLength,prefix,suffix; typed text; unsigned length |
| `55` | screen copy | typed baseRevision; unsigned baseLength,start,count; typed head,tail; unsigned length |

Bytes above are hexadecimal. Unsigned fields use the existing canonical
base-128 varint and JavaScript safe-integer bounds. RGB strings retain the
existing exact-case packing,including ordinary UTF-8 for mixed case.

Run flag bits 0–8 indicate fg,bg,bold,dim,italic,underline,strike,inverse,hidden
presence. Bits 9–15 hold the seven boolean values in the same order. A true
bit without its presence bit is invalid. Thus absent,false and true remain
distinct without per-property names or boolean bytes. Flags above bit 15 are
invalid. Cursor bits 0 and 1 mean visible and blink; bits 2–3 select block (0),
bar (1) or underline (2). Other cursor bits/styles are invalid. Appearance bits
0–1 indicate foreground/background; all other bits are invalid.

Runs are bounded to 8,000. Static schemas charge their logical keys,values,
strings and depth against the same receiver limits as ordinary v2 objects.
Negative or unsafe offsets,unrecognized colors and other unsupported values
retain the general encoding/fallback behavior. PTY root flags and raw output
bytes remain unchanged,so compact snapshots do not add overhead to PTY data.

## Browser ownership and backpressure

The parser accepts split headers,bodies and coalesced records. It borrows a
complete contiguous frame only while decoding and allocates an exact body for
fragmented input. Closing a source cancels its single owned fetch;callbacks
cannot keep dispatching after close.

The PTY consumer explicitly opts into raw output bytes. That opt-in copies the
exact payload into owned storage,so a slow xterm queue cannot retain an entire
network chunk. Default decoding and JSON/SSE fallback keep string data. Queue
limits and the rule that only a fully rendered offset is resumable are shared
by both paths. No keyboard input is replayed by this output transport.

Before a source delivers its first event,an unsupported or malformed format
can retry v3 → v2 → SSE on the same selected identity. Temporary HTTP 503 or a
transport failure keeps the negotiated format. First original-screen opening
allows at least 10 seconds,independently of its faster established-source
watchdog and bounded fallback GETs.

A disconnected PTY resumes output only after all accepted bytes are rendered.
Input stays disabled until the new source confirms its controls; old queued
frames cannot restore permission. Read retries back off from 0/250/500ms to
5 seconds. An in-flight or queued input,changed identity,nonretryable failure
or permanent status stops automatic recovery. Pending input is never replayed.
Intentional bounded renderer backpressure retains the existing writer controls
so Ctrl C can stop an output flood while the renderer drains.

## Reproduction

From the checkout root,build the matching release Core,then run:

```sh
node scripts/terminal-wire-check.mjs --build=.build/release
node scripts/terminal-wire-check.mjs --v3 --build=.build/release
node scripts/peer-stream-buffer-check.mjs --build=.build/release
node scripts/terminal-wire-transport-check.mjs --build=.build/release
node scripts/terminal-wire-browser-check.mjs --vectors=PATH_TO_V3_EMIT_STDOUT
```

`--source-root`,`--cache` and `--output` accept alternate directories. Output
must be a new directory. The fixture creates synthetic data only. Release
optimization can omit externally callable internal encoder symbols,so the
check compiles the exact encoder source without edits. The terminal DTO,
patch/copy and gzip implementations are linked from the matching Core objects.

The v3 check emits paired v2/v3 vectors from the same values and compares actual
Core gzip streams. It includes all 2,187 optional-boolean combinations,cursor
flags,colors,large offsets,logical limits and reserved-schema rejection.
The browser check uses those synthetic vectors with the current rendered UI,
real xterm completion and controlled loopback failures. Its seven-sample
receiver medians exclude painting,whole-app CPU and physical-network latency.
`--webkit` selects WebKit; Chromium is the default. Set the existing
`AUTOAPPROVE_PLAYWRIGHT_MODULE`/`AUTOAPPROVE_CHROMIUM_PATH` environment variables
when the browser installation is external to this checkout.

The Node VM check covers full values,default/raw decoding,all representative
splits,malformed/unsafe integers,EOF/cancellation,ordinary object properties,
legacy SSE parsing and actual PTY queue/offset logic. Actual HTTP transport,
real-browser rendering,physical devices and whole-app performance are separate
validation scopes.
