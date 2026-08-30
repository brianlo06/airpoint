#!/usr/bin/env node
// Drives the browser motion pipeline with synthetic `deviceorientation` angles.
//
// This exists to separate two very different failures that look identical from the couch:
// "the phone is not delivering sensor events" and "my maths turns sensor events into zero".
// It imports the exact file the browser loads, so a pass here means the remaining problem
// is delivery, permission or the clutch — not the algorithm.
//
//   node tools/motion-check.mjs

import {
  PointerPipeline,
  quatFromDeviceOrientation,
  quatConjugate,
  quatRotate,
  softDeadZone,
  DEFAULT_TUNING,
  GyroAxisResolver,
  SPEC_AXIS_CANDIDATE,
  applyAxisCandidate,
  normalize,
  cross,
} from '../Sources/airpointd/Resources/web/motion.js';

let passed = 0;
let failed = 0;

function check(name, condition, detail = '') {
  if (condition) {
    passed += 1;
    console.log(`  ok    ${name}`);
  } else {
    failed += 1;
    console.log(`  FAIL  ${name}${detail ? ' — ' + detail : ''}`);
  }
}

// Feeds a pan through the pipeline exactly as app.js does: process every sensor sample,
// drain at the send rate, sum what would have gone on the wire.
function pan({ from, to, axis, steps = 60, hz = 60, beta = 45, gamma = 0 }) {
  const pipeline = new PointerPipeline();
  const dt = 1 / hz;
  let t = 100;

  const anglesAt = (fraction) => {
    const value = from + (to - from) * fraction;
    return {
      alpha: axis === 'alpha' ? value : 0,
      beta: axis === 'beta' ? value : beta,
      gamma: axis === 'gamma' ? value : gamma,
    };
  };

  // Seed, then recentre, mirroring engage() on touchstart.
  const first = anglesAt(0);
  pipeline.process({
    attitude: quatFromDeviceOrientation(first.alpha, first.beta, first.gamma),
    timestamp: t,
  });
  pipeline.recenter(quatFromDeviceOrientation(first.alpha, first.beta, first.gamma));
  pipeline.setActive(true);

  let total = { dx: 0, dy: 0 };
  for (let i = 1; i <= steps; i += 1) {
    t += dt;
    const a = anglesAt(i / steps);
    pipeline.process({
      attitude: quatFromDeviceOrientation(a.alpha, a.beta, a.gamma),
      timestamp: t,
    });
    const drained = pipeline.drain(t);
    if (drained) {
      total.dx += drained.dx;
      total.dy += drained.dy;
    }
  }
  return total;
}

console.log('AirPoint motion pipeline check (browser code, synthetic sensors)\n');

// A 20-degree yaw sweep over one second is an ordinary aiming gesture.
const yaw = pan({ from: 0, to: 20, axis: 'alpha' });
check('a 20 deg yaw sweep produces horizontal motion',
  Math.abs(yaw.dx) > 100, `dx=${yaw.dx.toFixed(1)} dy=${yaw.dy.toFixed(1)}`);
console.log(`        dx=${yaw.dx.toFixed(1)} px  dy=${yaw.dy.toFixed(1)} px`);

// Tilting the phone up and down.
const pitch = pan({ from: 45, to: 65, axis: 'beta' });
check('a 20 deg pitch sweep produces vertical motion',
  Math.abs(pitch.dy) > 100, `dx=${pitch.dx.toFixed(1)} dy=${pitch.dy.toFixed(1)}`);
console.log(`        dx=${pitch.dx.toFixed(1)} px  dy=${pitch.dy.toFixed(1)} px`);

// The clutch must gate everything.
const clutched = (() => {
  const pipeline = new PointerPipeline();
  pipeline.setActive(false);
  let t = 100;
  pipeline.process({ attitude: quatFromDeviceOrientation(0, 45, 0), timestamp: t });
  let total = 0;
  for (let i = 1; i <= 60; i += 1) {
    t += 1 / 60;
    pipeline.process({ attitude: quatFromDeviceOrientation(i / 3, 45, 0), timestamp: t });
    const d = pipeline.drain(t);
    if (d) total += Math.abs(d.dx);
  }
  return total;
})();
check('a released clutch produces no motion at all', clutched === 0, `got ${clutched}`);

// A still phone must not creep.
const still = pan({ from: 10, to: 10, axis: 'alpha' });
check('a still phone produces no motion',
  Math.abs(still.dx) < 0.001 && Math.abs(still.dy) < 0.001,
  `dx=${still.dx} dy=${still.dy}`);

// Sanity on the stages most likely to silently zero everything out.
check('the dead zone passes an ordinary frame delta',
  softDeadZone(0.004, DEFAULT_TUNING.deadZoneRad, DEFAULT_TUNING.deadZoneRampRad) > 0.002,
  `got ${softDeadZone(0.004, DEFAULT_TUNING.deadZoneRad, DEFAULT_TUNING.deadZoneRampRad)}`);
check('the dead zone blocks sub-threshold drift',
  softDeadZone(0.0004, DEFAULT_TUNING.deadZoneRad, DEFAULT_TUNING.deadZoneRampRad) === 0);

// A realistic slow aim: 5 degrees over a second still has to move the cursor usefully.
const slow = pan({ from: 0, to: 5, axis: 'alpha' });
check('a slow 5 deg aim still moves the cursor',
  Math.abs(slow.dx) > 20, `dx=${slow.dx.toFixed(1)}`);
