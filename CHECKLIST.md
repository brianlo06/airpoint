# AirPoint — running checklist

Last updated: 2026-08-29.
Anything marked **done** has been built *and* exercised, either by `swift test` or by
`tools/probe.mjs` against a live daemon. Nothing is ticked on the strength of it compiling.

---

## Phase 1 — Cursor control core — **done**

- [x] `RemoteKit`: versioned envelope, 14 client event types, 6 server types
- [x] Validation with clamp-vs-reject rules per field
- [x] Key allowlist (`KeyName`), no raw keycodes on the wire
- [x] Quaternion maths with roll compensation
- [x] One-Euro and exponential filters behind a `MotionFilter` protocol
- [x] `PointerPipeline`: dead zone, bias estimator, acceleration, velocity clamp, clutch
- [x] Token-bucket rate limiting, per event type
- [x] Pairing crypto: 128-bit secret, derived 6-digit code, HMAC proof, constant-time compare
- [x] `CGEventExecutor`: move, click, drag, scroll, keys, Unicode text, media keys
- [x] Multi-display clamping that projects to the nearest screen instead of the bounding box
- [x] `--selftest` draws a square with the real cursor and reports the permission state
- [x] 84 unit tests, green

## Phase 2 — Transport + PWA — **done**

- [x] Self-signed TLS identity, SANs covering every live LAN address + `<host>.local`
- [x] Certificate regenerated when the address set changes
- [x] Private-key usability probe with timeout, and self-healing regeneration
- [x] Hand-rolled HTTP/1.1 static server + RFC 6455 WebSocket on **one** port
- [x] `Origin` and `Host` allowlists (cross-origin + DNS-rebinding defence) — verified live
- [x] CSP, `Permissions-Policy`, `nosniff`, `no-referrer` on every response
- [x] Static assets from a fixed allowlist (no path arithmetic, so no traversal)
- [x] Session state machine: auth deadline, idle timeout, session lifetime, one pointer owner
- [x] Pairing flow with terminal approval, single-use codes, lockout — verified live
- [x] Graceful close that flushes the reason before cancelling the socket
- [x] Bonjour advertisement (`_airpoint._tcp`)
- [x] `tools/probe.mjs`: 19 protocol assertions, green

## Phase 3 — Motion on a real phone — **done (code complete, needs a device)**

- [x] `motion.js` port of the Swift pipeline
- [x] Calibration that measures the device's noise floor and sizes the dead zone to it
- [x] Clutch, tap-to-click, two-finger right click, hold-to-drag, drag-to-scroll
- [x] Sensitivity slider, persisted
- [x] Latency HUD; gain backs off automatically above 150 ms
- [x] Four modes: Pointer, Media, Keyboard, Browser
- [x] Suspension, orientation-change and touch-cancel handling
- [ ] **Not yet done: run on a physical phone.** Everything above is written and the desktop
      mouse fallback path works, but no real gyroscope has driven it yet. This is the next
      thing to do and may well shake out tuning changes.

---

## Phase 4 — Menu-bar app and pairing UX — not started

- [ ] SwiftUI `MenuBarExtra` agent (`LSUIElement`), replacing the terminal
- [ ] On-screen QR and code, live countdown, one-tap regenerate
- [ ] Approve/Deny/Approve-and-trust sheet replacing `ConsoleApprover`
- [ ] Connected-device indicator that changes *shape*, not just colour
- [ ] Panic disconnect: menu item + global hotkey
- [ ] First-run permission wizard with a deep link to the Accessibility pane
- [ ] Trusted-device list with per-device revoke and "forget all"
- [ ] Troubleshooting panel (addresses, firewall state, permission state, last errors)
- [ ] Switch to `--keychain` once the app has a stable signed code identity

## Phase 5 — Full control surface — not started

- [ ] Per-site keymap profiles (YouTube / Netflix / Disney+ / Prime / Spotify)
- [ ] Accurate seek intervals per site, replacing the 5-second-per-press approximation
- [ ] CoreHaptics-quality feedback (currently `navigator.vibrate`, ignored by iOS Safari)
- [ ] Momentum scrolling with proper phase flags
- [ ] Text field with live incremental send instead of tap-to-send

## Phase 6 — Native iOS client — not started

- [ ] SwiftUI app consuming `RemoteKit` directly
- [ ] `CMDeviceMotion` at 100 Hz (`xArbitraryZVertical`, no magnetometer)
- [ ] Bonjour discovery, no typing an IP
- [ ] Certificate pinning against the QR fingerprint (removes threat T3 for real)
- [ ] Ed25519 device key + `resume` reconnect without re-approval
- [ ] Works with the screen dimmed; survives calls and app switches

## Phase 7 — Hardening and packaging — not started

- [ ] Signed and notarised `.app`, `launchd` login item, Sparkle updates
- [ ] PAKE (SPAKE2/CPace) pairing so the 6-digit code resists offline attack
- [ ] Binary `pointer_move` opcode behind the `features` list
- [ ] 8-hour soak test; assert < 5 MB RSS growth and no stuck modifiers
- [ ] Fuzz harness: 10⁵ mutated frames, 0 crashes
- [ ] Packet-loss injection tests (`dnctl`/`pfctl`) at 5% and 20%
- [ ] Latency measurement rig: 240 fps video, phone + screen in frame

---

## Known gaps and honest caveats

1. **No physical-device testing yet.** The motion pipeline is unit-tested against synthetic
   attitude data and the protocol is verified against a live daemon, but the feel of the
   thing is unproven. Expect the gain, acceleration and dead-zone defaults to move.
2. **Secrets are in 0600 files, not the Keychain, by default.** The Keychain binds an item's
   ACL to the exact binary, so an unsigned CLI gets a modal approval prompt on every rebuild
   — which a background daemon cannot answer, and which hangs startup. `--keychain` exists
   for the signed app in Phase 4. See `SecretStore.swift` for the full reasoning.
3. **Certificate trust is a real UX tax.** The browser interstitial is unavoidable on the web
   path and is the strongest argument for the native iOS client.
4. **The typed-code path has no certificate pinning**, so it does not defend against an
   active MITM (threat T3) the way the QR path does. The UI says so.
5. **Ed25519 "remember this device" is implemented server-side but the PWA does not yet
   generate a key**, because WebCrypto Ed25519 support is uneven. The server logs a warning
   and declines to trust rather than pretending. Native client (Phase 6) closes this.
6. **Seek intervals are approximated** at 5 seconds per arrow press. Correct per-site values
   are Phase 5.
7. **`scroll` momentum is accepted and validated but not yet mapped** to macOS continuous
   scroll phases.
8. **No CI yet.** `swift test` and `tools/dev.sh` run locally; nothing runs them on push.

## Fixed during Phase 1–3 (recorded because each was a real defect, not a typo)

- Dead-zone knee was set ~9× too high, silently costing a third of the gain on every normal
  pointing sweep. Now regression-tested.
- Rate limiter checked the global bucket first, so a pointer flood could starve clicking.
- Well-formed-but-invalid frames counted toward the "malformed JSON" budget, disconnecting
  clients with minor bugs after three mistakes.
- Rejected frames bypassed the rate limiter entirely — an unbounded free flood.
- The server replied to *every* rate-limited frame, amplifying a flood into an equal flood
  of errors.
- `connection.cancel()` discarded queued sends, so clients got a bare TCP reset (1006)
  instead of the error explaining why they were disconnected.
- `NWListener(using:on:)` plus `requiredLocalEndpoint` fails with EINVAL; the port must
  travel in only one of them.
- A reused PKCS#12 identity could hang the TLS handshake forever with no error surfaced.
