# 5. Event Protocol — AirPoint Wire Protocol v1

Transport: WebSocket over TLS 1.2+, text frames, UTF-8 JSON. One message per frame.

## Envelope

```json
{ "v": 1, "t": "pointer_move", "seq": 1042, "ts": 1756500000123, "d": { "dx": 4.5, "dy": -1.25 } }
```

| Field | Type | Rules |
|---|---|---|
| `v` | int | Must equal `1`. Mismatch ⇒ `error{code:"unsupported_version"}` and close 1008. |
| `t` | string | Must be a known type. Unknown ⇒ `error{code:"unknown_type"}`, message dropped, session kept. |
| `seq` | uint32 | Monotonically increasing per connection. Wraps at 2³². Used for loss telemetry and replay rejection. |
| `ts` | int64 | Client monotonic-ish milliseconds. Never trusted for security, only for latency stats. |
| `d` | object | Type-specific payload. Absent ⇒ treated as `{}`. |

**Global limits.** Frame ≤ 8 KiB. Any frame ≥ 8 KiB ⇒ close 1009. Malformed JSON ⇒
`error{code:"bad_json"}`; **three consecutive** non-JSON frames ⇒ close 1002.

Rejected frames (bad JSON, unknown type, or failed validation) get a separate, more
generous budget: **twenty consecutive** rejections ⇒ close 1008. Two counters rather than
one, because the failure modes differ — a client that cannot emit JSON is broken, while a
client sending an unsupported key name has a minor bug and should be told what is wrong and
allowed to carry on. Both reset on any accepted frame.

Note that rejected frames never reach the rate limiter (they fail at decode, before it), so
this budget is what stops an unbounded flood of invalid frames costing the server nothing.

**Ordering.** Only `pointer_move` and `scroll` may be reordered/dropped. The server keeps
`lastAppliedSeq` and discards any `pointer_move` whose `seq` is more than 0 behind it — stale
deltas are worse than no deltas. All other types are applied in arrival order.

---

## Client → server

### `pointer_move`
```json
{"v":1,"t":"pointer_move","seq":1042,"ts":1756500000123,"d":{"dx":4.5,"dy":-1.25}}
```
`dx`,`dy`: finite doubles, pixels, already filtered and gain-applied by the client.
Validation: `|dx|,|dy| ≤ 400`. Out of range ⇒ **clamp**, do not reject (a clamp keeps the cursor
usable during a burst; a reject makes it stutter). Non-finite ⇒ drop message.
Rate limit: 150/s.

### `left_click` / `right_click`
```json
{"v":1,"t":"left_click","seq":1043,"ts":1756500000200,"d":{"clicks":1}}
```
`clicks`: 1 or 2 (double-click). Default 1. Rate limit: 20/s.

### `drag_start` / `drag_end`
```json
{"v":1,"t":"drag_start","seq":1044,"ts":1756500001000,"d":{"button":"left"}}
```
`button`: `"left"` | `"right"`. Server enforces a state machine: `drag_start` while already
dragging is a no-op; `drag_end` with no drag is a no-op. **Safety:** any drag is force-ended after
30 s, on session loss, or on `disconnect` — a stuck mouse-down is the worst failure mode this
app has. Rate limit: 10/s.

### `scroll`
```json
{"v":1,"t":"scroll","seq":1045,"ts":1756500001200,"d":{"dx":0,"dy":-32,"unit":"px","momentum":true}}
```
`unit`: `"px"` | `"line"`. `|dx|,|dy| ≤ 2000` (clamped). `momentum` marks inertial frames so the
server can flag them as continuous scroll phases. Rate limit: 150/s.

### `key_press`
```json
{"v":1,"t":"key_press","seq":1046,"ts":1756500002000,"d":{"key":"Return","mods":["cmd"],"repeat":1}}
```
`key` must be a member of the **server-side allowlist** (`KeyName` enum: letters, digits, arrows,
Return/Escape/Tab/Space/Backspace/Delete/Home/End/PageUp/PageDown, F1–F12, punctuation, and
`BrightnessUp/Down`). Arbitrary virtual keycodes are **never** accepted from the wire.
`mods` ⊆ {`cmd`,`shift`,`alt`,`ctrl`,`fn`}. `repeat`: 1–10. Rate limit: 40/s.

### `text_input`
```json
{"v":1,"t":"text_input","seq":1047,"ts":1756500003000,"d":{"text":"the bear season 3"}}
```
`text`: 1–1024 UTF-8 chars after stripping C0/C1 control characters except `\n` and `\t`.
Typed via `CGEvent.keyboardSetUnicodeString`, chunked at 20 UTF-16 units per event.
Rate limit: 20/s and 4000 chars/s.

### `media_command`
```json
{"v":1,"t":"media_command","seq":1048,"ts":1756500004000,"d":{"command":"seek_forward","amount":10}}
```
`command` ∈ `play_pause | next | previous | volume_up | volume_down | mute |
seek_forward | seek_back | fullscreen_toggle | fullscreen_exit`.
`amount`: optional, 1–600, seconds for seek commands, ignored otherwise. Rate limit: 20/s.

