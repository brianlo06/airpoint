# AirPoint

Turn a phone into a motion-controlled remote for a Mac. Point the phone at the screen and the
cursor follows; tap to click, swipe to scroll, switch modes for media, keyboard and browser
controls. Built for driving a laptop that is plugged into a TV, from the couch.

It controls the **real cursor and keyboard**, so it works with YouTube, Netflix, Disney+,
Spotify Web and everything else without extensions, injected scripts or per-site
integrations. Nothing here touches DRM, authentication or platform security — it provides
ordinary input to your own machine, exactly as a Bluetooth mouse would.

**Status:** Phases 1–3 are implemented and verified end to end. Phase 4 onward is designed
but not built — see `CHECKLIST.md` for the exact line between the two.

---

## Quick start

```bash
git clone <this repo> && cd airpoint
swift build

# Check the Accessibility permission end to end (draws a square with the real cursor)
./.build/debug/airpointd --selftest

# Run it
./.build/debug/airpointd
```

The daemon prints a URL, a six-digit pairing code and a scannable QR code. On your phone:

1. **Scan the QR code**, or open the printed `https://<your-mac-ip>:8443` and type the code.
2. Safari will warn that the certificate is untrusted. **This is expected.** AirPoint signs
   its own certificate because it runs on your machine, not on a public server. Tap
   *Show Details* → *visit this website*.
   TLS is not optional: `DeviceMotionEvent` is a secure-context API in both Safari and
   Chrome, so a controller served over plain HTTP could never read the gyroscope.
3. Tap **Enable motion** and allow the sensor prompt (iOS requires a user gesture for this).
4. **Approve the pairing request** in the terminal — `y` for this session, `t` to remember
   the device, anything else to deny.
5. Hold a finger on the pad and aim the phone.

### Permissions

| Permission | Why | What happens without it |
|---|---|---|
| **Accessibility** (System Settings ▸ Privacy & Security ▸ Accessibility) | Posting synthetic input with `CGEvent` requires it | The daemon still runs and pairs, but returns `permission_denied` to the phone and shows a warning at startup. It never silently no-ops. |
| **Local network** / firewall allow | Accepting LAN connections | macOS prompts on first launch; choose Allow. If the bind fails the daemon names the firewall as the likely cause. |

AirPoint requests **nothing else**. No screen recording, no microphone, no clipboard access,
no network egress, no telemetry.

---

## Gestures

| On the pointer pad | Does |
|---|---|
| Hold a finger down | Motion control on (a clutch — release to stop instantly) |
| Tap (< 350 ms, < 12 px) | Left click |
| Two-finger tap | Right click |
| Hold 500 ms | Begin drag; ends on lift |
| Drag a finger | Scroll (pointing suspends so the two do not fight) |

| Scroll strip, right of the pad | Does |
|---|---|
| Drag | Scroll, 4× your finger travel |
| Flick | Scroll with momentum, gliding to a stop |
| Touch during a glide | Stop dead |

| Trigger row, below the pad | Does |
|---|---|
| Tap **Click** | Left click — **while you keep aiming** |
| Hold **Click** | Drag, held until you release, with the pointer still live |
| Tap **Right** | Right click |
| **Aim: hold the pad** | A real toggle. Locked means the phone steers continuously with nothing held. |

Pointing comes from moving the *phone*, so finger travel on the pad is free to mean
"scroll" without ever conflicting with aiming. The clutch is the most important control
here: it makes drift, accidental movement, the phone-rings case and screen-lock all
non-problems, because motion is only live while your thumb is down.

The triggers and the scroll strip live **off** the pad for exactly that reason — lifting a
finger from the pad to tap is what stops the aim. One thumb holds the aim, the other clicks
or scrolls, and multi-touch keeps them independent.

---

## Development

```bash
./tools/dev.sh          # build + unit tests + daemon (dry run) + protocol probe
swift test              # unit tests only (105 tests, no hardware needed)
```

Three harnesses, none of which need a phone:

- `tools/probe.mjs` drives a complete session against a running daemon — pairing, every
  event type, validation, rate limiting, version gating. The pairing code is single-use by
  design, so restart the daemon between runs (`dev.sh` does this for you).
