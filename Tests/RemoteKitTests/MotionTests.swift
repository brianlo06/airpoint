import XCTest
@testable import RemoteKit

final class QuaternionTests: XCTestCase {

    func testConjugateProductIsIdentity() {
        let q = Quaternion.axisAngle(axis: Vector3(0.3, -0.5, 0.8), angle: 1.1)
        let r = (q * q.conjugate).normalized
        XCTAssertEqual(r.w, 1, accuracy: 1e-9)
        XCTAssertEqual(r.x, 0, accuracy: 1e-9)
        XCTAssertEqual(r.y, 0, accuracy: 1e-9)
        XCTAssertEqual(r.z, 0, accuracy: 1e-9)
    }

    func testRotationPreservesLength() {
        let q = Quaternion.axisAngle(axis: Vector3(1, 2, 3), angle: 0.7)
        let v = Vector3(0.2, -0.9, 0.4)
        XCTAssertEqual(q.rotate(v).length, v.length, accuracy: 1e-9)
    }

    /// Rotating the pointing axis by a known yaw must produce exactly that yaw.
    /// This pins the sign convention: +yaw about the device Y axis moves the cursor right.
    func testKnownYawProducesMatchingPointingAngle() {
        let yaw = 30.0 * .pi / 180
        let q = Quaternion.axisAngle(axis: Vector3(0, 1, 0), angle: yaw)
        let w = q.rotate(Vector3(0, 0, -1))
        XCTAssertEqual(atan2(w.x, -w.z), -yaw, accuracy: 1e-9)
    }

    /// A positive rotation about the device +X (right) axis tips the pointing vector upward,
    /// so the measured pitch is +theta. Pinning this sign is what stops an inverted-Y cursor.
    func testKnownPitchProducesMatchingPointingAngle() {
        let pitch = 20.0 * .pi / 180
        let q = Quaternion.axisAngle(axis: Vector3(1, 0, 0), angle: pitch)
        let w = q.rotate(Vector3(0, 0, -1))
        let measured = atan2(w.y, (w.x * w.x + w.z * w.z).squareRoot())
        XCTAssertEqual(measured, pitch, accuracy: 1e-9)
        XCTAssertGreaterThan(w.y, 0, "positive X rotation must aim above the horizon")
    }

    func testWrapToPi() {
        XCTAssertEqual(Angle.wrapToPi(0.1), 0.1, accuracy: 1e-12)
        XCTAssertEqual(Angle.wrapToPi(2 * .pi + 0.1), 0.1, accuracy: 1e-12)
        XCTAssertEqual(Angle.wrapToPi(-2 * .pi - 0.1), -0.1, accuracy: 1e-12)
        // The case that matters: a yaw that wrapped must not read as a ~2π jump.
        XCTAssertEqual(abs(Angle.wrapToPi(1.99 * .pi)), 0.01 * .pi, accuracy: 1e-12)
    }

    func testDeviceOrientationQuaternionIsUnit() {
        let q = Quaternion.fromDeviceOrientation(alphaDeg: 137, betaDeg: -42, gammaDeg: 61)
        XCTAssertEqual(q.norm, 1, accuracy: 1e-12)
    }

    func testDeviceOrientationIdentityAtZero() {
        let q = Quaternion.fromDeviceOrientation(alphaDeg: 0, betaDeg: 0, gammaDeg: 0)
        XCTAssertEqual(q.w, 1, accuracy: 1e-12)
    }
}

final class MotionFilterTests: XCTestCase {

    func testOneEuroConvergesToConstantInput() {
        let f = OneEuroFilter()
        var out = 0.0
        for _ in 0..<500 { out = f.filter(1.0, dt: 0.01) }
        XCTAssertEqual(out, 1.0, accuracy: 1e-3)
    }

    func testOneEuroSuppressesJitterAtRest() {
        // Synthetic hand tremor: zero-mean noise around a stationary signal.
        var generator = SeededGenerator(seed: 0xA1D2_D200_1234)
        let f = OneEuroFilter()
        var inputs: [Double] = []
        var outputs: [Double] = []
        for _ in 0..<2000 {
            let sample = generator.nextGaussian() * 0.002   // ~0.1° RMS
            inputs.append(sample)
            outputs.append(f.filter(sample, dt: 0.01))
        }
        let inVar = variance(Array(inputs.dropFirst(200)))
        let outVar = variance(Array(outputs.dropFirst(200)))
        // Success criterion from docs/06: residual variance under 25% of input.
        XCTAssertLessThan(outVar, inVar * 0.25, "One-Euro must remove most jitter at rest")
    }

