import Foundation

public struct Vector3: Equatable, Sendable {
    public var x, y, z: Double
    public init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }

    public var length: Double { (x * x + y * y + z * z).squareRoot() }
    public var normalized: Vector3 {
        let l = length
        return l > 0 ? Vector3(x / l, y / l, z / l) : self
    }
}

/// Minimal unit-quaternion maths. Deliberately hand-written rather than pulled from a
/// dependency: this is four functions, and it has to compile for both macOS and iOS with
/// no third-party package in the trust path of a remote-input tool.
public struct Quaternion: Equatable, Sendable {
    public var w, x, y, z: Double

    public init(w: Double, x: Double, y: Double, z: Double) {
        self.w = w; self.x = x; self.y = y; self.z = z
    }

    public static let identity = Quaternion(w: 1, x: 0, y: 0, z: 0)

    public var conjugate: Quaternion { Quaternion(w: w, x: -x, y: -y, z: -z) }

    public var norm: Double { (w * w + x * x + y * y + z * z).squareRoot() }

    public var normalized: Quaternion {
        let n = norm
        guard n > 1e-12 else { return .identity }
        return Quaternion(w: w / n, x: x / n, y: y / n, z: z / n)
    }

    public static func * (a: Quaternion, b: Quaternion) -> Quaternion {
        Quaternion(
            w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
            x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w
        )
    }

    /// Rotates `v` by this quaternion: v' = q ⊗ v ⊗ q*.
    /// Uses the expanded form (no intermediate quaternion allocation) because this runs
    /// once per sensor sample.
    public func rotate(_ v: Vector3) -> Vector3 {
        let u = Vector3(x, y, z)
        let uv = Vector3(u.y * v.z - u.z * v.y,
                         u.z * v.x - u.x * v.z,
                         u.x * v.y - u.y * v.x)
        let uuv = Vector3(u.y * uv.z - u.z * uv.y,
                          u.z * uv.x - u.x * uv.z,
                          u.x * uv.y - u.y * uv.x)
        return Vector3(v.x + 2 * (w * uv.x + uuv.x),
                       v.y + 2 * (w * uv.y + uuv.y),
                       v.z + 2 * (w * uv.z + uuv.z))
    }

    /// Builds a quaternion from the browser `deviceorientation` angles.
    ///
    /// The W3C spec defines the device attitude as the intrinsic rotation Z-X'-Y'' by
    /// (alpha, beta, gamma) in degrees. Getting this order wrong is the single most common
    /// bug in web motion code and produces a cursor that behaves correctly only when the
    /// phone is held perfectly flat.
    public static func fromDeviceOrientation(alphaDeg: Double, betaDeg: Double, gammaDeg: Double) -> Quaternion {
        let a = alphaDeg * .pi / 180 * 0.5
        let b = betaDeg  * .pi / 180 * 0.5
        let g = gammaDeg * .pi / 180 * 0.5

        let (ca, sa) = (cos(a), sin(a))
        let (cb, sb) = (cos(b), sin(b))
        let (cg, sg) = (cos(g), sin(g))

        return Quaternion(
            w: ca * cb * cg - sa * sb * sg,
            x: ca * sb * cg - sa * cb * sg,
            y: ca * cb * sg + sa * sb * cg,
            z: sa * cb * cg + ca * sb * sg
        ).normalized
    }

    /// Quaternion for a rotation of `angle` radians about a unit axis.
    public static func axisAngle(axis: Vector3, angle: Double) -> Quaternion {
        let a = axis.normalized
        let h = angle * 0.5
        let s = sin(h)
        return Quaternion(w: cos(h), x: a.x * s, y: a.y * s, z: a.z * s)
    }
}

public enum Angle {
    /// Wraps to (-π, π]. Without this, a yaw crossing ±π produces a single ~2π delta,
    /// which is the "cursor flies across the screen once per rotation" bug.
    public static func wrapToPi(_ a: Double) -> Double {
        guard a.isFinite else { return 0 }
        return a - 2 * .pi * (a / (2 * .pi)).rounded()
    }
}
