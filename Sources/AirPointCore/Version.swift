import Foundation

/// AirPoint's own versions, kept out of `RemoteServer` so the library carries no product
/// identity. `controllerVersion` is compared against what the phone reports, which is how a
/// stale page held in a backgrounded browser tab gets noticed.
public enum AirPoint {
    public static let version = "0.2.0"
    public static let controllerVersion = "0.2.0"
}