    func testOneEuroTracksFastMotionWithLowLag() {
        // A fast sweep: the speed-adaptive cutoff should let it through nearly untouched.
        let f = OneEuroFilter()
        var last = 0.0
        for i in 0..<200 {
            last = f.filter(Double(i) * 0.01, dt: 0.01)
        }
        let ideal = 199 * 0.01
        XCTAssertEqual(last, ideal, accuracy: ideal * 0.15,
                       "adaptive cutoff must not lag badly during fast motion")
    }

    func testExponentialFilterConverges() {
        let f = ExponentialFilter(cutoffHz: 6)
        var out = 0.0
        for _ in 0..<500 { out = f.filter(2.0, dt: 0.01) }
        XCTAssertEqual(out, 2.0, accuracy: 1e-3)
    }

    func testFiltersIgnoreNonFiniteInput() {
        let f = OneEuroFilter()
        _ = f.filter(1.0, dt: 0.01)
        let out = f.filter(.nan, dt: 0.01)
        XCTAssertTrue(out.isFinite)
    }

    func testResetClearsState() {
        let f = OneEuroFilter()
        for _ in 0..<100 { _ = f.filter(5.0, dt: 0.01) }
        f.reset()
        XCTAssertEqual(f.filter(0.0, dt: 0.01), 0.0, accuracy: 1e-12)
    }

    private func variance(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
    }
}

final class PointerPipelineTests: XCTestCase {

    /// Feeds a pipeline a sequence of attitudes at a fixed rate and returns the total delta.
    private func sweep(_ pipeline: PointerPipeline,
                       attitudes: [Quaternion],
                       dt: Double = 0.01,
                       startTime: Double = 100) -> PointerDelta {
        var total = PointerDelta.zero
        for (i, q) in attitudes.enumerated() {
            let d = pipeline.process(SensorSample(attitude: q, timestamp: startTime + Double(i) * dt))
            total.dx += d.dx
            total.dy += d.dy
        }
        return total
    }

    private func yawSweep(from: Double, to: Double, steps: Int) -> [Quaternion] {
        (0...steps).map { i in
            let t = Double(i) / Double(steps)
            return Quaternion.axisAngle(axis: Vector3(0, 1, 0), angle: from + (to - from) * t)
        }
    }

    func testStillPhoneProducesNoMotion() {
        let pipeline = PointerPipeline()
        pipeline.recenter(to: .identity)
        let still = Array(repeating: Quaternion.identity, count: 500)
        let total = sweep(pipeline, attitudes: still)
        XCTAssertEqual(total.dx, 0, accuracy: 1e-9)
        XCTAssertEqual(total.dy, 0, accuracy: 1e-9)
    }

    func testYawSweepMovesCursorHorizontally() {
        var tuning = PointerTuning()
        tuning.accelCoefficient = 0        // isolate the base gain from the accel curve
        let pipeline = PointerPipeline(tuning: tuning)
        pipeline.recenter(to: .identity)

        // 10 degrees over 50 frames at 100 Hz = 0.5 s, an ordinary pointing speed.
        let total = sweep(pipeline, attitudes: yawSweep(from: 0, to: -10 * .pi / 180, steps: 50))
        XCTAssertGreaterThan(total.dx, 0, "yawing right must move the cursor right")
        XCTAssertEqual(total.dy, 0, accuracy: 1.0)

        // Expected ~ gain x 10 degrees, less filter warm-up and dead-zone losses.
        // The floor is the assertion that matters: losing more than 25% of a normal sweep
        // to filtering would feel sluggish.
        let ideal = tuning.baseGainPxPerRad * (10 * .pi / 180)
        XCTAssertGreaterThan(total.dx, ideal * 0.75, "sweep lost too much travel to filtering")
        XCTAssertLessThan(total.dx, ideal * 1.10)
    }

