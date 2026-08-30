#!/usr/bin/env node
// Exercises the controller's sensor control flow end to end against the real motion.js.
//
// This exists because of a specific failure: a rename left a dangling reference, the sensor
// handler threw on every event, and because a throw inside a DOM listener is swallowed by
// the browser, all motion stopped with no error anywhere. Unit tests on the pipeline passed
// the whole time — they never exercised the wiring between the sensors, the axis resolver
// and the pipeline. This does.
//
//   node tools/sensor-flow-check.mjs

import {
  PointerPipeline,
  GyroAxisResolver,
  applyAxisCandidate,
  quatFromDeviceOrientation,
  normalize,
  cross,
} from '../Sources/airpointd/Resources/web/motion.js';

// Mirrors App._processSensorSample. Kept deliberately close to it: if that method changes
// shape, this should be updated in step.
function runSession({ encode, samples = 400 }) {
  const pipeline = new PointerPipeline();
  const axes = new GyroAxisResolver();
  pipeline.setActive(true);

  let gravity = normalize({ x: 0.04, y: -0.26, z: -0.96 });   // a phone held like a remote
  let previousGravity = null;
  let lastGravityAt = null;
  let usedRatePath = false;
  let usedFallback = false;
  let travel = 0;

  for (let i = 0; i < samples; i += 1) {
    const t = 100 + i / 60;
    const omega = {
      x: 0.8 * Math.sin(i / 20),
      y: 0.4 * Math.sin(i / 31 + 1),
      z: 0.6 * Math.sin(i / 17 + 2),
    };
    const drift = cross(omega, gravity);
    gravity = normalize({
      x: gravity.x - drift.x / 60,
      y: gravity.y - drift.y / 60,
      z: gravity.z - drift.z / 60,
    });
    const raw = encode(omega);

    const dt = lastGravityAt === null ? 0 : t - lastGravityAt;
    axes.update(gravity, previousGravity, raw, dt);
    previousGravity = gravity;
    lastGravityAt = t;

    if (axes.isResolved) {
      usedRatePath = true;
      pipeline.processRate(applyAxisCandidate(axes.resolved, raw), gravity, t);
    } else {
      usedFallback = true;
      pipeline.process({
        attitude: quatFromDeviceOrientation(0, 20, 0),
        rotationRate: { x: raw[0], y: raw[1], z: raw[2] },
        accelerationG: null,
        timestamp: t,
      });
    }
    const drained = pipeline.drain(t);
    if (drained) travel += Math.hypot(drained.dx, drained.dy);
  }
  return { usedRatePath, usedFallback, travel, axes };
}

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

console.log('AirPoint sensor flow check\n');

const ios = runSession({ encode: (w) => [w.x, w.y, w.z] });
check('the fallback path carries motion before the axes resolve', ios.usedFallback);
check('the rate path takes over once the axes resolve', ios.usedRatePath);
check('an iOS-convention phone resolves correctly',
  ios.axes.describe() === 'x=alpha y=beta z=gamma', `got ${ios.axes.describe()}`);
check('the session produces usable travel', ios.travel > 500, `${ios.travel.toFixed(0)} px`);
console.log(`        iOS convention: ${ios.axes.describe()}, ${ios.travel.toFixed(0)} px travel`);

const spec = runSession({ encode: (w) => [w.z, w.x, w.y] });
check('a spec-convention phone resolves correctly',
  spec.axes.describe() === 'x=beta y=gamma z=alpha', `got ${spec.axes.describe()}`);
check('a spec-convention phone also produces travel', spec.travel > 500);
console.log(`        W3C convention: ${spec.axes.describe()}, ${spec.travel.toFixed(0)} px travel`);

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
