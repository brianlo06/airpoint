import Foundation

/// User- and device-tunable constants for the pointing model.
/// Defaults are documented in `docs/05-motion.md`; every value here is safe to change
/// without touching the algorithm.
public struct PointerTuning: Equatable, Sendable {
    /// Pixels per radian at 1.0× sensitivity. 2200 ≈ 38 px/degree: a 30° sweep crosses a
    /// 2560 px display exactly once.
    public var baseGainPxPerRad: Double = 2200

    /// User-facing sensitivity multiplier.
    public var sensitivity: Double = 1.0

    /// Soft dead zone, radians of per-frame angular change. Auto-tuned by calibration.
    /// 0.0008 rad at 100 Hz suppresses residual drift below ~4.6 deg/s. Jitter is
    /// One-Euro's job; this only has to stop slow creep.
    public var deadZoneRad: Double = 0.0008

    /// Angular change at which dead-zone compensation reaches unity gain.
    /// 0.006 rad/frame at 100 Hz is ~34 deg/s — an ordinary deliberate pointing speed.
    /// A ramp set far above real pointing speeds silently costs a third of your gain.
    public var deadZoneRampRad: Double = 0.006

    // Acceleration curve: gain × (1 + k · min((speed/ω₀)^p, cap))
    public var accelCoefficient: Double = 1.6      // k
    public var accelReferenceRadS: Double = 1.5    // ω₀
    public var accelExponent: Double = 1.3         // p
    public var accelCap: Double = 3.0              // cap

    /// Hard ceiling on cursor speed. Bounds the blast radius of a sensor glitch,
    /// a scheduling hiccup, or a hostile client.
    ///
    /// 4000 px/s proved too tight in practice: on a real phone the clamp bound on almost
    /// every fast flick (deltas pinned at exactly 80 px per frame at 50 Hz), which chops
    /// the end of a gesture and reads as jank. This still bounds a runaway, but sits above
    /// the range a hand actually produces.
    public var maxVelocityPxPerSec: Double = 9000

    /// Any gap longer than this means the sensor stream stopped (backgrounded tab, phone call,
    /// screen lock). The accumulated delta across the gap is meaningless and is discarded.
    public var maxSensorGap: TimeInterval = 0.250

    /// Stationary-detection thresholds for the bias estimator.
    public var stationaryGyroThresholdRadS: Double = 0.02
    public var stationaryAccelToleranceG: Double = 0.06
    public var stationaryWindow: TimeInterval = 0.4
    public var biasLearnRate: Double = 0.02

    public init() {}
}

public struct SensorSample: Sendable {
    /// Device→world attitude, gravity-referenced. On iOS this is
    /// `CMDeviceMotion.attitude.quaternion`; on the web it is built from `deviceorientation`.
    public var attitude: Quaternion
    /// Radians/second, device frame. Optional — used only for stationary detection.
    public var rotationRate: Vector3?
    /// Acceleration including gravity, in g. Optional — used only for stationary detection.
    public var accelerationG: Vector3?
    /// Monotonic seconds.
    public var timestamp: TimeInterval

    public init(attitude: Quaternion, rotationRate: Vector3? = nil,
                accelerationG: Vector3? = nil, timestamp: TimeInterval) {
        self.attitude = attitude
        self.rotationRate = rotationRate
        self.accelerationG = accelerationG
        self.timestamp = timestamp
    }
}

public struct PointerDelta: Equatable, Sendable {
    public var dx: Double
    public var dy: Double
    public var isZero: Bool { dx == 0 && dy == 0 }
    public static let zero = PointerDelta(dx: 0, dy: 0)
    public init(dx: Double, dy: Double) { self.dx = dx; self.dy = dy }
}

/// Turns a stream of device attitudes into pixel deltas.
///
/// Pure logic, no platform imports, no I/O — so it can be unit-tested against synthetic
/// motion and reused verbatim by the native iOS client. The JavaScript controller mirrors
/// this file; `Tests/RemoteKitTests/PointerPipelineTests.swift` is the shared contract.
public final class PointerPipeline {
    public private(set) var tuning: PointerTuning