    func testPitchSweepMovesCursorVerticallyWithInvertedSign() {
        var tuning = PointerTuning()
        tuning.accelCoefficient = 0
        let pipeline = PointerPipeline(tuning: tuning)
        pipeline.recenter(to: .identity)

        // Aiming upward (positive rotation about +X) must move the cursor UP,
        // i.e. toward negative screen y.
        let attitudes = (0...50).map { i -> Quaternion in
            let angle = (10 * .pi / 180) * Double(i) / 50
            return Quaternion.axisAngle(axis: Vector3(1, 0, 0), angle: angle)
        }
        let total = sweep(pipeline, attitudes: attitudes)
        XCTAssertLessThan(total.dy, 0, "pitching up must move the cursor up (negative y)")
        XCTAssertEqual(total.dx, 0, accuracy: 1.0)
    }

    /// The portrait/landscape regression test. Rolling the phone about its own pointing axis
    /// changes the attitude completely but must not move the cursor at all.
    func testRollAboutPointingAxisProducesNoCursorMotion() {
        let pipeline = PointerPipeline()
        pipeline.recenter(to: .identity)
        let rolls = (0...200).map { i in
            Quaternion.axisAngle(axis: Vector3(0, 0, 1), angle: .pi * Double(i) / 200)
        }
        let total = sweep(pipeline, attitudes: rolls)
        XCTAssertEqual(total.dx, 0, accuracy: 1e-6, "roll must not produce horizontal motion")
        XCTAssertEqual(total.dy, 0, accuracy: 1e-6, "roll must not produce vertical motion")
    }

    /// A gap in the sensor stream (backgrounded tab, phone call, screen lock) must not
    /// be replayed as one huge jump when samples resume.
    func testSensorGapDoesNotTeleportTheCursor() {
        let pipeline = PointerPipeline()
        pipeline.recenter(to: .identity)

        _ = pipeline.process(SensorSample(attitude: .identity, timestamp: 100.0))
        _ = pipeline.process(SensorSample(attitude: .identity, timestamp: 100.01))

        // 5 seconds later, pointing 80° away.
        let far = Quaternion.axisAngle(axis: Vector3(0, 1, 0), angle: 80 * .pi / 180)
        let jump = pipeline.process(SensorSample(attitude: far, timestamp: 105.0))
        XCTAssertEqual(jump.dx, 0, "a delta accumulated across a sensor gap must be discarded")
        XCTAssertEqual(jump.dy, 0)

        // And the frame right after the gap must also be clean (history was reseeded).
        let next = pipeline.process(SensorSample(attitude: far, timestamp: 105.01))
        XCTAssertEqual(next.dx, 0, accuracy: 1e-9)
    }

    func testDeadZoneSuppressesSlowDrift() {
        let pipeline = PointerPipeline()
        pipeline.recenter(to: .identity)
        // 0.0005 rad/frame is deliberately just below the default dead zone.
        XCTAssertLessThan(0.0005, PointerTuning().deadZoneRad, "test premise")
        var angle = 0.0
        var total = PointerDelta.zero
        for i in 0..<2000 {
            angle += 0.0005
            let q = Quaternion.axisAngle(axis: Vector3(0, 1, 0), angle: angle)
            let d = pipeline.process(SensorSample(attitude: q, timestamp: 100 + Double(i) * 0.01))
            total.dx += d.dx
            total.dy += d.dy
        }
        XCTAssertEqual(total.dx, 0, accuracy: 1e-9, "sub-dead-zone drift must produce no motion")
    }

    func testSoftDeadZoneIsContinuousAtTheThreshold() {
        let eps = 0.0012, ramp = 0.05
        let justBelow = PointerPipeline.softDeadZone(eps * 0.999, epsilon: eps, ramp: ramp)
        let justAbove = PointerPipeline.softDeadZone(eps * 1.001, epsilon: eps, ramp: ramp)
        XCTAssertEqual(justBelow, 0)
        XCTAssertLessThan(abs(justAbove), eps * 0.01,
                          "crossing the dead zone must not produce a visible jump")
    }

    func testSoftDeadZonePreservesSign() {
        XCTAssertLessThan(PointerPipeline.softDeadZone(-0.01, epsilon: 0.001, ramp: 0.05), 0)
        XCTAssertGreaterThan(PointerPipeline.softDeadZone(0.01, epsilon: 0.001, ramp: 0.05), 0)
    }

