# 7. Repository Structure

A single Swift package, because `RemoteKit` must be consumable by the macOS daemon today and an
iOS app later without a second build system. `swift build && swift test` is the whole toolchain.

```
airpoint/
├── Package.swift                 # one package, 3 targets
├── README.md                     # setup, permissions, run, test, troubleshoot
├── CHECKLIST.md                  # running done/remaining list
├── docs/
│   ├── 01-product-and-feasibility.md
│   ├── 02-architecture.md
│   ├── 03-protocol.md
│   ├── 04-security.md
│   ├── 05-motion.md
│   └── 06-plan-and-testing.md
├── Sources/
│   ├── RemoteKit/                # PLATFORM-AGNOSTIC. Shared with iOS in Phase 6.
│   │   ├── Protocol/
│   │   │   ├── Envelope.swift          # versioned envelope, seq, ts
│   │   │   ├── Events.swift            # every payload type, Codable
│   │   │   ├── KeyName.swift           # the key ALLOWLIST (no raw keycodes on the wire)
│   │   │   └── Validation.swift        # clamp/reject rules + ProtocolError
│   │   ├── Motion/
│   │   │   ├── Quaternion.swift        # minimal quat/vector maths
│   │   │   ├── MotionFilter.swift      # protocol + OneEuro + Exponential
│   │   │   └── PointerPipeline.swift   # the algorithm in docs/05, pure & testable
│   │   └── Security/
│   │       ├── PairingCode.swift       # code gen, HMAC proof, constant-time compare
│   │       └── RateLimiter.swift       # per-type token buckets
│   ├── airpointd/                # macOS daemon (Phase 1–3). Becomes the menu-bar app's core.
│   │   ├── main.swift            # CLI entry, config, signal handling
│   │   ├── Support/
│   │   │   ├── Config.swift            # env vars + CLI flags, no hard-coded addresses
│   │   │   ├── Log.swift               # levelled, secret-redacting logger
│   │   │   └── NetworkInterfaces.swift # enumerate private-IP interfaces
│   │   ├── Server/
│   │   │   ├── TLSIdentity.swift       # self-signed cert generation + SPKI fingerprint
│   │   │   ├── HTTPServer.swift        # NWListener, static files, upgrade routing
│   │   │   ├── WebSocketCodec.swift    # RFC 6455 framing
│   │   │   └── Session.swift           # per-connection state machine
│   │   ├── Pairing/
│   │   │   ├── PairingService.swift    # code lifecycle, approval, lockout
│   │   │   └── TrustStore.swift        # Keychain-backed trusted devices
│   │   ├── Input/
│   │   │   ├── InputExecutor.swift     # protocol (Windows backend slots in here)
│   │   │   ├── CGEventExecutor.swift   # the ONLY file that touches CGEvent
│   │   │   ├── DisplayGeometry.swift   # multi-monitor clamping
│   │   │   └── MediaKeys.swift         # NX_KEYTYPE_* via NSEvent
│   │   └── Resources/web/        # the PWA, served over TLS by HTTPServer
│   │       ├── index.html
│   │       ├── app.css
│   │       ├── motion.js         # ports PointerPipeline to JS (mirrored by tests)
│   │       └── app.js            # UI, modes, transport
│   └── airpoint-mac/             # Phase 4: SwiftUI MenuBarExtra wrapper (not yet)
└── Tests/RemoteKitTests/
    ├── EnvelopeTests.swift
    ├── ValidationTests.swift
    ├── QuaternionTests.swift
    ├── FilterTests.swift
    ├── PointerPipelineTests.swift
    └── RateLimiterTests.swift
```

---

# 8. Phased Implementation Plan

Each phase ends with something you can *run and judge*, not just compile.

