import Foundation

/// A scalar smoothing filter over an irregularly-sampled signal.
///
/// The pipeline depends only on this protocol so the filter can be swapped — for a Kalman
/// or complementary filter later — without touching the pointing maths. That separation is
/// the entire point: motion quality is the thing most likely to need iteration.
public protocol MotionFilter: AnyObject {
    func filter(_ value: Double, dt: Double) -> Double
    func reset()
}

/// Classic exponential moving average with a fixed cutoff.
/// Kept as the baseline to A/B against One-Euro, and as a fallback if a device's
/// timestamps are too irregular for One-Euro's derivative estimate.
public final class ExponentialFilter: MotionFilter {
    private var cutoffHz: Double
    private var previous: Double?

    public init(cutoffHz: Double = 6.0) { self.cutoffHz = cutoffHz }

    public func filter(_ value: Double, dt: Double) -> Double {
        guard value.isFinite, dt > 0 else { return previous ?? 0 }
        guard let prev = previous else { previous = value; return value }
        let tau = 1.0 / (2 * .pi * cutoffHz)
        let alpha = dt / (tau + dt)
        let out = alpha * value + (1 - alpha) * prev
        previous = out
        return out
    }

    public func reset() { previous = nil }
}

/// One-Euro filter (Casiez, Roussel & Vogel, CHI 2012).
///
/// A fixed low-pass filter forces an unavoidable trade: a cutoff low enough to kill hand
/// tremor at rest adds visible lag during fast motion. One-Euro makes the cutoff a linear
/// function of the estimated speed, so it is aggressive when the hand is still and nearly
/// transparent when the hand is moving. It costs two floats of state and ~15 lines, which
/// makes it strictly cheaper than a Kalman filter and much better than a plain EMA.
public final class OneEuroFilter: MotionFilter {
    private let minCutoff: Double   // Hz — cutoff at zero speed; lower = less jitter, more lag
    private let beta: Double        // speed coefficient; higher = less lag at speed
    private let derivativeCutoff: Double

    private var lastValue: Double?
    private var lastFiltered: Double = 0
    private var lastDerivative: Double = 0

    public init(minCutoff: Double = 1.2, beta: Double = 0.012, derivativeCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    private func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2 * .pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }

    public func filter(_ value: Double, dt: Double) -> Double {
        guard value.isFinite, dt > 0 else { return lastFiltered }

        guard let previous = lastValue else {
            lastValue = value
            lastFiltered = value
            lastDerivative = 0
            return value
        }

        let rawDerivative = (value - previous) / dt
        let dAlpha = alpha(cutoff: derivativeCutoff, dt: dt)
        lastDerivative = dAlpha * rawDerivative + (1 - dAlpha) * lastDerivative

        let cutoff = minCutoff + beta * abs(lastDerivative)
        let a = alpha(cutoff: cutoff, dt: dt)
        lastFiltered = a * value + (1 - a) * lastFiltered
        lastValue = value
        return lastFiltered
    }

    public func reset() {
        lastValue = nil
        lastFiltered = 0
        lastDerivative = 0
    }
}