console.log(`        dx=${slow.dx.toFixed(1)} px over 5 deg`);

// --- the gyro-rate path, which is what a real phone now uses -----------------

// World down in device coordinates, for a phone held upright aiming away from the user.
const uprightDown = quatRotate(
  quatConjugate(quatFromDeviceOrientation(0, 90, 0)),
  { x: 0, y: 0, z: -1 }
);

function panByRate({ rate, gravityDown, seconds = 0.5, hz = 60 }) {
  const pipeline = new PointerPipeline();
  pipeline.setActive(true);
  const dt = 1 / hz;
  let t = 100;
  let total = { dx: 0, dy: 0 };
  pipeline.processRate(rate, gravityDown, t);
  for (let i = 0; i < seconds * hz; i += 1) {
    t += dt;
    pipeline.processRate(rate, gravityDown, t);
    const drained = pipeline.drain(t);
    if (drained) {
      total.dx += drained.dx;
      total.dy += drained.dy;
    }
  }
  return total;
}

console.log('\n  -- gyro-rate path --');
console.log(`        upright gravityDown = (${uprightDown.x.toFixed(2)}, ${uprightDown.y.toFixed(2)}, ${uprightDown.z.toFixed(2)})`);

// Turning right is a rotation about world down, whatever that is in device coordinates.
const scale = 0.5;
const rightTurn = { x: uprightDown.x * scale, y: uprightDown.y * scale, z: uprightDown.z * scale };
const turned = panByRate({ rate: rightTurn, gravityDown: uprightDown, seconds: 1 });
check('turning right moves the cursor right', turned.dx > 500,
  `dx=${turned.dx.toFixed(1)} dy=${turned.dy.toFixed(1)}`);
console.log(`        0.5 rad/s for 1 s -> dx=${turned.dx.toFixed(0)} px (2200 px/rad => ~1100)`);

const stillRate = panByRate({ rate: { x: 0, y: 0, z: 0 }, gravityDown: uprightDown, seconds: 1 });
check('a still gyro produces no motion',
  Math.abs(stillRate.dx) < 0.001 && Math.abs(stillRate.dy) < 0.001);

// --- gyro axis resolution ----------------------------------------------------
//
// Simulates a phone whose browser reports rotationRate under a given convention, and checks
// that the resolver recovers it from gravity alone. The iOS case is the one measured on a
// real device: CoreMotion's (x, y, z) passed straight through as (alpha, beta, gamma).

function simulate(trueOmegaSequence, encode) {
  const resolver = new GyroAxisResolver({ samplesNeeded: 60 });
  let gravity = normalize({ x: 0.05, y: -0.3, z: -0.95 });
  let previous = null;
  const dt = 1 / 60;

  for (const omega of trueOmegaSequence) {
    // Gravity is fixed in the world, so in the device frame it rotates the other way.
    const drift = cross(omega, gravity);
    const next = normalize({
      x: gravity.x - drift.x * dt,
      y: gravity.y - drift.y * dt,
      z: gravity.z - drift.z * dt,
    });
    previous = gravity;
    gravity = next;
    resolver.update(gravity, previous, encode(omega), dt);
    if (resolver.isResolved) break;
  }
  return resolver;
}

// A varied gesture: tilt, then turn, then a diagonal. Varied motion is what separates
// candidates that differ only in the component parallel to gravity.
const gesture = [];
for (let i = 0; i < 400; i += 1) {
  const phase = i / 60;
  gesture.push({
    x: 0.9 * Math.sin(phase * 2.0),
    y: 0.5 * Math.sin(phase * 1.3 + 1),
    z: 0.7 * Math.sin(phase * 1.7 + 2),
  });
}

// Spec convention: alpha is about Z, beta about X, gamma about Y.
const specEncoded = simulate(gesture, (w) => [w.z, w.x, w.y]);
check('resolver recovers the W3C axis convention', specEncoded.isResolved
  && JSON.stringify(applyAxisCandidate(specEncoded.resolved, [1, 2, 3]))
     === JSON.stringify({ x: 2, y: 3, z: 1 }),
  `got ${specEncoded.describe()}`);
console.log(`        spec-encoded -> ${specEncoded.describe()}`);

// iOS convention: CoreMotion (x, y, z) passed straight through.
const iosEncoded = simulate(gesture, (w) => [w.x, w.y, w.z]);
check('resolver recovers the iOS CoreMotion pass-through convention', iosEncoded.isResolved
  && JSON.stringify(applyAxisCandidate(iosEncoded.resolved, [1, 2, 3]))
     === JSON.stringify({ x: 1, y: 2, z: 3 }),
  `got ${iosEncoded.describe()}`);
console.log(`        iOS-encoded  -> ${iosEncoded.describe()}`);

// A sign flip must be caught too.
const flipped = simulate(gesture, (w) => [-w.x, w.y, w.z]);
check('resolver recovers a flipped sign', flipped.isResolved
  && applyAxisCandidate(flipped.resolved, [1, 2, 3]).x === -1,
  `got ${flipped.describe()}`);

// A still phone carries no information and must not produce a confident wrong answer.
const stillResolver = new GyroAxisResolver({ samplesNeeded: 60 });
const flat = normalize({ x: 0, y: -0.3, z: -0.95 });
for (let i = 0; i < 300; i += 1) stillResolver.update(flat, flat, [0, 0, 0], 1 / 60);
check('a still phone never resolves from noise', !stillResolver.isResolved);

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