    func testAccelerationCurveIsMonotonicAndBounded() {
        let tuning = PointerTuning()
        var previous = 0.0
        for i in 0...200 {
            let speed = Double(i) * 0.1
            let factor = PointerPipeline.accelerationFactor(speed: speed, tuning: tuning)
            XCTAssertGreaterThanOrEqual(factor, previous - 1e-12, "acceleration must be monotonic")
            XCTAssertLessThanOrEqual(factor, 1 + tuning.accelCoefficient * tuning.accelCap + 1e-9)
            previous = factor
        }
        XCTAssertEqual(PointerPipeline.accelerationFactor(speed: 0, tuning: tuning), 1)
    }

    func testVelocityIsClampedOnDrain() {
        var tuning = PointerTuning()
        tuning.maxVelocityPxPerSec = 1000
        let pipeline = PointerPipeline(tuning: tuning)
        pipeline.recenter(to: .identity)

        // Establish a drain baseline, then produce a large delta over a short window.
        _ = pipeline.drain(at: 100.0)
        _ = sweep(pipeline, attitudes: yawSweep(from: 0, to: -60 * .pi / 180, steps: 50),
                  dt: 0.001, startTime: 100.0)
        guard let payload = pipeline.drain(at: 100.05) else {
            return XCTFail("expected a delta")
        }
        let magnitude = (payload.dx * payload.dx + payload.dy * payload.dy).squareRoot()
        XCTAssertLessThanOrEqual(magnitude / 0.05, tuning.maxVelocityPxPerSec + 1e-6)
    }

    func testClutchDisengagedProducesNoMotion() {
        let pipeline = PointerPipeline()
        pipeline.recenter(to: .identity)
        pipeline.isActive = false
        let total = sweep(pipeline, attitudes: yawSweep(from: 0, to: -30 * .pi / 180, steps: 100))
        XCTAssertEqual(total.dx, 0, accuracy: 1e-12)
        XCTAssertNil(pipeline.drain(at: 200))
    }

    func testReengagingTheClutchDoesNotReplayMotion() {
        let pipeline = PointerPipeline()
        pipeline.recenter(to: .identity)
        pipeline.isActive = false
        _ = sweep(pipeline, attitudes: yawSweep(from: 0, to: -30 * .pi / 180, steps: 100))
        pipeline.isActive = true

        // First sample after re-engaging must be a seed, not a 30° jump.
        let far = Quaternion.axisAngle(axis: Vector3(0, 1, 0), angle: -30 * .pi / 180)
        let d = pipeline.process(SensorSample(attitude: far, timestamp: 200.0))
        XCTAssertEqual(d.dx, 0, accuracy: 1e-12)
    }

    func testSensitivityScalesLinearly() {
        func totalFor(sensitivity: Double) -> Double {
            var tuning = PointerTuning()
            tuning.sensitivity = sensitivity
            tuning.accelCoefficient = 0
            tuning.deadZoneRad = 0
            let pipeline = PointerPipeline(tuning: tuning)
            pipeline.recenter(to: .identity)
            return sweep(pipeline, attitudes: yawSweep(from: 0, to: -10 * .pi / 180, steps: 50)).dx
        }
        let single = totalFor(sensitivity: 1.0)
        let double = totalFor(sensitivity: 2.0)
        XCTAssertEqual(double, single * 2, accuracy: abs(single) * 0.02)
    }

    func testDrainReturnsNilWhenNothingAccumulated() {
        let pipeline = PointerPipeline()
        XCTAssertNil(pipeline.drain(at: 100))
    }

    func testDrainClearsAccumulator() {
        var tuning = PointerTuning()
        tuning.accelCoefficient = 0
        let pipeline = PointerPipeline(tuning: tuning)
        pipeline.recenter(to: .identity)
        _ = sweep(pipeline, attitudes: yawSweep(from: 0, to: -10 * .pi / 180, steps: 50))
        XCTAssertNotNil(pipeline.drain(at: 200))
        XCTAssertNil(pipeline.drain(at: 200.016), "the accumulator must be empty after a drain")
    }

    func testRecenterClearsPendingMotion() {
        let pipeline = PointerPipeline()
        pipeline.recenter(to: .identity)
        _ = sweep(pipeline, attitudes: yawSweep(from: 0, to: -20 * .pi / 180, steps: 100))
        pipeline.recenter(to: .identity)
        XCTAssertNil(pipeline.drain(at: 300))
    }

