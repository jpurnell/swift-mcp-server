import Foundation

/// Which `Host` and `Origin` values a server will answer.
///
/// ## The attack this closes
///
/// A page the user is merely *visiting* can point its own domain at `127.0.0.1` and then POST to
/// a server that only ever expected local callers. The socket sees a local connection, because
/// it is one; the difference is visible only in the headers the browser is obliged to send. A
/// server that reads neither cannot tell the attacker's page from the user's own client.
///
/// The advisory this follows is
/// [GHSA-w48q-cv73-mx4w](https://github.com/modelcontextprotocol/typescript-sdk/security/advisories/GHSA-w48q-cv73-mx4w),
/// and MCP's own scope for it is narrow and worth repeating: it is about **loopback servers
/// running without TLS and without authentication**. A server reachable over the network has
/// already decided that callers it did not start are legitimate, and a `Host` check would only
/// tell it what its own DNS name is.
///
/// ## Why the default is `any`
///
/// A default of ``loopback`` would be the safer *shape* and the wrong *behaviour*: this package
/// serves deployed, publicly-named servers, and flipping it would take them off the air on
/// upgrade with a 403 that names nothing the operator changed. The choice belongs to whoever
/// knows where the server runs — so it is asked for, not assumed.
///
/// **If your server listens on loopback and has no TLS or API key, pass ``loopback``.** That is
/// the configuration the advisory is about, and nothing else in this package substitutes for it.
public enum AllowedHosts: Sendable, Equatable {
    /// Answer only callers naming a loopback host: `localhost`, `127.0.0.1`, or `[::1]`, with or
    /// without a port.
    case loopback

    /// Answer loopback callers and these additional host names.
    ///
    /// Compared without the port, so `example.com` admits `example.com:8443`. Matching is
    /// case-insensitive, as host names are.
    case named(Set<String>)

    /// Answer every caller. No `Host` or `Origin` validation is performed.
    case any

    /// The loopback names, without ports.
    private static let loopbackNames: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    /// Whether a request naming `host` and `origin` may be served.
    ///
    /// Both are checked when present, and both must pass: an attacker's page controls `Origin`
    /// and the DNS name in `Host`, so accepting a request because one of the two looked
    /// acceptable would leave the other free to be anything.
    ///
    /// A missing `Origin` is not a failure — a non-browser client sends none, and it is browsers
    /// this guards against. A missing `Host` is: HTTP/1.1 requires it, and its absence is not a
    /// shape any ordinary client produces.
    ///
    /// - Parameters:
    ///   - host: The `Host` header, if the request carried one.
    ///   - origin: The `Origin` header, if the request carried one.
    /// - Returns: `true` when the request may be served.
    public func admits(host: String?, origin: String?) -> Bool {
        if case .any = self { return true }

        guard let host, Self.isAdmissible(Self.hostName(fromAuthority: host), by: self) else {
            return false
        }
        guard let origin else { return true }
        guard let originHost = Self.hostName(fromOrigin: origin) else { return false }
        return Self.isAdmissible(originHost, by: self)
    }

    private static func isAdmissible(_ name: String?, by policy: AllowedHosts) -> Bool {
        guard let name else { return false }
        let lowered = name.lowercased()
        if loopbackNames.contains(lowered) { return true }
        if case .named(let extra) = policy {
            return extra.contains { $0.lowercased() == lowered }
        }
        return false
    }

    /// The host out of an `authority`, dropping any port.
    ///
    /// An IPv6 literal keeps its brackets, because that is how it is written in a header and how
    /// ``loopbackNames`` spells it; splitting on `:` first would shred it into fragments.
    private static func hostName(fromAuthority authority: String) -> String? {
        let trimmed = authority.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            return String(trimmed[...close])
        }
        return trimmed.split(separator: ":").first.map(String.init)
    }

    /// The host out of an `Origin`, which is a scheme and an authority rather than a bare name.
    private static func hostName(fromOrigin origin: String) -> String? {
        let trimmed = origin.trimmingCharacters(in: .whitespaces)
        // `null` is what a browser sends for an opaque origin — a sandboxed frame, a `data:`
        // document. It names nothing that can be checked, so it is not admitted.
        guard trimmed != "null" else { return nil }
        guard let separator = trimmed.range(of: "://") else {
            return hostName(fromAuthority: trimmed)
        }
        let authority = trimmed[separator.upperBound...]
        let withoutPath = authority.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        return hostName(fromAuthority: withoutPath)
    }
}
