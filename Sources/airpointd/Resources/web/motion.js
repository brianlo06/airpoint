// AirPoint motion pipeline.
//
// A direct port of Sources/RemoteKit/Motion/PointerPipeline.swift. The Swift version is the
// reference implementation and carries the unit tests; this file must stay behaviourally
// identical to it. When the native iOS client lands it will use the Swift one directly and
// this file becomes the Android/zero-install path.
//
// See docs/05-motion.md for the maths.

'use strict';

// ---------------------------------------------------------------------------
// Quaternions
// ---------------------------------------------------------------------------

export function quatMultiply(a, b) {
  return {
    w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
    x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
    y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
    z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
  };
}

export function quatConjugate(q) {
  return { w: q.w, x: -q.x, y: -q.y, z: -q.z };
}

export function quatNormalize(q) {
  const n = Math.hypot(q.w, q.x, q.y, q.z);
  if (!(n > 1e-12)) return { w: 1, x: 0, y: 0, z: 0 };
  return { w: q.w / n, x: q.x / n, y: q.y / n, z: q.z / n };
}

// Rotates a vector by a quaternion: v' = q (x) v (x) q*
export function quatRotate(q, v) {
  const ux = q.x, uy = q.y, uz = q.z;
  const uvx = uy * v.z - uz * v.y;
  const uvy = uz * v.x - ux * v.z;
  const uvz = ux * v.y - uy * v.x;
  const uuvx = uy * uvz - uz * uvy;
  const uuvy = uz * uvx - ux * uvz;
  const uuvz = ux * uvy - uy * uvx;
  return {
    x: v.x + 2 * (q.w * uvx + uuvx),
    y: v.y + 2 * (q.w * uvy + uuvy),
    z: v.z + 2 * (q.w * uvz + uuvz),
  };
}

// Builds the device attitude from the browser's deviceorientation angles.
//
// The W3C spec defines this as the intrinsic Z-X'-Y'' rotation by (alpha, beta, gamma).
// Getting the order wrong yields a cursor that only behaves when the phone is held flat,
// which is the single most common bug in web motion code.
export function quatFromDeviceOrientation(alphaDeg, betaDeg, gammaDeg) {
  const a = (alphaDeg * Math.PI) / 360;   // degrees -> radians, halved
  const b = (betaDeg * Math.PI) / 360;
  const g = (gammaDeg * Math.PI) / 360;

  const ca = Math.cos(a), sa = Math.sin(a);
  const cb = Math.cos(b), sb = Math.sin(b);
  const cg = Math.cos(g), sg = Math.sin(g);

  return quatNormalize({
    w: ca * cb * cg - sa * sb * sg,
    x: ca * sb * cg - sa * cb * sg,
    y: ca * cb * sg + sa * sb * cg,
    z: sa * cb * cg + ca * sb * sg,
  });
}

export function dot(a, b) {
  return a.x * b.x + a.y * b.y + a.z * b.z;
}

export function cross(a, b) {
  return {
    x: a.y * b.z - a.z * b.y,
    y: a.z * b.x - a.x * b.z,
    z: a.x * b.y - a.y * b.x,
  };
}

export function normalize(v) {
  const n = Math.hypot(v.x, v.y, v.z);
  if (!(n > 1e-9)) return { x: 0, y: 0, z: 0 };
  return { x: v.x / n, y: v.y / n, z: v.z / n };
}

export function wrapToPi(a) {
  if (!Number.isFinite(a)) return 0;
  return a - 2 * Math.PI * Math.round(a / (2 * Math.PI));
}

// ---------------------------------------------------------------------------
// One-Euro filter
// ---------------------------------------------------------------------------

// A fixed low-pass filter forces a bad trade: a cutoff low enough to kill hand tremor at
// rest adds visible lag during fast motion. One-Euro makes the cutoff a function of speed.
export class OneEuroFilter {
  constructor(minCutoff = 1.2, beta = 0.012, derivativeCutoff = 1.0) {
    this.minCutoff = minCutoff;
    this.beta = beta;
    this.derivativeCutoff = derivativeCutoff;
    this.reset();
  }

  reset() {
    this.lastValue = null;
    this.lastFiltered = 0;
    this.lastDerivative = 0;
  }

  static alpha(cutoff, dt) {
    const tau = 1 / (2 * Math.PI * cutoff);
    return 1 / (1 + tau / dt);
  }

