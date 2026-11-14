import Foundation
import RavenTunnelC

/// Swift face of Raven Tunnel, the WireGuard tunnel in the Go archive. One
/// tunnel at a time; Raven reaches it as a SOCKS5 proxy on loopback.
enum RavenTunnel {
    struct Summary: Equatable {
        var endpoint: String
        var address: String
    }

    /// Validates a wg-quick config without starting anything.
    static func describe(_ config: String) -> Result<Summary, TunnelError> {
        var err: UnsafeMutablePointer<CChar>?
        let out = config.withCString { RavenTunnelDescribe(UnsafeMutablePointer(mutating: $0), &err) }
        if let out {
            defer { RavenTunnelFree(out) }
            let parts = String(cString: out).split(separator: "|", maxSplits: 1).map(String.init)
            return .success(Summary(endpoint: parts.first ?? "", address: parts.count > 1 ? parts[1] : ""))
        }
        return .failure(TunnelError(take(err) ?? "Invalid configuration."))
    }

    /// Starts the tunnel; returns the loopback SOCKS5 port.
    static func start(_ config: String, user: String, password: String) -> Result<UInt16, TunnelError> {
        var err: UnsafeMutablePointer<CChar>?
        let port = config.withCString { c in
            user.withCString { u in
                password.withCString { p in
                    RavenTunnelStart(UnsafeMutablePointer(mutating: c), UnsafeMutablePointer(mutating: u),
                                     UnsafeMutablePointer(mutating: p), &err)
                }
            }
        }
        if port > 0 { return .success(UInt16(port)) }
        return .failure(TunnelError(take(err) ?? "The tunnel did not start."))
    }

    static func stop() { RavenTunnelStop() }

    /// The latest WireGuard handshake, or nil before the first one.
    static var lastHandshake: Date? {
        let t = RavenTunnelLastHandshake()
        return t > 0 ? Date(timeIntervalSince1970: TimeInterval(t)) : nil
    }

    /// Two WireGuard peers on loopback, traffic through the SOCKS5 endpoint. nil on success.
    static func selfTest() -> String? { take(RavenTunnelSelfTest()) }

    private static func take(_ p: UnsafeMutablePointer<CChar>?) -> String? {
        guard let p else { return nil }
        defer { RavenTunnelFree(p) }
        return String(cString: p)
    }

    struct TunnelError: Error, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