- `tools/motion-check.mjs` drives the exact `motion.js` the browser loads with synthetic
  sensor data, including the gyroscope axis resolver.
- `tools/sensor-flow-check.mjs` exercises the wiring between sensors, resolver and pipeline.
  It exists because a dangling reference once broke that seam while every pipeline unit test
  kept passing.

### Useful flags

```
--dry-run          Accept connections, never post real input. Safe for experimenting.
--bind 127.0.0.1   Loopback only.
--auto-approve     Skip the approval prompt. Refused unless bound to loopback.
--selftest         Move the cursor in a square and exit.
--log-level debug  Verbose.
--keychain         Store secrets in the Keychain instead of 0600 files (signed hosts only).
```

Run `--help` for the full list. There are no hard-coded addresses or credentials anywhere;
the bind address is derived from live network interfaces at startup.

### Layout

```
Sources/RemoteKit/   Platform-agnostic core: protocol, validation, motion maths, rate limits.
                     Shared with the native iOS client in Phase 6 — this is why the whole
                     project is Swift rather than Node.
Sources/airpointd/   macOS daemon: TLS listener, HTTP + WebSocket server, pairing, CGEvent.
    Resources/web/   The controller PWA, served over TLS by the daemon itself.
Tests/               Unit tests for the protocol, motion pipeline and security primitives.
tools/               probe.mjs, motion-check.mjs, sensor-flow-check.mjs, dev.sh.
docs/                Product, architecture, protocol, security, motion, plan and testing.
```

---

## Troubleshooting

**"Could not reach your Mac" on the phone.**
Both devices must be on the same Wi-Fi network — a Guest network is usually isolated from
the main one and will not work. The daemon prints every address it is reachable on.

**Safari shows a certificate warning.**
Expected; see step 2 above. Safari can show an interstitial for an `https://` page but
*not* for a `wss://` connection, which is why the page and the WebSocket share one port —
accepting the certificate once covers both.

**The cursor does not move but everything else works.**
Accessibility permission. Run `./.build/debug/airpointd --selftest`. Note that macOS binds
the permission to the exact binary, so a rebuild can require re-granting it.

**The cursor drifts or jitters.**
Tap **Calibrate**, hold the phone still for a second, then point at the middle of the screen.
Calibration measures your specific device's noise floor and sizes the dead zone to it.

**The cursor is too fast or too slow.**
Sensitivity slider in Pointer mode; it persists.

**The Mac's IP changed.**
Restart the daemon so the certificate and QR code match the new address. Trusted devices can
reconnect via `<hostname>.local`, which does not change.

**Motion does not work at all in the browser.**
Check the page is on `https://` and that you tapped *Enable motion*. Motion sensors are a
secure-context API and require a user gesture; there is no way around either.

---

## Security

The phone can move the cursor and type, which is close to full control of the logged-in
session. `docs/04-security.md` has the full threat model; the short version:

- **TLS on the only listener**, LAN-private interfaces only. Binding a public address is
  refused without an explicit override flag. No UPnP, no relay, no cloud, no internet
  exposure by default.
- **Nothing gets control without a human saying yes** on the Mac — unless that human
  previously chose to remember that specific device.
- **Pairing codes are short-lived and single-use**, with a lockout after five failed
  attempts from one address.
- **`Origin` and `Host` allowlists** on the WebSocket upgrade, which is the defence against
  a malicious web page or DNS rebinding reaching the control channel. There is no ambient
  authority — no cookies, no token in the URL — so a cross-origin socket starts
  unauthenticated and dies at the 5-second deadline.
- **Keys come from a fixed allowlist**, never raw keycodes. Text is length-capped and
  control-characters stripped. Every numeric field is bounds-checked.
- **Per-event-type rate limits**, so a pointer flood cannot starve your ability to click.
- **Logs never contain typed text, pairing secrets, tokens or key names.** A remote's own
  log is still a keylog.
- Drags auto-release after 30 s, on disconnect, and on shutdown. Ctrl-C releases every held
  button and modifier.

---

## Licence

Not yet chosen.