    /// The device's pointing axis in the device frame: out the back of the phone.
    private static let pointingAxis = Vector3(0, 0, -1)

    private let yawFilter: MotionFilter
    private let pitchFilter: MotionFilter

    private var referenceAttitude: Quaternion = .identity
    private var previousYaw: Double?
    private var previousPitch: Double?
    private var previousTimestamp: TimeInterval?

    private var biasYaw: Double = 0
    private var biasPitch: Double = 0
    private var stationarySince: TimeInterval?

    private var accumulated = PointerDelta.zero
    private var lastDrain: TimeInterval?

    /// When false, samples are consumed to keep the attitude history warm but no motion is
    /// produced. This is the clutch: motion is only live while the user's thumb is down.
    public var isActive: Bool = true {
        didSet {
            guard isActive != oldValue else { return }
            // Re-seed on both edges: never emit motion that accumulated while disengaged.
            previousYaw = nil
            previousPitch = nil
            accumulated = .zero
            yawFilter.reset()
            pitchFilter.reset()
        }
    }

    public init(tuning: PointerTuning = PointerTuning(),
                makeFilter: () -> MotionFilter = { OneEuroFilter() }) {
        self.tuning = tuning
        self.yawFilter = makeFilter()
        self.pitchFilter = makeFilter()
    }

    public func update(tuning newTuning: PointerTuning) {
        tuning = newTuning
    }

    /// Captures a new reference attitude. Everything downstream is measured relative to this,
    /// so recentring is both "point here means centre" and "forget accumulated drift".
    public func recenter(to attitude: Quaternion) {
        referenceAttitude = attitude.normalized
        previousYaw = nil
        previousPitch = nil
        accumulated = .zero
        biasYaw = 0
        biasPitch = 0
        yawFilter.reset()
        pitchFilter.reset()
    }

    public func reset() {
        recenter(to: .identity)
        previousTimestamp = nil
        lastDrain = nil
        stationarySince = nil
    }

    /// Feeds an angular-rate sample: the preferred path.
    ///
    /// Pointing from integrated **gyroscope rate** rather than from the orientation
    /// quaternion, because on iOS the quaternion's yaw is magnetometer-referenced. Indoors,
    /// next to a laptop and a television, that heading is noisy and laggy — which shows up
    /// as horizontal movement being markedly worse than vertical, since pitch comes from
    /// clean gyro/accelerometer fusion and yaw does not. The gyro has no such asymmetry.
    ///
    /// Roll compensation is preserved by resolving the rate onto world axes derived from
    /// gravity, so the maths stays orientation-agnostic exactly as before:
    ///   yaw rate   = omega . gravityDown            (rotation about the world vertical)
    ///   pitch rate = omega . (gravityDown x aim)    (rotation about the world horizontal)
    ///
    /// - Parameters:
    ///   - rate: angular velocity in the device frame, radians/second.
    ///   - gravityDown: unit vector pointing along world "down", in the device frame.
    @discardableResult
    public func process(rate: Vector3, gravityDown: Vector3, timestamp: TimeInterval) -> PointerDelta {
        let previousT = previousTimestamp
        previousTimestamp = timestamp
        guard let previousT else { return .zero }

        let dt = timestamp - previousT
        guard dt > 0, dt <= tuning.maxSensorGap else { return .zero }
        guard isActive else { return .zero }
        guard rate.x.isFinite, rate.y.isFinite, rate.z.isFinite else { return .zero }

        let down = gravityDown.normalized
        guard down.length > 0.5 else { return .zero }   // no usable gravity reading

        // Aiming near-vertically makes the horizontal axis degenerate; hold the previous
        // frame rather than producing a wild value as the cross product collapses.
        let rightRaw = down.cross(Self.pointingAxis)
        guard rightRaw.length > 1e-3 else { return .zero }
        let right = rightRaw.normalized

        var dYaw = rate.dot(down) * dt
        var dPitch = rate.dot(right) * dt

        updateStationaryFromRate(rate: rate, timestamp: timestamp, dYaw: dYaw, dPitch: dPitch)
        dYaw -= biasYaw
        dPitch -= biasPitch

        return emit(dYaw: dYaw, dPitch: dPitch, dt: dt)
    }

