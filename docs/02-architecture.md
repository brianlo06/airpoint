# 3. Recommended Architecture

```
 ┌────────────────────────────── PHONE ──────────────────────────────┐
 │  Controller UI (PWA today, native SwiftUI later)                  │
 │                                                                   │
 │  ┌───────────┐   100 Hz   ┌──────────────────────────┐            │
 │  │  Sensors  │──samples──▶│  Motion Pipeline         │            │
 │  │ gyro/acc/ │            │  attitude → pointing vec │            │
 │  │ orientation│           │  → Δyaw/Δpitch → filter  │            │
 │  └───────────┘            │  → deadzone → gain/accel │            │
 │                           │  → clamp  ⇒ (dx,dy) px   │            │
 │  ┌───────────┐            └────────────┬─────────────┘            │
 │  │ Touch UI  │  taps/swipes/keys       │ 60 Hz coalesced          │
 │  │ 4 modes   │────────────┐            │                          │
 │  └───────────┘            ▼            ▼                          │
 │                     ┌───────────────────────────┐                 │
 │                     │  Session Client           │                 │
 │                     │  seq, ping/pong, backoff  │                 │
 │                     └────────────┬──────────────┘                 │
 └──────────────────────────────────┼────────────────────────────────┘
                                    │  WSS (TLS 1.3, pinned SPKI)
                                    │  JSON envelopes, one port
 ┌──────────────────────────────────┼────────────────────────────────┐
 │                    MAC ──────────▼───────────                     │
 │  ┌─────────────────────────────────────────────────────────────┐  │
 │  │ Listener (NWListener + TLS identity, LAN interfaces only)   │  │
 │  │   ├─ HTTP/1.1 static server  → serves the controller PWA    │  │
 │  │   └─ RFC 6455 upgrade        → WebSocket sessions           │  │
 │  │      Origin + Host allowlist (DNS-rebinding defence)        │  │
 │  └───────────────┬─────────────────────────────────────────────┘  │
 │                  ▼                                                │
 │  ┌──────────────────────────┐   ┌──────────────────────────────┐  │
 │  │ Pairing / Auth           │   │ Session Manager              │  │
 │  │ code+QR, HMAC challenge, │──▶│ 1 active pointer session,    │  │
 │  │ human approval, Keychain │   │ rate limits, expiry, revoke  │  │
 │  └──────────────────────────┘   └──────────────┬───────────────┘  │
 │                                                ▼                  │
 │                                 ┌──────────────────────────────┐  │
 │                                 │ Validation (RemoteKit)       │  │
 │                                 │ schema, ranges, key allowlist│  │
 │                                 └──────────────┬───────────────┘  │
 │                                                ▼                  │
 │                                 ┌──────────────────────────────┐  │
 │                                 │ Input Executor               │  │
 │                                 │ CGEvent mouse/scroll/keys,   │  │
 │                                 │ NSEvent media keys,          │  │
 │                                 │ multi-display clamping       │  │
 │                                 └──────────────┬───────────────┘  │
 │                                                ▼                  │
 │                                        macOS HID event tap        │
 │                                     (requires Accessibility)      │
 │                                                                   │
 │  ┌─────────────────────────────────────────────────────────────┐  │
 │  │ Menu-bar UI (Phase 4): QR, pair approval, connected device,  │ │
 │  │ PANIC DISCONNECT, permission wizard, troubleshooting         │  │
 │  └─────────────────────────────────────────────────────────────┘  │
 └───────────────────────────────────────────────────────────────────┘
```

## Component responsibilities

**Mobile controller** — owns *all* motion maths and all user-facing tuning. Emits pixel deltas,
never raw sensor samples. Owns mode state (Pointer/Media/Keyboard/Browser) and haptics.

**Desktop companion** — deliberately dumb about motion. It authenticates, validates, rate-limits,
and executes. It never trusts a number it did not bound-check.

**Local server** — one `NWListener` on one port, TLS-wrapped, serving both static HTTP and
WebSocket. Bound to LAN interfaces; advertises `_airpoint._tcp` via Bonjour.

**Pairing flow** — see `docs/04-security.md`.

**Motion pipeline** — see `docs/05-motion.md`.

**Input execution layer** — the only code that touches `CGEvent`. Isolated so it can be swapped
for a Windows/`SendInput` backend later behind the same `InputExecutor` protocol.

**Communication protocol** — see `docs/03-protocol.md`.

## Why the motion maths lives on the phone
1. The filter needs the full 100 Hz stream; sending it over the network triples bandwidth and
   puts filter state behind a jittery link, which is exactly what a low-pass filter hates.
2. Sensitivity and acceleration are *phone-side settings* with phone-side UI. Keeping the model
   next to the UI avoids a settings-sync protocol.
3. Deltas are loss-tolerant. A lost packet costs a few pixels of travel and self-corrects; an
   absolute-coordinate protocol would need resync logic.
