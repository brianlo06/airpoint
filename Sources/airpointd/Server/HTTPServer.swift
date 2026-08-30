import Foundation
import Network
import RemoteKit

/// A minimal HTTP/1.1 request, parsed only as far as this server needs.
struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]        // lowercased keys

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    var isWebSocketUpgrade: Bool {
        header("upgrade")?.lowercased() == "websocket"
            && (header("connection")?.lowercased().contains("upgrade") ?? false)
    }

    /// Parses a complete request head. Returns nil if the terminator has not arrived yet.
    /// Throws only for input that can never become valid.
    static func parse(_ buffer: Data) throws -> (request: HTTPRequest, headLength: Int)? {
        guard let terminator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            // Bound the head so a client cannot stream headers forever and exhaust memory.
            guard buffer.count < 16 * 1024 else { throw ParseError.headTooLarge }
            return nil
        }
        let headData = buffer[buffer.startIndex..<terminator.lowerBound]
        guard let head = String(data: headData, encoding: .utf8) else { throw ParseError.notUTF8 }

        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw ParseError.malformedRequestLine }

        let requestLine = lines.removeFirst().split(separator: " ", maxSplits: 2).map(String.init)
        guard requestLine.count >= 2 else { throw ParseError.malformedRequestLine }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            headers[name] = value
        }

        let request = HTTPRequest(method: requestLine[0].uppercased(), path: requestLine[1], headers: headers)
        return (request, terminator.upperBound - buffer.startIndex)
    }

    enum ParseError: Error {
        case headTooLarge, notUTF8, malformedRequestLine
    }
}

/// Serves the controller PWA.
///
/// Files are resolved from a fixed allowlist rather than by joining the request path to a
/// directory. There is no path to traverse if there is no path arithmetic — this removes an
/// entire bug class rather than trying to filter `..` correctly.
enum StaticFiles {

    struct Asset {
        let data: Data
        let contentType: String
    }

    private static let allowlist: [String: String] = [
        "/":                        "index.html",
        "/index.html":              "index.html",
        "/app.css":                 "app.css",
        "/app.js":                  "app.js",
        "/motion.js":               "motion.js",
        "/typing.js":               "typing.js",
        "/manifest.webmanifest":    "manifest.webmanifest",
    ]

    private static let contentTypes: [String: String] = [
        "html": "text/html; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "webmanifest": "application/manifest+json; charset=utf-8",
    ]

    static func asset(for path: String) -> Asset? {
        // Strip any query string; the controller reads its parameters from the URL fragment,
        // which never reaches the server at all.
        let cleanPath = path.components(separatedBy: "?").first ?? path
        guard let filename = allowlist[cleanPath] else { return nil }
        guard let url = Bundle.module.url(forResource: filename, withExtension: nil, subdirectory: "web"),
              let data = try? Data(contentsOf: url) else {
            Log.error("controller asset '\(filename)' is missing from the bundle")
            return nil
        }
        let ext = (filename as NSString).pathExtension
        return Asset(data: data, contentType: contentTypes[ext] ?? "application/octet-stream")
    }

    /// Response headers applied to every asset.
    ///
    /// The CSP is the second half of the defence against a hostile page (threat T4): even if
    /// something were injected into the controller, it could not load external code or open a
    /// socket to anywhere but this origin. `Permissions-Policy` is required for the motion
    /// sensors to be readable at all in Chrome.
    static func securityHeaders() -> [String: String] {
        [
            "Content-Security-Policy":
                "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
                + "connect-src 'self' wss:; manifest-src 'self'; base-uri 'none'; form-action 'none'; "
                + "frame-ancestors 'none'",
            "Permissions-Policy": "gyroscope=(self), accelerometer=(self), magnetometer=(self)",
            "X-Content-Type-Options": "nosniff",
            "Referrer-Policy": "no-referrer",
            "Cache-Control": "no-store",
        ]
    }

    static func response(status: Int, reason: String, body: Data,
                         contentType: String, extraHeaders: [String: String] = [:]) -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        for (name, value) in securityHeaders().merging(extraHeaders, uniquingKeysWith: { _, new in new }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }

    static func errorResponse(status: Int, reason: String, message: String) -> Data {
        response(status: status, reason: reason, body: Data(message.utf8),
                 contentType: "text/plain; charset=utf-8")
    }
}

/// Decides whether an HTTP upgrade request is allowed to become a control session.
///
/// This is the DNS-rebinding and cross-origin defence. A malicious page the user visits on
/// any device can guess the LAN address and open a WebSocket; these two checks are what stop
/// it from getting as far as the pairing exchange.
struct OriginPolicy {
    let allowedHosts: Set<String>
    let port: UInt16

    init(subjectNames: [String], port: UInt16) {
        self.allowedHosts = Set(subjectNames.map { $0.lowercased() })
        self.port = port
    }

    enum Decision {
        case allow
        case reject(String)
    }

    func evaluate(_ request: HTTPRequest) -> Decision {
        // Host: rejecting an unexpected Host is the DNS-rebinding defence. An attacker's
        // domain resolving to our LAN IP still carries their name in the Host header.
        guard let host = request.header("host")?.lowercased() else {
            return .reject("missing Host header")
        }
        guard allowedHosts.contains(hostname(from: host)) else {
            return .reject("Host '\(host)' is not one of this server's names")
        }

        // Origin: browsers always send it on a WebSocket handshake and cannot forge it.
        // A native client sends none, which is why absence is allowed.
        if let origin = request.header("origin")?.lowercased() {
            guard let components = URLComponents(string: origin),
                  let originHost = components.host?.lowercased(),
                  allowedHosts.contains(originHost),
                  components.scheme == "https" else {
                return .reject("Origin '\(origin)' is not permitted")
            }
        }
        return .allow
    }

    /// Strips the port, handling bracketed IPv6 literals.
    private func hostname(from host: String) -> String {
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            return String(host[host.index(after: host.startIndex)..<close])
        }
        guard let colon = host.lastIndex(of: ":") else { return host }
        return String(host[host.startIndex..<colon])
    }
}