    /// Feeds one attitude sample. Fallback for clients with no usable gyroscope stream.
    @discardableResult
    public func process(_ sample: SensorSample) -> PointerDelta {
        let previousT = previousTimestamp
        previousTimestamp = sample.timestamp

        guard let previousT else { return .zero }               // first sample: seed only
        let dt = sample.timestamp - previousT
        guard dt > 0, dt <= tuning.maxSensorGap else {
            // Sensor stall or resume. Drop the history so the next frame starts clean;
            // emitting the accumulated cross-gap delta is the "cursor teleports on unlock" bug.
            previousYaw = nil
            previousPitch = nil
            return .zero
        }

        // ②③ Relative rotation, then rotate the pointing axis into the reference frame.
        // Working with the rotated *axis* rather than Euler angles gives free roll
        // compensation: spinning the phone about its own pointing axis moves nothing.
        let relative = (referenceAttitude.conjugate * sample.attitude.normalized).normalized
        let w = relative.rotate(Self.pointingAxis)

        // ④ Yaw and pitch of the pointing vector. atan2 for pitch (not asin) keeps the
        // derivative bounded when aiming near straight up or down.
        let yaw = atan2(w.x, -w.z)
        let pitch = atan2(w.y, (w.x * w.x + w.z * w.z).squareRoot())

        guard let lastYaw = previousYaw, let lastPitch = previousPitch else {
            previousYaw = yaw
            previousPitch = pitch
            return .zero
        }

        // ⑤ Frame delta with wrap handling.
        var dYaw = Angle.wrapToPi(yaw - lastYaw)
        var dPitch = Angle.wrapToPi(pitch - lastPitch)
        previousYaw = yaw
        previousPitch = pitch

        guard isActive else { return .zero }

        // ⑥ Stationary bias estimation and removal.
        updateStationary(sample: sample, dYaw: dYaw, dPitch: dPitch)
        dYaw -= biasYaw
        dPitch -= biasPitch

        return emit(dYaw: dYaw, dPitch: dPitch, dt: dt)
    }

    /// Stages ⑦–⑨, shared by both input paths so the two can never drift apart.
    private func emit(dYaw rawYaw: Double, dPitch rawPitch: Double, dt: Double) -> PointerDelta {
        // ⑦ Speed-adaptive smoothing.
        var dYaw = yawFilter.filter(rawYaw, dt: dt)
        var dPitch = pitchFilter.filter(rawPitch, dt: dt)

        // ⑧ Soft dead zone.
        dYaw = Self.softDeadZone(dYaw, epsilon: tuning.deadZoneRad, ramp: tuning.deadZoneRampRad)
        dPitch = Self.softDeadZone(dPitch, epsilon: tuning.deadZoneRad, ramp: tuning.deadZoneRampRad)
        if dYaw == 0 && dPitch == 0 { return .zero }

        // ⑨ Gain and acceleration.
        let speed = (dYaw * dYaw + dPitch * dPitch).squareRoot() / dt
        let gain = tuning.baseGainPxPerRad * tuning.sensitivity * Self.accelerationFactor(speed: speed, tuning: tuning)

        // Screen y grows downward; pitch grows upward.
        let delta = PointerDelta(dx: gain * dYaw, dy: -gain * dPitch)
        accumulated.dx += delta.dx
        accumulated.dy += delta.dy
        return delta
    }

