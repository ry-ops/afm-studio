import Foundation
import Darwin

/// Keeps the model's `fetch_url` tool on the public internet. A page the model reads can tell it
/// to fetch another URL, so without this check a prompt injection could reach your router,
/// other machines on your network, local services or cloud metadata endpoints.
///
/// Set `AFM_FETCH_ALLOW_PRIVATE=1` to allow private and local addresses (for example a homelab).
public enum NetGuard {
    public static var allowPrivate: Bool { ProcessInfo.processInfo.environment["AFM_FETCH_ALLOW_PRIVATE"] == "1" }

    /// Throws unless `url` is http(s) and every address its host resolves to is public.
    public static func check(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw AFMError(code: "bad_url", message: "Only http and https URLs can be fetched.")
        }
        guard let rawHost = url.host, !rawHost.isEmpty else { throw AFMError(code: "bad_url", message: "That URL has no host.") }
        if allowPrivate { return }
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal") || !host.contains(".") && !host.contains(":") {
            throw blocked(rawHost)
        }
        let addrs = resolve(host)
        guard !addrs.isEmpty else { throw AFMError(code: "dns", message: "Couldn't resolve \(rawHost).") }
        if addrs.contains(where: isPrivate) { throw blocked(rawHost) }
    }

    static func blocked(_ host: String) -> AFMError {
        AFMError(code: "private_address", message: "\(host) is a local or private address, so fetch_url won't open it.",
                 suggestion: "Set AFM_FETCH_ALLOW_PRIVATE=1 to allow local network fetches.")
    }

    /// Every address the host resolves to, as raw bytes (4 for IPv4, 16 for IPv6).
    static func resolve(_ host: String) -> [[UInt8]] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return [] }
        defer { freeaddrinfo(first) }
        var out: [[UInt8]] = []
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            if ai.pointee.ai_family == AF_INET, let sa = ai.pointee.ai_addr {
                sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { s in
                    var a = s.pointee.sin_addr
                    out.append(withUnsafeBytes(of: &a) { Array($0) })
                }
            } else if ai.pointee.ai_family == AF_INET6, let sa = ai.pointee.ai_addr {
                sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { s in
                    var a = s.pointee.sin6_addr
                    out.append(withUnsafeBytes(of: &a) { Array($0) })
                }
            }
            p = ai.pointee.ai_next
        }
        return out
    }

    /// Loopback, private, link-local, carrier-grade NAT, multicast, unspecified and similar ranges.
    public static func isPrivate(_ b: [UInt8]) -> Bool {
        if b.count == 4 {
            switch (b[0], b[1]) {
            case (0, _), (10, _), (127, _), (169, 254), (192, 168), (198, 18), (198, 19): return true
            case (172, 16...31), (100, 64...127): return true
            case (192, 0) where b[2] == 0 || b[2] == 2: return true
            default: return b[0] >= 224
            }
        }
        guard b.count == 16 else { return true }
        if b.allSatisfy({ $0 == 0 }) || b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true } // :: and ::1
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff { return isPrivate(Array(b[12...])) } // ::ffff:a.b.c.d
        if b[0..<12].allSatisfy({ $0 == 0 }) { return isPrivate(Array(b[12...])) } // ::a.b.c.d (deprecated)
        if b[0] == 0x64 && b[1] == 0xff && b[2] == 0x9b { return isPrivate(Array(b[12...])) } // NAT64 64:ff9b::/96
        if b[0] & 0xfe == 0xfc { return true }          // fc00::/7 unique local
        if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return true } // fe80::/10 link-local
        if b[0] == 0xff { return true }                // multicast
        if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8 { return true } // documentation
        return false
    }

    /// Re-checks every redirect, so a public page can't bounce the fetch to a private address.
    final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        var hops = 0
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            hops += 1
            guard hops <= 5, let u = request.url, (try? NetGuard.check(u)) != nil else { completionHandler(nil); return }
            completionHandler(request)
        }
    }
}
