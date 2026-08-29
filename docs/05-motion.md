# 6. Motion Algorithm

## Relative vs absolute pointing — the decision

**Absolute pointing** maps device attitude directly to a screen coordinate: yaw ↦ x, pitch ↦ y.
This is what a Wii Remote does (using the IR sensor bar as a fixed optical reference).

| | Absolute | Relative (deltas) |
|---|---|---|
| Feels like | A laser pointer. Cursor is *where you aim*. | A mouse. Cursor is where you *moved it to*. |
| Needs a fixed reference | **Yes** — true heading (magnetometer, wrecked by TVs/speakers) or an optical marker (extra hardware) | No |
| Survives the user shifting on the couch | **No** — turn your body 20° and the mapping is wrong | Yes |
| Gyro drift | Accumulates into a permanent offset; needs constant re-reference | Manifests as slow creep, killed by the dead zone |
| Screen edges | Cursor pins at the edge and the mapping becomes non-invertible ("dead" region you must aim back out of) | Clamps harmlessly; keep moving and it comes back |
| Packet loss | Recoverable (next absolute sample corrects) | Loses a few px, self-heals |
| Precision at distance | Limited by arm tremor across the *whole* screen | Adjustable — you can slow down for fine work |

**Chosen for MVP: relative, computed from attitude deltas.**

The important nuance: we do *not* integrate raw gyro rates. We compute the device's **pointing
vector in a gravity-referenced world frame** each frame, take its angular change, and convert that
to pixels. Over a one-second horizon this feels exactly like absolute laser pointing (a 5° flick
right always moves the same number of pixels regardless of how the phone is rolled); over minutes
it behaves like a mouse (no drift lock-in, no body-orientation dependency). That combination is
what makes a good air mouse, and it is why "relative" here is not a downgrade.

Absolute mode remains viable as a later opt-in for presenters standing in a fixed spot;
the pipeline is structured so it is a different final stage, not a rewrite.

## Frames and notation

- Device frame: **x** right across the screen, **y** up the screen, **z** out of the screen
  toward the user. The phone is held flat-ish, pointing *away* from the user, so the natural
  pointing axis is **p̂ = (0, 0, −1)** (out the back of the phone).