4. The Mac stays a thin, auditable trust boundary: fewer lines of code between the network and
   `CGEvent` means a smaller attack surface.

---

# 4. Technology Recommendations

| Layer | Choice | Why this and not the alternative |
|---|---|---|
| Shared logic | **One Swift package, `RemoteKit`** | Protocol codecs, validation, motion maths and rate limiting are used by the Mac daemon today and the native iOS app in Phase 6. Writing them once in Swift means the iOS client cannot drift out of protocol sync with the server. This is the biggest structural win available and it is why the whole project is Swift rather than Node/TypeScript. |
| Mac transport | **`Network.framework` (`NWListener`/`NWConnection`) + hand-rolled HTTP/1.1 & RFC 6455** | Zero dependencies, native TLS, native Bonjour, and — critically — full access to the upgrade request headers so we can enforce `Origin`/`Host` allowlists. Apple's `NWProtocolWebSocket` server option would hide those headers and could not also serve static HTTP on the same port, which Safari's certificate-exception model requires. The framing code is ~250 lines and fully tested. |
| Mac input | **Core Graphics `CGEvent`** posted to `.cghidEventTap` | The public, supported way to synthesise input. `CGWarpMouseCursorPosition` moves the pointer without generating events (breaks hover/drag) and imposes an association delay; `CGEvent` with `mouseEventDeltaX/Y` set works with apps that read deltas. |
| Mac media keys | **`NSEvent` `.systemDefined` subtype 8 → `CGEvent`** | Produces genuine `NX_KEYTYPE_*` events, so the OS volume HUD appears and the frontmost media app responds — identical to pressing the physical key. |
| Mac UI (Phase 4) | **SwiftUI `MenuBarExtra`** | A menu-bar agent (`LSUIElement`) is the correct shape: always available, no Dock icon, one click to the panic button. |
| Serialization | **JSON over WebSocket text frames** | At 60 Hz × ~90 bytes that is 5.4 KB/s — nothing. Human-readable frames make the protocol debuggable with `websocat` and testable without a phone. A binary `pointer_move` frame is specified as an optional Phase 7 optimisation, not a v1 requirement. |
| Crypto | **CryptoKit** (`HMAC<SHA256>`, `Curve25519.Signing`, `SymmetricKey`) | In-OS, audited, no dependency. |
| Credential storage | **Keychain** (`kSecClassGenericPassword`, `WhenUnlockedThisDeviceOnly`) | Trusted-device public keys must not sit in a world-readable plist. |
| Cert generation | **`/usr/bin/openssl` via a temp config file** | Ships with macOS (LibreSSL 3.3). Generating a self-signed cert with correct SANs in pure `Security.framework` means hand-rolling ASN.1; shelling out to a first-party binary once at first run is the honest trade. |
| Phone (now) | **Vanilla PWA: HTML + CSS + ES modules, no framework** | The controller is ~12 controls and a render loop. React/Vue would add a build step, a bundle, and frame-scheduling indirection to something that must hit a 16 ms budget. No `package.json` at all — the Mac serves three static files. |
| Phone (later) | **Native SwiftUI + CoreMotion** | Buys out the TLS interstitial, the permission prompt, background suspension, and gives `CMDeviceMotion`'s fused attitude and CoreHaptics. |

## Platform strategy — the honest comparison

| | Mobile web / PWA | Native iOS | React Native / Flutter |
|---|---|---|---|
| Sensor access | Gated on HTTPS **and** a user gesture; iOS gives ~60 Hz `deviceorientation`, no bias-corrected quaternion | `CMDeviceMotion` at 100 Hz, fused, bias-corrected, free | Bridges to CoreMotion; RN's JS bridge adds jitter unless you use JSI/Reanimated worklets |
| Install friction | **Zero** — scan QR, open URL | App Store review, or a $99/yr account for sideloading | Same as native, plus a toolchain |
| Latency | Good (~10–20 ms sensor→socket) | Best | Good–poor depending on bridge discipline |
| Android | Works today | No | Yes |
| Screen-lock / call handling | Poor (page suspends) | Good | Good |
| Dev cost | Lowest | Medium, but shares `RemoteKit` | Highest — a second language and no code sharing with the Mac app |

**Recommendation**
- *Fast proof of concept*: **PWA.** Zero install, testable in a browser on the Mac itself.
- *Reliable MVP*: **PWA, with the TLS trust step properly designed** (QR carries the exact URL, the
  interstitial is explained in-app with a screenshot). Ship this. It is genuinely good enough,
  and it covers Android for free.
- *Polished product*: **Native iOS (SwiftUI + CoreMotion), sharing `RemoteKit` with the Mac.**
  Keep the PWA forever as the Android client and the zero-install fallback.

**Rejected: React Native / Flutter.** It is the worst of both worlds here — it does not remove the
native-install friction, and it forfeits the one large architectural advantage available to this
project, which is sharing the protocol and motion code with the Mac in a single language.