### `recenter`
```json
{"v":1,"t":"recenter","seq":1049,"ts":1756500005000,"d":{"toCenter":true}}
```
Client-side operation (it resets the client's reference attitude). Sent to the server only so the
server can optionally warp the cursor to the centre of the active display when `toCenter` is true,
and so the event appears in the session log. Rate limit: 5/s.

### `calibration`
```json
{"v":1,"t":"calibration","seq":1050,"ts":1756500006000,
 "d":{"stage":"complete","holdMs":1200,"biasRadS":[0.0011,-0.0004,0.0002],"noiseRadS":0.0009}}
```
`stage` ∈ `start | sampling | complete | failed`. Payload is diagnostic: the server records it for
the troubleshooting panel and does not act on it. `biasRadS`: 3 finite doubles, `|b| ≤ 0.5`.

### `ping`
```json
{"v":1,"t":"ping","seq":1051,"ts":1756500007000,"d":{"id":77}}
```
Server replies immediately with `pong`. Client sends every 2 s; a session with no client frame for
10 s is closed. Rate limit: 5/s.

### `disconnect`
```json
{"v":1,"t":"disconnect","seq":1052,"ts":1756500008000,"d":{"reason":"user_requested"}}
```
Server force-ends drags, releases modifiers, closes with 1000.

### `hello` (must be the first frame)
```json
{"v":1,"t":"hello","seq":0,"ts":1756500000000,
 "d":{"deviceId":"c1f0…","deviceName":"Brian's iPhone","platform":"ios-web",
      "clientVersion":"0.1.0","auth":{"mode":"code","code":"418302"}}}
```
`auth.mode` ∈ `code` (first pairing, QR or typed) | `resume` (trusted device: `{"sig": base64,
"nonce": base64}` signing the server nonce from `challenge`).
No `hello` within 5 s of connect ⇒ close 1008.

---

## Server → client

### `challenge` (sent immediately on connect, before `hello`)
```json
{"v":1,"t":"challenge","seq":1,"ts":1756500000000,"d":{"nonce":"9f3c…","serverVersion":"0.1.0"}}
```

### `welcome`
```json
{"v":1,"t":"welcome","seq":2,"ts":1756500000500,
 "d":{"sessionId":"s_8fc2…","expiresAt":1756503600000,
      "displays":[{"id":1,"w":2560,"h":1440,"scale":2,"main":true}],
      "features":["pointer","scroll","keyboard","media","drag"],
      "permissions":{"accessibility":true}}}
```

### `pair_pending`
```json
{"v":1,"t":"pair_pending","seq":3,"ts":1756500000600,"d":{"message":"Approve on your Mac","timeoutMs":60000}}
```

### `status`
```json
{"v":1,"t":"status","seq":9,"ts":1756500010000,
 "d":{"pointerEnabled":true,"accessibility":true,"activeDisplay":1,"dragging":false}}
```

### `pong`
```json
{"v":1,"t":"pong","seq":10,"ts":1756500007001,"d":{"id":77,"clientTs":1756500007000}}
```
Client RTT = `now − d.clientTs`. One-way estimate = RTT/2.

### `error`
```json
{"v":1,"t":"error","seq":11,"ts":1756500011000,
 "d":{"code":"rate_limited","message":"pointer_move exceeded 150/s","fatal":false,"retryAfterMs":500}}
```

| `code` | fatal | Meaning |
|---|---|---|
| `unsupported_version` | yes | `v` ≠ 1 |
| `bad_json` | no (3rd ⇒ yes) | Frame is not valid JSON |
| `unknown_type` | no | Unrecognised `t` |
| `invalid_payload` | no | Field missing, wrong type, or out of unclampable range |
| `unauthenticated` | yes | Any non-`hello`/`ping` frame before `welcome` |
| `pair_rejected` | yes | Human denied, or bad code |
| `pair_timeout` | yes | No human decision within 60 s |
| `too_many_attempts` | yes | 5 failed codes from one address ⇒ 15 min lockout |
| `session_expired` | yes | Past `expiresAt` |
| `session_replaced` | yes | Another device was granted the pointer |
| `rate_limited` | no | Token bucket empty; server drops, does not queue. **At most one notice per event type per second** — answering every dropped frame would amplify a flood into an equal flood of errors. |
| `permission_denied` | no | Accessibility not granted; input cannot be executed |

## Bandwidth and pacing
- Client emits `pointer_move` at **60 Hz maximum**, coalescing all sensor frames since the last
  send into one delta. Sensors run at 100 Hz; the filter sees every sample, the network sees 60/s.
- If a send would occur while the socket's `bufferedAmount > 32 KiB`, the frame is **skipped and
  its delta folded into the next one** — backpressure must never grow a queue, because a queued
  motion delta is a lie by the time it arrives.
- A frame with `dx == 0 && dy == 0` is not sent. A still phone costs 0.5 packets/s (ping only).
- Measured budget: 60 × 92 B ≈ 5.5 KB/s peak, ~0 idle.

## Future (not v1)
A binary `pointer_move` opcode — `0x01 | seq:u32 | dx:f16 | dy:f16` = 9 bytes — behind the
`features` list. Specified so it can be added without a version bump.
