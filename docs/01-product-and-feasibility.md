# 1. Product Definition

## Problem
A laptop plugged into a TV is a great streaming box with a terrible remote. The moment you sit
down on the couch, the trackpad is 3 metres away. Existing answers are all compromised:
a wireless keyboard/trackpad is another object to lose, a Bluetooth "air mouse" dongle is
cheap hardware with bad software, and smart-TV apps don't control *your* browser session
(your logins, your extensions, your ad blocker, your queue).

Everyone already owns the right hardware: a phone with a 100 Hz gyroscope, a touchscreen,
a keyboard, and haptics.

## Product
**AirPoint** turns a phone into a motion-controlled remote for a Mac. Point the phone at the
screen, the cursor follows. Tap to click. Swipe to scroll. Switch to Media mode for
play/pause/seek/volume, Keyboard mode to type a search, Browser mode for back/forward/tabs.

## Target users
- **Primary:** a person who uses a laptop as a living-room media source (HDMI to TV, or a Mac mini
  under the TV). Technical enough to install an app, not willing to debug a network stack.
- **Secondary:** presenters (slide advance + laser-pointer cursor from anywhere in the room),
  and anyone with an accessibility need that makes a trackpad at desk distance hard.

## Core use cases
1. Browse YouTube from the couch, pick a video, fullscreen it, adjust volume.
2. Type "the bear season 3" into a Netflix search box without standing up.
3. Skip 10 s forward, pause when someone walks in, resume.
4. Advance slides during a talk while walking around.

## Value
It controls the *real cursor and keyboard*, so it works with every site — including DRM-protected
players — without extensions, injected scripts, or per-site integrations. Nothing to bypass,
nothing to break when a site ships a redesign.

## Explicit non-goals (v1)
Screen mirroring, internet-based remote access, Windows/Linux hosts, voice control,
multi-user sessions, gesture macros, game input.

---

# 2. Technical Feasibility Analysis

## Straightforward
| Thing | Why it's easy |
|---|---|
| Moving the macOS cursor | `CGEvent` + `.cghidEventTap` is a stable, documented public API. One Accessibility permission. |
| Synthesising keystrokes and text | `CGEvent.keyboardSetUnicodeString` types arbitrary Unicode without keycode mapping. |
| Media keys | `NSEvent` `.systemDefined` subtype 8 posts the same events as an F-key row; macOS shows the volume HUD, and the *frontmost app* handles play/pause. |
| Sensor fusion on iOS | `CMDeviceMotion` already ships a bias-corrected, gravity-referenced attitude quaternion at 100 Hz. On a native client we do **not** write a Kalman filter — Apple's is better than ours. |
| Local transport | TLS + TCP via `Network.framework`; `NWListener` gives us Bonjour advertisement for free. |
| Latency budget | LAN RTT is 2–8 ms on 5 GHz. Sensor-to-pixel under 40 ms is comfortably achievable. |

## Difficult / constrained
| Thing | The constraint | Consequence |
|---|---|---|
| **Web sensors need HTTPS** | `DeviceMotionEvent` is a secure-context API in Safari (since 12.2) and Chrome. `http://192.168.1.x` is *not* a secure context. | The Mac must serve the controller over TLS with a self-signed cert, and the user must click through an interstitial once. This is the single biggest UX tax on the web path. |
| **Web sensors need a user gesture** | `DeviceMotionEvent.requestPermission()` must be called from a transient user activation, and iOS re-prompts per origin. | The controller UI must have an explicit "Enable motion" button; it cannot auto-start. |
| Safari certificate exceptions | Safari can show an interstitial for an `https://` page, but **cannot** show one for a `wss://` connection. | HTTPS page and WebSocket must share the same host **and** the same port, so one accepted exception covers both. This forces a hand-rolled HTTP+WebSocket server on a single listener (see §4). |
| Web page suspension | iOS suspends timers and sensor delivery when Safari backgrounds or the screen locks. | Detect `visibilitychange`, freeze the pointer, show a "reconnect" state. A `NoSleep`-style silent-video wake-lock, or `navigator.wakeLock` where supported, keeps the screen on. |
| Gyro bias drift | Any MEMS gyro drifts; integrated yaw walks. | Never integrate to an absolute position. Use frame-to-frame deltas + dead zone + a stationary-bias estimator (see `docs/05-motion.md`). |
| Magnetometer indoors | TVs and speakers distort heading badly. | Use `CMAttitudeReferenceFrame.xArbitraryZVertical` (gravity-referenced, **no** magnetometer) rather than `...CorrectedZVertical`. We only need short-horizon relative yaw, not true north. |
| Accessibility permission | macOS requires the user to add the app in System Settings and it does not take effect for a CLI binary until re-launch in some cases. | Detect with `AXIsProcessTrusted()`, show a first-run wizard, re-check on a timer, never silently no-op. |
| Site-specific shortcuts | `F` is fullscreen on YouTube, `Enter`/`F` on Netflix, arrow-key seek intervals differ, Disney+ intercepts space differently. | Send *generic* input; ship a small per-site keymap table for the Media mode, defaulting to Space/arrows, and let the user override. Never inject scripts. |
| DRM | Netflix/Disney+ run in a protected media path. | Irrelevant to us — we only move the cursor and press keys, exactly like a human. Nothing here touches DRM. |

## Things that look hard but aren't
- **Multi-monitor**: `CGEvent` uses one global top-left-origin space spanning all displays. Clamp to the
  union of `NSScreen.screens`, projecting to the nearest screen rect when the union has holes.
- **Packet loss**: we send *deltas*, so a dropped packet loses ~3 px of travel and self-heals.
  No resync protocol needed.

## Verdict
Feasible. The only genuinely awkward part is the browser TLS trust step, and that is exactly the
cost the native iOS client (Phase 6) buys out.