- `q_t` — unit quaternion, device→world, gravity-referenced, no magnetometer
  (iOS: `CMAttitudeReferenceFrame.xArbitraryZVertical`; web: built from
  `deviceorientation`'s α/β/γ, or integrated from `rotationRate` where available).
- `q_ref` — reference attitude captured at calibration/recenter.

## Input source: angular rate, not attitude — revised after device testing

The first implementation differenced the orientation quaternion. On a real iPhone that
produced a clear asymmetry: **horizontal pointing was visibly worse than vertical**, janky
and imprecise, while pitch felt fine.

The cause is that iOS derives `deviceorientation`'s **alpha from the magnetometer**. Indoors,
next to a laptop and a television, the heading is noisy and laggy. Beta and gamma come from
gyro/accelerometer fusion and have no such problem — so yaw inherited magnetic noise that
pitch never saw.

The fix is to drive pointing from the **gyroscope rate** and use gravity only for roll
compensation, which touches the magnetometer nowhere:

```
down  = unit vector along world "down", in device coordinates
right = normalize(down × p̂)              // horizontal axis perpendicular to the aim
Δyaw   = (ω · down)  · dt
Δpitch = (ω · right) · dt
```

`down` is derived from the orientation quaternion rather than from
`accelerationIncludingGravity`, for two reasons: the accelerometer reading is polluted by
hand movement, and browsers disagree about its sign. Gravity's direction depends only on
beta and gamma — never on alpha — so this remains magnetometer-free.

Roll compensation is preserved: both axes are recomputed from gravity every sample, so the
mapping is identical in any grip. `AngularRatePointerTests.testRollDoesNotChangeTheMapping`
asserts that the same physical gesture produces the same travel with the phone rolled 90°.

The attitude-differencing path below is retained as a fallback for clients with no usable
gyroscope stream, and both paths share stages ⑦–⑨.

## Pipeline

```
sensors ─▶ ① attitude ─▶ ② relative rotation ─▶ ③ pointing vector ─▶ ④ yaw/pitch
        ─▶ ⑤ frame delta ─▶ ⑥ bias removal ─▶ ⑦ filter ─▶ ⑧ dead zone
        ─▶ ⑨ gain × acceleration ─▶ ⑩ velocity clamp ─▶ ⑪ 60 Hz coalescer ─▶ (dx, dy) px
```

### ① Attitude
Native iOS: `CMDeviceMotion.attitude.quaternion`, 100 Hz, already fused and bias-corrected.
Web: `deviceorientation` gives Tait–Bryan α (z), β (x'), γ (y''), in degrees, ZXY order:

```
q = qz(α) ⊗ qx(β) ⊗ qy(γ)
```

Note α is magnetometer-influenced on iOS unless `webkitCompassHeading` is absent; because we only
ever use *differences* of α, a slowly-varying magnetic error is indistinguishable from gyro bias
and is removed by ⑥.

### ② Relative rotation
```
q_rel = conj(q_ref) ⊗ q_t
```
### ③ Pointing vector
Rotate p̂ by `q_rel` (v′ = q ⊗ v ⊗ q*):
```
w = R(q_rel) · (0, 0, −1)
```
Rotating the *pointing axis* rather than reading Euler angles directly is what gives free **roll
compensation**: if the user rotates the phone about its own pointing axis, `w` does not change, so
the cursor does not move. This is the single most important detail for "works in portrait and
landscape" — no orientation special-casing is needed anywhere in the pipeline.

### ④ Yaw / pitch of the pointing vector
```
θ = atan2( w.x, −w.z )                    // yaw,   +right
φ = atan2( w.y, sqrt(w.x² + w.z²) )       // pitch, +up
```
`atan2` for pitch (rather than `asin(w.y)`) keeps the derivative bounded near the poles, i.e. when
the phone is pointed straight up or down.

### ⑤ Frame delta with wrap handling
```
Δθ = wrapToPi(θ_t − θ_{t−1})
Δφ = wrapToPi(φ_t − φ_{t−1})
wrapToPi(a) = a − 2π·round(a / 2π)
```
Guard: if `dt > 250 ms` (sensor stall, tab backgrounded, phone call), **discard the delta and
re-seed** `θ_{t−1}, φ_{t−1}`. Never emit motion accumulated across a gap — that is the classic
"cursor teleports across the screen when you unlock the phone" bug.

### ⑥ Stationary bias estimation
The phone is judged stationary when, over a 400 ms window,
`|‖a‖ − g| < 0.06 g` **and** `‖ω‖ < 0.02 rad/s`.
While stationary, update a slow bias estimate of the per-frame angular delta:
```
b ← b + λ (Δ − b),    λ = 0.02
```
and always subtract it: `Δ′ = Δ − b`. λ is small enough (τ ≈ 2 s at 100 Hz) that real motion
never poisons the estimate, because real motion also fails the stationary test.

### ⑦ Filtering — **One-Euro**
A fixed low-pass filter forces a bad trade: cut jitter at rest and you add lag in motion.
The One-Euro filter (Casiez, Roussel & Vogel, CHI 2012) makes the cutoff a function of speed:

```
fc(t) = fc_min + β · |x̂˙(t)|
α(t)  = 1 / (1 + τ/Te),   τ = 1/(2π·fc),   Te = dt
x̂(t)  = α·x(t) + (1−α)·x̂(t−1)
```
with the derivative itself low-pass filtered at `d_cutoff`.
Defaults, tuned for hand tremor at ~100 Hz: `fc_min = 1.2 Hz`, `β = 0.012`, `d_cutoff = 1.0 Hz`.
Cost: ~15 lines, two floats of state per axis. This is *not* overengineering — it is strictly
cheaper than a Kalman filter and materially better than a plain EMA.

A plain `ExponentialFilter` ships alongside it behind the same `MotionFilter` protocol so the two
can be A/B'd, and so a Kalman/complementary implementation can be dropped in later without
touching the pipeline.

### ⑧ Dead zone — soft, not hard
A hard dead zone produces a visible jump when you cross it. Use a three-part piecewise curve:
```
softDeadZone(x, ε, M) = 0                                    if |x| ≤ ε
                        sign(x)·(|x| − ε)·M/(M − ε)          if ε < |x| < M
                        x                                    if |x| ≥ M
```
Continuous at both ends, and **exact above the knee** so fast motion keeps full gain.

Defaults: `ε = 0.0008 rad` (≈ 4.6°/s of residual drift suppressed at 100 Hz),
`M = 0.006 rad/frame` (≈ 34°/s — an ordinary deliberate pointing speed).

The knee value matters more than it looks. An early draft used `M = 0.05 rad/frame`
(≈ 290°/s), which meant compensation never engaged at real pointing speeds and quietly
threw away roughly a third of the gain on every normal sweep — the cursor felt sluggish
for no visible reason. `PointerPipelineTests.testYawSweepMovesCursorHorizontally` asserts
that a 10° sweep retains at least 75% of its ideal travel, so this cannot regress silently.

### ⑨ Gain and acceleration
```
speed  = ‖(Δ′θ, Δ′φ)‖ / dt                                    // rad/s
accel  = 1 + k · min( (speed / ω₀)^p , cap )
dx_px  =  G · S · accel · Δ′θ
dy_px  = −G · S · accel · Δ′φ                                 // screen y grows downward
```
- `G = 2200 px/rad` base gain (≈ 38 px per degree; a 30° sweep crosses a 2560 px screen at 1.0×).
- `S` = user sensitivity slider, 0.25 – 3.0, default 1.0.
- `ω₀ = 1.5 rad/s`, `k = 1.6`, `p = 1.3`, `cap = 3.0`.
  Slow, deliberate aiming stays at ~1.0× for precision; a fast flick reaches ~4× and crosses two
  displays in one gesture.

### ⑩ Velocity clamp
```
if ‖(dx,dy)‖ / dt > V_max:  scale both so that it equals V_max     // V_max = 9000 px/s
```
Originally 4000 px/s. Device testing showed the clamp binding on nearly every fast flick —
deltas pinned at exactly 80 px per frame at 50 Hz — which truncates the end of a gesture and
reads as jank. 9000 px/s still bounds a runaway while sitting above what a hand produces.
Bounds the damage from a sensor glitch, a dropped frame, or a hostile client.

### ⑪ Coalescing
Accumulate `dx,dy` per sensor frame; emit at ≤ 60 Hz. If the socket is backed up
(`bufferedAmount > 32 KiB`), skip the send and keep accumulating.

## Calibration (5 seconds, once per session)

1. **Hold still** (1.2 s). Collect `ω` and `‖a‖`. Reject and retry if `‖ω‖ > 0.15 rad/s`
   ("hold the phone steady"). Compute the initial gyro bias `b₀` and the noise floor `σ`.
2. **Auto-tune the dead zone**: `ε = clamp(3σ·dt, 0.0006, 0.004)` — a phone with a noisier gyro
   gets a bigger dead zone automatically, rather than a hard-coded constant that is wrong for
   half the fleet.
3. **Point at the centre of the screen and tap** → sets `q_ref`. This is the only step the user
   perceives as "calibration".
4. Report `calibration{stage:"complete", …}` for the Mac's troubleshooting panel.

## Recenter
Sets `q_ref ← q_t` and zeroes the filter and the delta history. Optionally asks the Mac to warp the
cursor to the centre of the active display (`recenter{toCenter:true}`), which is what users
actually expect: *"put the cursor in the middle and let me point at the middle."*

Bound to: the recenter button, a double-tap on the trackpad area, and automatically after any
sensor gap > 250 ms.

## The clutch — the most important UX decision here
**Motion is only active while a finger rests on the pointer pad** (dead-man switch), like a
laser-pointer trigger. Default on; a "always-on motion" toggle exists in settings.

This one choice resolves, for free, half the edge-case list: accidental movement while gesturing
in conversation, drift while the phone sits on the sofa arm, the phone-rings case, screen-lock
(a resting finger keeps the screen awake), and "I want to quickly pause motion control".

## Pseudocode

```
state: q_ref, θ_prev, φ_prev, bias b, filters Fx Fy, accum(ax, ay), tLastSend, stationary window

on sensor sample (q_t, ω, a, t):
    if not clutchEngaged:  reset(θ_prev, φ_prev); return
    dt = t - tPrev; tPrev = t
    if dt <= 0 or dt > 0.250:                       # stall / resume / first frame
        reseed(q_t); return

    q_rel = conj(q_ref) ⊗ q_t
    w     = rotate(q_rel, (0,0,-1))
    θ = atan2(w.x, -w.z);  φ = atan2(w.y, hypot(w.x, w.z))

    if θ_prev is nil: θ_prev, φ_prev = θ, φ; return
    dθ = wrapToPi(θ - θ_prev);  dφ = wrapToPi(φ - φ_prev)
    θ_prev, φ_prev = θ, φ

    updateStationary(a, ω, dt)
    if isStationary: b = b + 0.02 * ((dθ,dφ) - b)
    dθ -= b.x;  dφ -= b.y

    dθ = Fx.filter(dθ, dt);  dφ = Fy.filter(dφ, dt)
    dθ = softDeadZone(dθ, ε); dφ = softDeadZone(dφ, ε)
    if dθ == 0 and dφ == 0: return

    speed = hypot(dθ, dφ) / dt
    g     = G * S * (1 + k * min(pow(speed/ω₀, p), cap))
    ax += g * dθ;  ay += -g * dφ

on send tick (60 Hz):
    if ax == 0 and ay == 0: return
    v = hypot(ax, ay) / elapsed
    if v > V_max: s = V_max/v; ax *= s; ay *= s
    if socket.bufferedAmount > 32768: return          # keep accumulating
    send pointer_move{dx: ax, dy: ay}; ax = ay = 0
```

## Why not a Kalman filter for v1
A Kalman filter needs a motion model and a measurement-noise model per device to beat One-Euro on
*perceived* pointing quality, and it adds tuning surface we cannot validate without a device lab.
On iOS, `CMDeviceMotion` has already run a proper fusion filter before we see the data, so a second
Kalman stage would mostly filter an already-filtered signal. The `MotionFilter` protocol exists
precisely so this can be revisited with measurements rather than opinions.