| Phase | Deliverable | Testable result |
|---|---|---|
| **1. Cursor control core** ✅ | `RemoteKit` protocol + motion + `CGEventExecutor` + unit tests | `swift test` green; `airpointd --selftest` draws a square with the real cursor. Proves the Accessibility permission path. |
| **2. Transport + PWA** ✅ | TLS listener, HTTP static server, RFC 6455 WebSocket, pairing code, the PWA | Open the URL on a laptop browser, drag on the pad → the Mac cursor moves. No phone needed yet. |
| **3. Motion on a real phone** ✅ | `motion.js` pipeline, calibration, clutch, sensitivity | Point the phone at the TV; cursor tracks. Measure sensor→pixel latency with the built-in HUD. |
| **4. Menu-bar app + pairing UX** | SwiftUI `MenuBarExtra`, QR rendering, approve/deny sheet, panic disconnect, permission wizard, trusted devices | A non-technical person can go from download to controlling YouTube without a terminal. |
| **5. Full control surface** | Media/Keyboard/Browser modes, per-site keymaps, haptics, right-click, drag | Drive Netflix, YouTube, Spotify Web end-to-end from the couch. |
| **6. Native iOS client** | SwiftUI + CoreMotion app sharing `RemoteKit`; Bonjour discovery | No TLS interstitial, no permission prompt, 100 Hz fused attitude, works with the screen dimmed. |
| **7. Hardening + packaging** | Signed/notarised `.app`, Sparkle updates, `launchd` login item, crash-free 8 h soak, PAKE pairing, binary pointer frames | Ship it. |

Phases 1–3 are implemented in this repo now. Phase 4 onward is planned, not built —
see `CHECKLIST.md` for the exact line.

---

# 9. Testing Strategy

## Unit (`swift test`, runs in CI, no hardware)
- **Protocol**: round-trip every event type; reject `v≠1`; unknown `t`; missing `d`; wrong field
  types; oversized text; non-finite doubles; `seq` regression.
- **Validation**: every clamp boundary (±400 px, ±2000 scroll, 1–10 repeat, 1–1024 chars);
  control-character stripping; key allowlist rejects `"; rm -rf"` and unknown names.
- **Quaternion**: `q ⊗ conj(q) = identity`; rotating p̂ by a known 30° yaw yields yaw = 30°;
  **roll invariance** — rolling the phone 90° about its pointing axis must produce zero cursor
  motion (this is the regression test for portrait/landscape).
- **Filters**: One-Euro converges to a step input; output variance on synthetic 0.5°-RMS tremor is
  < 25% of input variance; phase lag on a 1 Hz sweep < 30 ms.
- **Pipeline**: a 250 ms sensor gap emits zero motion (no teleport); dead zone suppresses a
  0.05°/frame drift indefinitely; acceleration curve is monotonic; velocity clamp holds at 4000 px/s.
- **RateLimiter**: bucket refills at the right rate; burst allowance; no integer overflow at t=∞.

## Integration (scripted, no phone)
- `websocat` fixture replaying a recorded session; assert cursor path with `CGEventTap` capture.
- Fuzz: 10⁵ random/mutated JSON frames at the session state machine — must never crash, never
  execute input, and always end in a defined close code.
- Pairing: wrong code ×5 ⇒ lockout; expired code; replayed `hello` proof (nonce reuse) rejected.
- Origin/Host: connect with `Origin: https://evil.example` ⇒ upgrade refused; `Host: attacker.com`
  ⇒ refused (DNS-rebinding regression test).

## Device / manual matrix
| Axis | Cases |
|---|---|
| Phones | iPhone (Safari), iPhone (Chrome), Android (Chrome), Android (Firefox) |
| Orientation | portrait, landscape-left, landscape-right, face-up transitions |
| Displays | single, dual with different scale factors, mirrored, laptop-lid-closed |
| Sites | YouTube, Netflix, Disney+, Max, Prime Video, Hulu, Spotify Web — windowed and fullscreen |
| Network | 5 GHz, 2.4 GHz, phone on guest VLAN (expect failure + clear error), Wi-Fi drop mid-session |
| Interruptions | incoming call, screen lock, app switch, low-power mode, 30 min idle |