  filter(value, dt) {
    if (!Number.isFinite(value) || !(dt > 0)) return this.lastFiltered;

    if (this.lastValue === null) {
      this.lastValue = value;
      this.lastFiltered = value;
      this.lastDerivative = 0;
      return value;
    }

    const rawDerivative = (value - this.lastValue) / dt;
    const dAlpha = OneEuroFilter.alpha(this.derivativeCutoff, dt);
    this.lastDerivative = dAlpha * rawDerivative + (1 - dAlpha) * this.lastDerivative;

    const cutoff = this.minCutoff + this.beta * Math.abs(this.lastDerivative);
    const a = OneEuroFilter.alpha(cutoff, dt);
    this.lastFiltered = a * value + (1 - a) * this.lastFiltered;
    this.lastValue = value;
    return this.lastFiltered;
  }
}

// ---------------------------------------------------------------------------
// Tuning
// ---------------------------------------------------------------------------

export const DEFAULT_TUNING = {
  baseGainPxPerRad: 2200,
  sensitivity: 1.0,
  deadZoneRad: 0.0008,
  deadZoneRampRad: 0.006,
  accelCoefficient: 1.6,
  accelReferenceRadS: 1.5,
  accelExponent: 1.3,
  accelCap: 3.0,
  maxVelocityPxPerSec: 9000,
  maxSensorGap: 0.25,
  stationaryGyroThresholdRadS: 0.02,
  stationaryAccelToleranceG: 0.06,
  stationaryWindow: 0.4,
  biasLearnRate: 0.02,
};

// Zero below eps, linear ramp to the knee, pass-through above it. Continuous at both ends,
// so crossing the threshold never produces a visible jump.
export function softDeadZone(value, epsilon, ramp) {
  if (!Number.isFinite(value)) return 0;
  if (!(epsilon > 0)) return value;
  const magnitude = Math.abs(value);
  if (magnitude <= epsilon) return 0;
  const knee = Math.max(ramp, epsilon * 2);
  if (magnitude >= knee) return value;
  const sign = value < 0 ? -1 : 1;
  return (sign * (magnitude - epsilon) * knee) / (knee - epsilon);
}

export function accelerationFactor(speed, tuning) {
  if (!Number.isFinite(speed) || speed <= 0 || !(tuning.accelReferenceRadS > 0)) return 1;
  const normalized = speed / tuning.accelReferenceRadS;
  const curved = Math.min(Math.pow(normalized, tuning.accelExponent), tuning.accelCap);
  return 1 + tuning.accelCoefficient * curved;
}

// ---------------------------------------------------------------------------
// Pipeline
// ---------------------------------------------------------------------------

const POINTING_AXIS = { x: 0, y: 0, z: -1 };

// The horizontal axis about which "aim higher / aim lower" happens, in any grip.
//
// Taking the horizontal component of the phone's own lateral (+X) axis works whether the
// user points the top edge of the phone at the screen like a remote, or the back of it like
// a camera, because tipping the phone about its left-right axis raises or lowers the aim
// either way. It also stays well-conditioned when the phone is held flat, where deriving
// the axis from an assumed aiming direction collapses to zero.
export function horizontalRight(down) {
  let lateral = { x: 1, y: 0, z: 0 };
  // Rolled into landscape, +X is near vertical and useless as a horizontal reference.
  if (Math.abs(dot(lateral, down)) > 0.9) lateral = { x: 0, y: 1, z: 0 };
  const k = dot(lateral, down);
  const horizontal = {
    x: lateral.x - down.x * k,
    y: lateral.y - down.y * k,
    z: lateral.z - down.z * k,
  };
  if (Math.hypot(horizontal.x, horizontal.y, horizontal.z) < 1e-3) return null;
  return normalize(horizontal);
}

export class PointerPipeline {
  constructor(tuning = {}) {
    this.tuning = { ...DEFAULT_TUNING, ...tuning };
    this.yawFilter = new OneEuroFilter();
    this.pitchFilter = new OneEuroFilter();
    this.reset();
  }

  reset() {
    this.referenceAttitude = { w: 1, x: 0, y: 0, z: 0 };
    this.previousYaw = null;
    this.previousPitch = null;
    this.previousTimestamp = null;
    this.biasYaw = 0;
    this.biasPitch = 0;
    this.stationarySince = null;
    this.accumulated = { dx: 0, dy: 0 };
    this.lastDrain = null;
    this._active = true;
    this.yawFilter.reset();
    this.pitchFilter.reset();
  }

  // The clutch. Motion is only live while the user's thumb is on the pad, which is what
  // makes drift, accidental movement and the phone-rings case all non-problems.
  setActive(active) {
    if (active === this._active) return;
    this._active = active;
    this.previousYaw = null;
    this.previousPitch = null;
    this.accumulated = { dx: 0, dy: 0 };
    this.yawFilter.reset();
    this.pitchFilter.reset();
  }

  get isActive() {
    return this._active;
  }

  recenter(attitude) {
    this.referenceAttitude = quatNormalize(attitude);
    this.previousYaw = null;
    this.previousPitch = null;
    this.accumulated = { dx: 0, dy: 0 };
    this.biasYaw = 0;
    this.biasPitch = 0;
    this.yawFilter.reset();
    this.pitchFilter.reset();
  }