    private func updateStationaryFromRate(rate: Vector3, timestamp: TimeInterval,
                                          dYaw: Double, dPitch: Double) {
        guard rate.length < tuning.stationaryGyroThresholdRadS else {
            stationarySince = nil
            return
        }
        guard let since = stationarySince else {
            stationarySince = timestamp
            return
        }
        guard timestamp - since >= tuning.stationaryWindow else { return }
        let lambda = tuning.biasLearnRate
        biasYaw += lambda * (dYaw - biasYaw)
        biasPitch += lambda * (dPitch - biasPitch)
    }

    /// Returns the coalesced delta since the last drain, velocity-clamped, and clears it.
    /// Call at the send rate (60 Hz), not the sensor rate.
    public func drain(at now: TimeInterval) -> PointerMovePayload? {
        defer { lastDrain = now }
        guard !accumulated.isZero else { return nil }

        var delta = accumulated
        accumulated = .zero

        // ⑩ Velocity clamp.
        if let last = lastDrain {
            let elapsed = now - last
            if elapsed > 0 {
                let magnitude = (delta.dx * delta.dx + delta.dy * delta.dy).squareRoot()
                let velocity = magnitude / elapsed
                if velocity > tuning.maxVelocityPxPerSec, magnitude > 0 {
                    let scale = tuning.maxVelocityPxPerSec / velocity
                    delta.dx *= scale
                    delta.dy *= scale
                }
            }
        }

        guard delta.dx.isFinite, delta.dy.isFinite else { return nil }
        return PointerMovePayload(dx: delta.dx, dy: delta.dy)
    }

    // MARK: - Stages

    /// Soft dead zone, piecewise in three parts:
    ///   |x| <= eps    -> 0            (drift is suppressed entirely)
    ///   eps < |x| < M -> linear ramp  (no visible jump at the threshold)
    ///   |x| >= M      -> x            (fast motion is passed through at full gain)
    ///
    /// The ramp is what makes this "soft". A hard gate produces a visible jump the instant
    /// the threshold is crossed; a plain subtract-and-rescale either loses gain forever or
    /// overshoots above the knee. This form is continuous at both ends and exact above M.
    public static func softDeadZone(_ value: Double, epsilon: Double, ramp: Double) -> Double {
        guard value.isFinite else { return 0 }
        guard epsilon > 0 else { return value }
        let magnitude = abs(value)
        guard magnitude > epsilon else { return 0 }
        let knee = max(ramp, epsilon * 2)
        let sign: Double = value < 0 ? -1 : 1
        guard magnitude < knee else { return value }
        return sign * (magnitude - epsilon) * knee / (knee - epsilon)
    }

    /// Monotonically increasing in speed, saturating at `1 + k·cap`.
    public static func accelerationFactor(speed: Double, tuning: PointerTuning) -> Double {
        guard speed.isFinite, speed > 0, tuning.accelReferenceRadS > 0 else { return 1 }
        let normalized = speed / tuning.accelReferenceRadS
        let curved = min(pow(normalized, tuning.accelExponent), tuning.accelCap)
        return 1 + tuning.accelCoefficient * curved
    }

    private func updateStationary(sample: SensorSample, dYaw: Double, dPitch: Double) {
        guard let rate = sample.rotationRate, let accel = sample.accelerationG else {
            stationarySince = nil
            return
        }
        let gyroStill = rate.length < tuning.stationaryGyroThresholdRadS
        let accelStill = abs(accel.length - 1.0) < tuning.stationaryAccelToleranceG

        guard gyroStill && accelStill else {
            stationarySince = nil
            return
        }
        guard let since = stationarySince else {
            stationarySince = sample.timestamp
            return
        }
        // Only learn once the phone has been demonstrably still for a full window, so a
        // momentary pause mid-gesture cannot poison the estimate.
        guard sample.timestamp - since >= tuning.stationaryWindow else { return }
        let lambda = tuning.biasLearnRate
        biasYaw += lambda * (dYaw - biasYaw)
        biasPitch += lambda * (dPitch - biasPitch)
    }

    /// Exposed for tests and the troubleshooting panel.
    public var estimatedBias: (yaw: Double, pitch: Double) { (biasYaw, biasPitch) }
}
