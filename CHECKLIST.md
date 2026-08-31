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
- [x] **Run on a physical phone.** Done: an iPhone drove 27,383 px of cursor travel over a
      45-second session at 30–50 frames/s. Pointing works.
- [x] Gyro-rate pointing path, after device testing showed yaw (magnetometer-derived) was
      markedly worse than pitch
- [x] Gyro axis convention resolved from physics; confirmed working on a real iPhone
- [x] Dedicated click/right-click triggers off the pad, so clicking does not break the aim
- [x] Dedicated scroll strip with flick momentum, off the pad for the same reason
- [ ] Tune gain/acceleration against a real hand — current values are still synthetic
- [ ] Smoothness pass: measure frame-rate variance on device (observed 27–50 Hz, want steady 60)

---

## Library extraction — **done**

- [x] `RemoteServer` split out as a published library product
- [x] `RemoteSessionHandler` seam: the session layer no longer knows what an event means
- [x] `ServerConfig` with `maxConcurrentSessions`, replacing the hardcoded single-pointer rule
- [x] `StaticContent` so a host serves its own controller assets
- [x] `permissions` in `welcome` is host-supplied rather than hardcoded to `accessibility`
- [x] AirPoint rebuilt on the seam as `PointerHandler`; all 111 tests and 19 protocol
      assertions still pass, and `Origin`/`Host` policy still verified live

## Found by building a second project on the library

Both were invisible from inside AirPoint and appeared within minutes of a second host
existing, which is the argument for doing the extraction rather than planning it.

- `PairingService` held its approver **weakly**. A caller constructing one inline saw it
  deallocated at once, and every pairing was then refused with "no approval interface
  available" — indistinguishable from a wrong code. AirPoint never hit it only because its
  approver happened to be a top-level `let`. Now held strongly, and the nil case logs.
- `sessionDidEnd` fired for connections that never became sessions, so every plain HTTPS
  request for a static file looked to the host like a player joining and leaving. Guarded on
  whether the session was ever announced.

## Phase 4 — Menu-bar app and pairing UX — **mostly done**

- [x] SwiftUI `MenuBarExtra` agent (accessory activation policy, no Dock icon)
- [x] On-screen QR and code, live countdown, one-click regenerate
- [x] Approve / Allow once / Allow and remember sheet, replacing `ConsoleApprover`
- [x] Status icon that changes *shape*, not just colour
- [x] Panic disconnect, always visible while running rather than behind a submenu
- [x] Accessibility prompt with an explanation and a deep link, polled so the switch takes
      effect without a relaunch
- [x] Trusted-device list with per-device revoke and "forget all"
- [x] `AirPointCore` extracted so the CLI and the app are one program, not two
- [ ] Global hotkey for panic disconnect
- [ ] Troubleshooting panel (firewall state, last errors)
- [ ] Signing and notarisation, and `--keychain` once there is a stable code identity
- [ ] **The app has not been driven by a phone yet.** It starts, serves the controller,
      enforces the Host allowlist and routes a pairing request to the sheet, but no device
      has been approved through the UI.

## Phase 5 — Full control surface — not started

- [ ] Per-site keymap profiles (YouTube / Netflix / Disney+ / Prime / Spotify)
- [ ] Accurate seek intervals per site, replacing the 5-second-per-press approximation
- [ ] CoreHaptics-quality feedback (currently `navigator.vibrate`, ignored by iOS Safari)
- [ ] Map the `momentum` flag onto macOS continuous-scroll phases (the client sets it; the
      executor still treats momentum frames as ordinary scrolls)
- [x] Live incremental typing instead of tap-to-send, autocorrect- and emoji-safe
- [x] Keyboard prompt driven by the Mac's focused-element role
- [x] Floating Enter/Esc/Done bar pinned above the iOS keyboard via visualViewport
- [ ] Chrome and Electron do not expose web content to accessibility by default, so the
      keyboard prompt does not fire for text fields inside them. Setting `AXManualAccessibility`
      on those apps would fix it but turns on their full accessibility tree — a much broader
      action than this feature justifies, so it is documented rather than done.

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

1. **Tuning is still synthetic.** Pointing has now been driven by a real iPhone and works,
   but the gain, acceleration and dead-zone defaults were chosen against simulated data and
   have had exactly one round of feedback ("janky, sideways worse than vertical") applied.
   Expect them to move again. Frame delivery was 27–50 Hz rather than a steady 60; the
   cause of that variance has not been measured yet.
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
8. **CI runs on push** (`.github/workflows/ci.yml`): build, 111 unit tests, all three browser
   harnesses, and a real protocol session against a live TLS listener in `--dry-run`.
   What CI cannot cover is anything needing the Accessibility permission or a real phone.
9. **The controller has no unit tests of its own**, only the two Node harnesses in `tools/`.
   That gap let a dangling reference ship: every pipeline test passed while the wiring
   between sensors, resolver and pipeline was broken. `tools/sensor-flow-check.mjs` now
   covers that seam, but it mirrors `App._processSensorSample` by hand rather than importing
   it, so the two can still drift.

## Found by real-device testing

- Pairing codes expired mid-flow at 90 s; the first run cannot be completed that fast.
- Nothing ever raised the Accessibility prompt, so the binary had to be found by hand.
- A backgrounded Safari tab reconnects over WebSocket without reloading, so the phone ran a
  stale controller for three debugging rounds while looking healthy.
- iOS does not reliably carry a motion grant across page loads, and the "Enable motion"
  gate only appeared when the grant had *never* been given — leaving no way to recover.
- `DeviceMotionEvent` permission is separate from `DeviceOrientationEvent`; only the latter
  was being requested.
- The clutch was not discoverable. Tapping the pad is also a click, so clicking worked
  perfectly and only pointing seemed broken. Added an aim-lock toggle.
- "Motion is flowing" fired on 20 px of total travel — a creep no one can see. Telemetry now
  reports frames/s and mean px/frame.
- **Yaw was magnetometer-derived and visibly worse than pitch.** Switched to gyro rate.
- The velocity clamp bound on nearly every fast flick.
- **Aiming up/down moved the cursor left/right: iOS reports rotationRate under CoreMotion's
  axis convention, not the W3C one.** Found by logging the raw gravity vector and angular
  rate to the desktop and correlating them: gravity.y swung -0.26 -> -0.66 -> -0.27 (a real
  tilt) while the rotation appeared on the component the spec reserves for yaw. Two earlier
  hypotheses were ruled out by measurement first — the grip assumption (old and new
  horizontal references are identical for every no-roll grip) and a cursor read-back race
  (both executors pass the burst test identically). Fixed by deriving the axis mapping from
  `dg/dt = -(omega x g)` rather than assuming or sniffing it.

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
