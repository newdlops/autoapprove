# Terminal wire version 2

This is the output transport for existing terminal snapshots and managed PTYs.
Input requests,source identity checks,permissions and committed PTY offsets use
their existing APIs. The transport does not create a terminal session.

## Negotiation and compatibility

The dashboard and the owning Mac must both advertise `terminalWireVersion: 2`
before the browser requests `wire=2`. The response media type is
`application/vnd.autoapprove.terminal-v2`. Without negotiation,the server retains
`text/event-stream` and the browser retains native `EventSource`. A negotiated
fetch also accepts an SSE response. Existing gzip streaming remains per
connection,with an incremental flush after each logical event.

## Envelope

Each record is `41 41 02`,one mode byte,a canonical unsigned base-128 varint
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
five bytes `41 41 02 04 00`.

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

## Reproduction

From the checkout root,build the matching release Core,then run:

```sh
node scripts/terminal-wire-check.mjs --build=.build/release
```

`--source-root`,`--cache` and `--output` accept alternate directories. Output
must be a new directory. The fixture creates synthetic data only. Release
optimization can omit externally callable internal encoder symbols,so the
check compiles the exact encoder source without edits. The terminal DTO,
patch/copy and gzip implementations are linked from the matching Core objects.

The Node VM check covers full values,default/raw decoding,all representative
splits,malformed/unsafe integers,EOF/cancellation,ordinary object properties,
legacy SSE parsing and actual PTY queue/offset logic. Actual HTTP transport,
real-browser rendering,physical devices and whole-app performance are separate
validation scopes.