  // The preferred path: integrate gyroscope rate, resolved onto gravity-derived world axes.
  //
  // iOS derives `deviceorientation`'s alpha from the magnetometer, which indoors — beside a
  // laptop and a television — is noticeably noisier and laggier than beta/gamma. On a real
  // phone that made horizontal pointing distinctly worse than vertical. The gyroscope has no
  // such asymmetry, and resolving its rate onto axes derived from gravity keeps the roll
  // compensation that makes portrait and landscape work identically.
  //
  //   yaw rate   = omega . gravityDown           (rotation about the world vertical)
  //   pitch rate = omega . (gravityDown x aim)   (rotation about the world horizontal)
  //
  // rate: rad/s in the device frame. gravityDown: unit vector along world down, device frame.
  processRate(rate, gravityDown, timestamp) {
    const previousT = this.previousTimestamp;
    this.previousTimestamp = timestamp;
    if (previousT === null) return { dx: 0, dy: 0 };

    const dt = timestamp - previousT;
    if (!(dt > 0) || dt > this.tuning.maxSensorGap) return { dx: 0, dy: 0 };
    if (!this._active) return { dx: 0, dy: 0 };
    if (!Number.isFinite(rate.x) || !Number.isFinite(rate.y) || !Number.isFinite(rate.z)) {
      return { dx: 0, dy: 0 };
    }

    const down = normalize(gravityDown);
    if (Math.hypot(down.x, down.y, down.z) < 0.5) return { dx: 0, dy: 0 };

    const right = horizontalRight(down);
    if (!right) return { dx: 0, dy: 0 };

    let dYaw = dot(rate, down) * dt;
    let dPitch = dot(rate, right) * dt;
    // Exposed for the diagnostics channel; costs nothing and turns an argument about
    // sensor-axis conventions into a measurement.
    this.lastResolved = { yaw: dYaw, pitch: dPitch, down, right };

    this._updateStationaryFromRate(rate, timestamp, dYaw, dPitch);
    dYaw -= this.biasYaw;
    dPitch -= this.biasPitch;

    return this._emit(dYaw, dPitch, dt);
  }

  _updateStationaryFromRate(rate, timestamp, dYaw, dPitch) {
    if (Math.hypot(rate.x, rate.y, rate.z) >= this.tuning.stationaryGyroThresholdRadS) {
      this.stationarySince = null;
      return;
    }
    if (this.stationarySince === null) {
      this.stationarySince = timestamp;
      return;
    }
    if (timestamp - this.stationarySince < this.tuning.stationaryWindow) return;
    const lambda = this.tuning.biasLearnRate;
    this.biasYaw += lambda * (dYaw - this.biasYaw);
    this.biasPitch += lambda * (dPitch - this.biasPitch);
  }

  // Fallback for clients with no usable gyroscope stream.
  // sample: { attitude, rotationRate?: {x,y,z} rad/s, accelerationG?: {x,y,z} g, timestamp: seconds }
  process(sample) {
    const previousT = this.previousTimestamp;
    this.previousTimestamp = sample.timestamp;
    if (previousT === null) return { dx: 0, dy: 0 };

    const dt = sample.timestamp - previousT;
    if (!(dt > 0) || dt > this.tuning.maxSensorGap) {
      // Sensor stall or resume (backgrounded tab, phone call, screen lock). Discard the
      // history: emitting a delta accumulated across the gap is the cursor-teleport bug.
      this.previousYaw = null;
      this.previousPitch = null;
      return { dx: 0, dy: 0 };
    }

    const relative = quatNormalize(
      quatMultiply(quatConjugate(this.referenceAttitude), quatNormalize(sample.attitude))
    );
    // Rotating the pointing axis rather than reading Euler angles gives free roll
    // compensation: spinning the phone about its own aim does not move the cursor, which
    // is what makes portrait and landscape work with no special cases.
    const w = quatRotate(relative, POINTING_AXIS);

    const yaw = Math.atan2(w.x, -w.z);
    const pitch = Math.atan2(w.y, Math.hypot(w.x, w.z));

    if (this.previousYaw === null || this.previousPitch === null) {
      this.previousYaw = yaw;
      this.previousPitch = pitch;
      return { dx: 0, dy: 0 };
    }

    let dYaw = wrapToPi(yaw - this.previousYaw);
    let dPitch = wrapToPi(pitch - this.previousPitch);
    this.previousYaw = yaw;
    this.previousPitch = pitch;

    if (!this._active) return { dx: 0, dy: 0 };

    this._updateStationary(sample, dYaw, dPitch);
    dYaw -= this.biasYaw;
    dPitch -= this.biasPitch;

    return this._emit(dYaw, dPitch, dt);
  }