    func testStationaryPhoneTrainsBiasEstimator() {
        let pipeline = PointerPipeline()
        pipeline.recenter(to: .identity)
        // A perfectly still phone: 1 g down, no rotation, but a constant angular creep
        // as if the gyro had a small bias baked into the attitude.
        var angle = 0.0
        for i in 0..<3000 {
            angle += 0.0002
            let q = Quaternion.axisAngle(axis: Vector3(0, 1, 0), angle: angle)
            pipeline.process(SensorSample(
                attitude: q,
                rotationRate: Vector3(0, 0.001, 0),
                accelerationG: Vector3(0, 0, -1),
                timestamp: 100 + Double(i) * 0.01))
        }
        XCTAssertNotEqual(pipeline.estimatedBias.yaw, 0,
                          "a demonstrably still phone must train the bias estimator")
    }

    func testMovingPhoneDoesNotTrainBiasEstimator() {
        let pipeline = PointerPipeline()
        pipeline.recenter(to: .identity)
        var angle = 0.0
        for i in 0..<1000 {
            angle += 0.01                       // clearly moving
            let q = Quaternion.axisAngle(axis: Vector3(0, 1, 0), angle: angle)
            pipeline.process(SensorSample(
                attitude: q,
                rotationRate: Vector3(0, 1.0, 0),
                accelerationG: Vector3(0, 0, -1),
                timestamp: 100 + Double(i) * 0.01))
        }
        XCTAssertEqual(pipeline.estimatedBias.yaw, 0,
                       "real motion must never poison the bias estimate")
    }
}

// MARK: - Test support

/// Deterministic PRNG so filter-quality assertions are reproducible in CI.
struct SeededGenerator {
    private var state: UInt64
    private var spare: Double?

    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func nextUniform() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }

    /// Box–Muller.
    mutating func nextGaussian() -> Double {
        if let value = spare { spare = nil; return value }
        var u = nextUniform()
        if u < 1e-12 { u = 1e-12 }
        let v = nextUniform()
        let r = (-2 * log(u)).squareRoot()
        spare = r * sin(2 * .pi * v)
        return r * cos(2 * .pi * v)
    }
}

/// The gyro-rate path, which is the one a real phone uses.
///
/// These pin the sign conventions and the roll compensation. They exist because the
/// quaternion path shipped with an asymmetry that only a physical device exposed: on iOS
/// the attitude's yaw is magnetometer-derived and markedly worse than its pitch, so
/// horizontal pointing felt worse than vertical. Driving from angular rate removes the
/// magnetometer entirely, and these tests are what keep the axes honest.
final class AngularRatePointerTests: XCTestCase {

    /// Phone held upright, screen toward the user, aiming away: device -Z is forward,
    /// +Y is world up, so world "down" in device coordinates is -Y.
    private let uprightGravityDown = Vector3(0, -1, 0)

    private func run(rate: Vector3, gravityDown: Vector3, seconds: Double = 0.5,
                     hz: Double = 60, tuning: PointerTuning? = nil) -> PointerDelta {
        var config = tuning ?? PointerTuning()
        config.accelCoefficient = 0        // isolate the base gain
        let pipeline = PointerPipeline(tuning: config)
        pipeline.isActive = true

        let dt = 1 / hz
        var t = 100.0
        var total = PointerDelta.zero
        _ = pipeline.process(rate: rate, gravityDown: gravityDown, timestamp: t)
        for _ in 0..<Int(seconds * hz) {
            t += dt
            let d = pipeline.process(rate: rate, gravityDown: gravityDown, timestamp: t)
            total.dx += d.dx
            total.dy += d.dy
        }
        return total
    }

    func testTurningRightMovesTheCursorRight() {
        // Turning right is a positive rotation about the world "down" axis.
        let rate = Vector3(0, -0.5, 0)          // 0.5 rad/s about -Y == about down
        let total = run(rate: rate, gravityDown: uprightGravityDown)
        XCTAssertGreaterThan(total.dx, 0, "turning right must move the cursor right")
        XCTAssertEqual(total.dy, 0, accuracy: 1.0)
    }

    func testTurningLeftMovesTheCursorLeft() {
        let total = run(rate: Vector3(0, 0.5, 0), gravityDown: uprightGravityDown)
        XCTAssertLessThan(total.dx, 0)
    }

