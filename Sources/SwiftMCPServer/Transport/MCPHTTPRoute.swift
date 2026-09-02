import Foundation

/// A read-only HTTP endpoint served alongside the MCP protocol routes.
///
/// The transport's routes are a `switch` over literal paths, so a consumer
/// that needed one more endpoint had to change this package and rebuild its server. Two
/// consumers hit that: VaultMCP declined a `POST /reindex`, and later needed a calendar
/// subscription feed that a calendar client can only fetch over plain HTTP.
///
/// ## Why this is safe to add, when `/reindex` was not
///
/// **These routes are `GET`-only by construction.** There is no method to choose. The
/// objection that killed `POST /reindex` was that it would make an eighteen-second
/// reindex remotely triggerable on a WAN-forwarded port — a denial-of-service concern
/// about an expensive *mutation*. A read-only resource route is neither expensive by
/// nature nor a mutation, and nothing here lets a consumer reintroduce one.
///
/// Two further limits keep the protocol surface intact:
///
/// - **Reserved paths always win.** A custom route can never shadow `/mcp`, `/health`, or
///   any OAuth endpoint, no matter how greedy its prefix. Registering `/` is legal and
///   still cannot capture them.
/// - **Authentication is the default.** ``requiresAuthentication`` must be set to `false`
///   deliberately, and the only good reason is a client that cannot send headers at all —
///   a calendar subscription being the motivating case. Such a route carries its own
///   credential in the path, and the consumer is responsible for comparing it in constant
///   time.
public struct MCPHTTPRoute: Sendable {

    /// The parts of an incoming request a route is given.
    public struct Request: Sendable {
        /// Request path, with any query string already removed.
        public let path: String
        /// Raw query string, or `nil` when the request carried none.
        public let query: String?

        /// Creates a request.
        public init(path: String, query: String?) {
            self.path = path
            self.query = query
        }
    }

    /// What a route answers with.
    public struct Response: Sendable {
        /// HTTP status code.
        public let status: Int
        /// Value for the `Content-Type` header.
        public let contentType: String
        /// Response body.
        public let body: String

        /// Creates a response.
        public init(status: Int, contentType: String, body: String) {
            self.status = status
            self.contentType = contentType
            self.body = body
        }

        /// A `200 OK` carrying `body`.
        public static func ok(_ body: String, contentType: String) -> Response {
            Response(status: 200, contentType: contentType, body: body)
        }

        /// A `404 Not Found` with an empty body.
        ///
        /// The right answer for a credential that does not match: a route that carries its
        /// secret in the path should not distinguish "wrong token" from "no such feed".
        public static let notFound = Response(status: 404, contentType: "text/plain", body: "Not Found")
    }

    /// Path this route claims, matched on segment boundaries.
    public let pathPrefix: String
    /// Whether the server's authenticator must approve the request first.
    public let requiresAuthentication: Bool
    /// Produces the response.
    public let respond: @Sendable (Request) async -> Response

    /// Registers a read-only endpoint.
    ///
    /// - Parameters:
    ///   - pathPrefix: Path to claim, e.g. `"/calendar"`. Matching stops at a segment
    ///     boundary, so this claims `/calendar` and `/calendar/…` but never `/calendarium`.
    ///     A trailing slash is equivalent to none.
    ///   - requiresAuthentication: Whether the server's authenticator gates this route.
    ///     Defaults to `true`; set `false` only for clients that cannot send headers.
    ///   - respond: Produces the response. Runs off the event loop.
    public init(
        pathPrefix: String,
        requiresAuthentication: Bool = true,
        respond: @escaping @Sendable (Request) async -> Response
    ) {
        self.pathPrefix = pathPrefix
        self.requiresAuthentication = requiresAuthentication
        self.respond = respond
    }
}

/// Resolves a request path to a consumer-registered route, protecting the protocol's own.
struct HTTPRouteTable: Sendable {

    /// Paths this package owns. No custom route may answer for these, or beneath them.
    ///
    /// Held here rather than in the handler so the guarantee is testable without a
    /// channel, and so adding a protocol endpoint without reserving it is a visible
    /// omission in one place.
    static let reservedPaths: Set<String> = [
        "/health",
        "/mcp",
        "/mcp/sse",
        "/.well-known/oauth-protected-resource",
        "/.well-known/oauth-authorization-server",
        "/register",
        "/authorize",
        "/authorize/consent",
        "/token",
    ]

    /// Routes in registration order; the first match wins.
    let routes: [MCPHTTPRoute]

    /// The route that should answer for `path`, if any.
    ///
    /// - Parameter path: Request path, query string already stripped.
    /// - Returns: The matching route, or `nil` for a reserved or unclaimed path.
    func match(path: String) -> MCPHTTPRoute? {
        guard !Self.isReserved(path) else { return nil }
        return routes.first { Self.claims(prefix: $0.pathPrefix, path: path) }
    }

    /// Whether this package owns `path`, or owns something `path` sits beneath.
    static func isReserved(_ path: String) -> Bool {
        reservedPaths.contains { claims(prefix: $0, path: path) }
    }

    /// Whether `prefix` claims `path`, matching only at a segment boundary.
    ///
    /// `hasPrefix` alone would let `/calendar` capture `/calendarium`, which is how a
    /// route quietly swallows a sibling endpoint someone adds later.
    private static func claims(prefix: String, path: String) -> Bool {
        let base = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        if path == base { return true }
        return path.hasPrefix(base + "/")
    }
}