## Measurable success criteria
| Metric | Target | How measured |
|---|---|---|
| End-to-end input latency (finger motion → pixel) | **< 50 ms p95**, < 80 ms p99 | 240 fps video of phone + screen, frame counting; plus in-app `ping` RTT HUD |
| Protocol RTT on 5 GHz LAN | < 12 ms p95 | `ping`/`pong` histogram in the daemon log |
| Cursor drift at rest | **< 2 px over 60 s**, phone stationary, clutch held | Automated: log cursor position for 60 s |
| Jitter at rest | < 1 px RMS | Same capture |
| Pointing accuracy | hit a 60 px target at 3 m in < 1.5 s, 9/10 trials | Manual Fitts-style task |
| Reconnect after Wi-Fi drop | **< 3 s** to usable | Toggle airplane mode, stopwatch |
| Packet loss tolerance | 5% loss ⇒ no perceptible change; 20% ⇒ still usable | `dnctl`/`pfctl` loss injection |
| Idle bandwidth | < 200 B/s | `nettop` |
| Active bandwidth | < 8 KB/s | `nettop` |
| Soak | 8 h session, no leak (< 5 MB RSS growth), no stuck modifier | Instruments + assert |
| Fuzz | 0 crashes / 10⁵ hostile frames | CI |

---

# Edge Cases and Their Handling

| Case | Handling |
|---|---|
| Phone and Mac on different networks / guest VLAN | Connection times out; the PWA shows "Can't reach your Mac — check both are on the same Wi-Fi network (not Guest)". Mac panel lists the exact URLs it is reachable on. |
| Local IP changes (DHCP, network switch) | `NWPathMonitor` detects it, the cert is regenerated with the new SAN set, the QR updates live, and the daemon logs the change. Trusted devices reconnect via `<hostname>.local`, which is IP-independent. |
| macOS firewall prompt | First run explains it before it appears and tells the user to click "Allow". The daemon detects a bind failure and surfaces the firewall as the likely cause. |
| Accessibility permission denied | `AXIsProcessTrusted()` polled; UI shows a blocking wizard with a deep link to the right Settings pane; input events return `permission_denied` to the phone rather than silently no-op'ing. |
| Phone orientation change | No special case needed — roll compensation (§③) makes the pipeline orientation-agnostic. The CSS layout reflows; the pointer pad stays under the thumb. |
| Sensor drift | Dead zone + stationary bias estimator + recenter. |
| Wi-Fi interruption | Exponential backoff reconnect (0.25 s → 4 s), session resumed by id if within 30 s, otherwise re-auth silently with the trusted-device key. Cursor freezes; it never lurches on reconnect (delta history is reseeded). |
| High latency (> 150 ms) | The HUD turns amber; motion gain is *reduced* automatically, because high gain plus lag causes overshoot oscillation. |
| Multiple phones connect | Second device gets `pair_pending`; the Mac asks the human whether to hand over. Only one pointer session is ever active. |
| Phone screen locks | Page suspends; `visibilitychange` freezes the pointer and marks the session idle. Wake lock requested while the clutch is held. On resume, delta history is reseeded (no teleport). |
| Browser suspends background activity | Same path as above; `pong` timeout closes the session cleanly rather than leaving a zombie. |
| Incoming call | Sensors stop; the > 250 ms gap guard discards the accumulated delta. Returning to the page auto-recenters. |
| Cursor at screen edge | Clamped to the union of display rects, projected to the nearest rect when the union is non-rectangular, so the cursor can never land in a "hole" between displays. |
| Multiple monitors | Single global coordinate space; the active display is the one containing the cursor; `recenter{toCenter}` centres on *that* display, not always the main one. |
| Fullscreen browser apps | Nothing special — we post OS-level events, so fullscreen is irrelevant. Fullscreen *entry* is site-specific and handled by the per-site keymap. |
| Accidental clicks from movement | Clicks require a touch that moved < 12 px and lasted < 350 ms; motion during the press does not cancel it, but a *drag* on the pad is a scroll, not a click. |
| Quickly pausing motion control | Release the clutch. That is the whole gesture. |
| Stuck mouse button | Drag auto-ends after 30 s, on disconnect, on session loss, and on panic. All modifiers are released on every session teardown. |