  // Shared tail for both input paths, so the two can never drift apart.
  _emit(rawYaw, rawPitch, dt) {
    let dYaw = this.yawFilter.filter(rawYaw, dt);
    let dPitch = this.pitchFilter.filter(rawPitch, dt);

    dYaw = softDeadZone(dYaw, this.tuning.deadZoneRad, this.tuning.deadZoneRampRad);
    dPitch = softDeadZone(dPitch, this.tuning.deadZoneRad, this.tuning.deadZoneRampRad);
    if (dYaw === 0 && dPitch === 0) return { dx: 0, dy: 0 };

    const speed = Math.hypot(dYaw, dPitch) / dt;
    const gain =
      this.tuning.baseGainPxPerRad *
      this.tuning.sensitivity *
      accelerationFactor(speed, this.tuning);

    const delta = { dx: gain * dYaw, dy: -gain * dPitch };
    this.accumulated.dx += delta.dx;
    this.accumulated.dy += delta.dy;
    return delta;
  }

  // Call at the send rate (60 Hz), not the sensor rate.
  drain(now) {
    const last = this.lastDrain;
    this.lastDrain = now;
    if (this.accumulated.dx === 0 && this.accumulated.dy === 0) return null;

    let { dx, dy } = this.accumulated;
    this.accumulated = { dx: 0, dy: 0 };

    if (last !== null) {
      const elapsed = now - last;
      if (elapsed > 0) {
        const magnitude = Math.hypot(dx, dy);
        const velocity = magnitude / elapsed;
        if (velocity > this.tuning.maxVelocityPxPerSec && magnitude > 0) {
          const scale = this.tuning.maxVelocityPxPerSec / velocity;
          dx *= scale;
          dy *= scale;
        }
      }
    }
    if (!Number.isFinite(dx) || !Number.isFinite(dy)) return null;
    return { dx, dy };
  }

  _updateStationary(sample, dYaw, dPitch) {
    const rate = sample.rotationRate;
    const accel = sample.accelerationG;
    if (!rate || !accel) {
      this.stationarySince = null;
      return;
    }
    const gyroStill = Math.hypot(rate.x, rate.y, rate.z) < this.tuning.stationaryGyroThresholdRadS;
    const accelStill =
      Math.abs(Math.hypot(accel.x, accel.y, accel.z) - 1) < this.tuning.stationaryAccelToleranceG;

    if (!gyroStill || !accelStill) {
      this.stationarySince = null;
      return;
    }
    if (this.stationarySince === null) {
      this.stationarySince = sample.timestamp;
      return;
    }
    // Only learn after a full window of stillness, so a pause mid-gesture cannot poison
    // the estimate.
    if (sample.timestamp - this.stationarySince < this.tuning.stationaryWindow) return;
    const lambda = this.tuning.biasLearnRate;
    this.biasYaw += lambda * (dYaw - this.biasYaw);
    this.biasPitch += lambda * (dPitch - this.biasPitch);
  }
}

// ---------------------------------------------------------------------------
// Calibration
// ---------------------------------------------------------------------------

// Samples a stationary phone to measure its noise floor, then sizes the dead zone to it.
// A hard-coded dead zone is wrong for half the devices in the world; this one adapts.
export class Calibrator {
  constructor(durationMs = 1200) {
    this.durationMs = durationMs;
    this.samples = [];
    this.startedAt = null;
  }

  start() {
    this.samples = [];
    this.startedAt = performance.now();
  }

  // Returns null while still sampling, or a result object when finished.
  add(rotationRate) {
    if (this.startedAt === null) return null;
    if (rotationRate) {
      this.samples.push(Math.hypot(rotationRate.x, rotationRate.y, rotationRate.z));
    }
    if (performance.now() - this.startedAt < this.durationMs) return null;

    this.startedAt = null;
    if (this.samples.length < 10) {
      return { ok: false, reason: 'not enough sensor samples' };
    }
    const mean = this.samples.reduce((a, b) => a + b, 0) / this.samples.length;
    if (mean > 0.15) {
      return { ok: false, reason: 'hold the phone still' };
    }
    const variance =
      this.samples.reduce((a, b) => a + (b - mean) * (b - mean), 0) / this.samples.length;
    const sigma = Math.sqrt(variance);
    // 3 sigma of the measured noise, bounded so a pathological reading cannot disable
    // pointing entirely or leave it jittering.
    const deadZoneRad = Math.min(Math.max(3 * sigma * 0.01, 0.0006), 0.004);
    return { ok: true, deadZoneRad, noiseRadS: sigma, biasRadS: [mean, 0, 0], holdMs: this.durationMs };
  }
}
