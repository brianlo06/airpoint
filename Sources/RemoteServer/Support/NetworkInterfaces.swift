import Foundation

/// Enumerates the machine's live network interfaces.
///
/// Used for two things: deciding what is safe to bind, and building the certificate's
/// SAN list so the phone can reach the Mac by IP or by `<hostname>.local` without a
/// certificate name mismatch on top of the self-signed warning.
public enum NetworkInterfaces {

    public struct Interface {
        public let name: String
        public let address: String
        public let isIPv4: Bool
        public let isPrivate: Bool
        public let isLoopback: Bool
    }

    public static func all() -> [Interface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var interfaces: [Interface] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP != 0, let sockaddr = pointer.pointee.ifa_addr else { continue }

            let family = sockaddr.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(sockaddr, socklen_t(sockaddr.pointee.sa_len),
                                     &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            guard result == 0 else { continue }

            // Strip the zone index from link-local IPv6 (fe80::1%en0) — it is not valid
            // in a certificate SAN or a URL host.
            let address = String(cString: host).components(separatedBy: "%").first ?? ""
            guard !address.isEmpty else { continue }

            let name = String(cString: pointer.pointee.ifa_name)
            let isIPv4 = family == UInt8(AF_INET)
            interfaces.append(Interface(
                name: name,
                address: address,
                isIPv4: isIPv4,
                isPrivate: isPrivateAddress(address, isIPv4: isIPv4),
                isLoopback: flags & IFF_LOOPBACK != 0
            ))
        }
        return interfaces
    }

    /// IPv4 addresses reachable on a home LAN, most-likely-primary first.
    /// `en0` is Wi-Fi on every Mac shipped this decade, so it sorts to the front.
    public static func privateIPv4Addresses() -> [String] {
        all()
            .filter { $0.isIPv4 && $0.isPrivate && !$0.isLoopback }
            .sorted { lhs, rhs in
                if lhs.name == rhs.name { return lhs.address < rhs.address }
                if lhs.name == "en0" { return true }
                if rhs.name == "en0" { return false }
                return lhs.name < rhs.name
            }
            .map(\.address)
    }

    public static func isPrivateAddress(_ address: String, isIPv4: Bool) -> Bool {
        if !isIPv4 {
            let lower = address.lowercased()
            // Unique-local (fc00::/7) and link-local (fe80::/10), plus loopback.
            return lower.hasPrefix("fc") || lower.hasPrefix("fd")
                || lower.hasPrefix("fe8") || lower.hasPrefix("fe9")
                || lower.hasPrefix("fea") || lower.hasPrefix("feb")
                || lower == "::1"
        }
        let parts = address.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _):                       return true    // 10.0.0.0/8
        case (127, _):                      return true    // loopback
        case (192, 168):                    return true    // 192.168.0.0/16
        case (169, 254):                    return true    // link-local
        case (172, let second) where (16...31).contains(second): return true  // 172.16.0.0/12
        default:                            return false
        }
    }

    /// The `.local` name the phone can use instead of an IP, so a DHCP lease change
    /// does not break a trusted device's saved connection.
    public static func localHostName() -> String? {
        let name = ProcessInfo.processInfo.hostName
        guard !name.isEmpty else { return nil }
        return name.hasSuffix(".local") ? name : name + ".local"
    }
}