    func testAimingUpMovesTheCursorUp() {
        // Positive rotation about the device +X (right) axis tips the aim upward.
        let total = run(rate: Vector3(0.5, 0, 0), gravityDown: uprightGravityDown)
        XCTAssertLessThan(total.dy, 0, "aiming up must move the cursor up (negative screen y)")
        XCTAssertEqual(total.dx, 0, accuracy: 1.0)
    }

    func testTravelMatchesTheIntegratedAngle() {
        var tuning = PointerTuning()
        tuning.accelCoefficient = 0
        tuning.deadZoneRad = 0
        let total = run(rate: Vector3(0, -0.5, 0), gravityDown: uprightGravityDown,
                        seconds: 1.0, tuning: tuning)
        // 0.5 rad/s for 1 s = 0.5 rad; at 2200 px/rad that is 1100 px.
        XCTAssertEqual(total.dx, 1100, accuracy: 1100 * 0.1)
    }

    /// The whole point of resolving onto gravity-derived axes: holding the phone rolled
    /// 90 degrees must not swap or tilt the cursor axes.
    func testRollDoesNotChangeTheMapping() {
        let upright = run(rate: Vector3(0, -0.5, 0), gravityDown: uprightGravityDown)

        // Phone rolled so that device +X now points at the floor: world down is +X in
        // device coordinates. "Turn right" is always a rotation about world down, so in
        // this grip the same physical gesture is a rotation about device +X.
        let rolled = run(rate: Vector3(0.5, 0, 0), gravityDown: Vector3(1, 0, 0))

        XCTAssertGreaterThan(rolled.dx, 0, "turning right must still move the cursor right when rolled")
        XCTAssertEqual(rolled.dx, upright.dx, accuracy: abs(upright.dx) * 0.05,
                       "the same physical gesture must produce the same travel in any grip")
        XCTAssertEqual(rolled.dy, 0, accuracy: 1.0)
    }

    func testStillPhoneProducesNothing() {
        let total = run(rate: Vector3(0, 0, 0), gravityDown: uprightGravityDown)
        XCTAssertEqual(total.dx, 0, accuracy: 1e-9)
        XCTAssertEqual(total.dy, 0, accuracy: 1e-9)
    }

    func testReleasedClutchProducesNothing() {
        let pipeline = PointerPipeline()
        pipeline.isActive = false
        var t = 100.0
        var total = 0.0
        for _ in 0..<60 {
            t += 1.0 / 60
            total += abs(pipeline.process(rate: Vector3(0, -0.5, 0),
                                          gravityDown: uprightGravityDown, timestamp: t).dx)
        }
        XCTAssertEqual(total, 0)
    }

    func testSensorGapIsDiscarded() {
        let pipeline = PointerPipeline()
        pipeline.isActive = true
        _ = pipeline.process(rate: Vector3(0, -0.5, 0), gravityDown: uprightGravityDown, timestamp: 100)
        let afterGap = pipeline.process(rate: Vector3(0, -0.5, 0),
                                        gravityDown: uprightGravityDown, timestamp: 105)
        XCTAssertEqual(afterGap.dx, 0, "a rate sample across a 5 s gap must not integrate")
    }

    func testMissingGravityIsIgnored() {
        let pipeline = PointerPipeline()
        pipeline.isActive = true
        _ = pipeline.process(rate: Vector3(0, -0.5, 0), gravityDown: .init(0, 0, 0), timestamp: 100)
        let d = pipeline.process(rate: Vector3(0, -0.5, 0), gravityDown: .init(0, 0, 0), timestamp: 100.016)
        XCTAssertEqual(d.dx, 0, "no usable gravity reading must produce no motion, not garbage")
    }

    func testAimingStraightDownDoesNotExplode() {
        // Gravity parallel to the aim axis makes the horizontal axis degenerate.
        let pipeline = PointerPipeline()
        pipeline.isActive = true
        _ = pipeline.process(rate: Vector3(0.5, 0, 0), gravityDown: Vector3(0, 0, -1), timestamp: 100)
        let d = pipeline.process(rate: Vector3(0.5, 0, 0), gravityDown: Vector3(0, 0, -1), timestamp: 100.016)
        XCTAssertTrue(d.dx.isFinite && d.dy.isFinite)
        XCTAssertEqual(d.dx, 0)
    }
}
