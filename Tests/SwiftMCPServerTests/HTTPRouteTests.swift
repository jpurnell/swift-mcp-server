import Foundation
import Testing
@testable import SwiftMCPServer

@Suite("MCPHTTPRoute")
struct HTTPRouteTests {

    private static func route(
        _ prefix: String,
        requiresAuthentication: Bool = true,
        body: String = "ok"
    ) -> MCPHTTPRoute {
        MCPHTTPRoute(pathPrefix: prefix, requiresAuthentication: requiresAuthentication) { _ in
            .ok(body, contentType: "text/plain")
        }
    }

    // MARK: - Matching

    @Test("a route matches its own path exactly")
    func matchesExactPath() {
        let table = HTTPRouteTable(routes: [Self.route("/calendar")])
        #expect(table.match(path: "/calendar")?.pathPrefix == "/calendar")
    }

    @Test("a route matches paths beneath it")
    func matchesDescendantPaths() {
        let table = HTTPRouteTable(routes: [Self.route("/calendar")])
        #expect(table.match(path: "/calendar/abc123/19-coprock.ics")?.pathPrefix == "/calendar")
    }

    @Test("matching stops at a path segment, so /calendar does not capture /calendarium")
    func matchesOnSegmentBoundaries() {
        let table = HTTPRouteTable(routes: [Self.route("/calendar")])
        #expect(table.match(path: "/calendarium") == nil)
        #expect(table.match(path: "/calendar-feed") == nil)
        #expect(table.match(path: "/calendar/")?.pathPrefix == "/calendar")
    }

    @Test("a trailing slash on the prefix behaves the same as none")
    func trailingSlashOnPrefixIsEquivalent() {
        let table = HTTPRouteTable(routes: [Self.route("/calendar/")])
        #expect(table.match(path: "/calendar/x.ics")?.pathPrefix == "/calendar/")
        #expect(table.match(path: "/calendarium") == nil)
    }

    @Test("an unmatched path yields no route")
    func unmatchedPathYieldsNothing() {
        let table = HTTPRouteTable(routes: [Self.route("/calendar")])
        #expect(table.match(path: "/something-else") == nil)
    }

    @Test("the first registered route wins when two could match")
    func firstRegistrationWins() async throws {
        let table = HTTPRouteTable(routes: [
            Self.route("/feed", body: "first"),
            Self.route("/feed", body: "second"),
        ])
        let matched = try #require(table.match(path: "/feed/x"))
        let response = await matched.respond(.init(path: "/feed/x", query: nil))
        #expect(response.body == "first")
    }

    // MARK: - Reserved paths

    @Test("a custom route can never shadow the protocol's own endpoints")
    func reservedPathsAreNeverMatched() {
        let greedy = HTTPRouteTable(routes: [Self.route("/")])
        for reserved in ["/health", "/mcp", "/mcp/sse", "/token", "/authorize",
                         "/authorize/consent", "/register",
                         "/.well-known/oauth-protected-resource",
                         "/.well-known/oauth-authorization-server"] {
            #expect(greedy.match(path: reserved) == nil, "\(reserved) must stay reserved")
        }
    }

    @Test("a route registered directly on a reserved path is refused a match")
    func routeOnAReservedPathNeverMatches() {
        let table = HTTPRouteTable(routes: [Self.route("/mcp")])
        #expect(table.match(path: "/mcp") == nil)
    }

    @Test("paths beneath a reserved endpoint stay reserved too")
    func descendantsOfReservedPathsAreReserved() {
        let greedy = HTTPRouteTable(routes: [Self.route("/")])
        #expect(greedy.match(path: "/mcp/anything") == nil)
    }

    @Test("a path that merely looks reserved is still routable")
    func lookalikePathsAreRoutable() {
        let table = HTTPRouteTable(routes: [Self.route("/")])
        #expect(table.match(path: "/healthy")?.pathPrefix == "/")
        #expect(table.match(path: "/mcpx")?.pathPrefix == "/")
    }

    // MARK: - Authentication

    @Test("routes require authentication unless they opt out explicitly")
    func authenticationIsTheDefault() {
        #expect(Self.route("/a").requiresAuthentication)
        #expect(Self.route("/b", requiresAuthentication: false).requiresAuthentication == false)
    }

    // MARK: - Responses

    @Test("a route answers with the body and content type it chose")
    func routeAnswers() async {
        let route = MCPHTTPRoute(pathPrefix: "/calendar", requiresAuthentication: false) { request in
            .ok("path=\(request.path) query=\(request.query ?? "-")", contentType: "text/calendar")
        }
        let response = await route.respond(.init(path: "/calendar/x.ics", query: "a=1"))
        #expect(response.status == 200)
        #expect(response.contentType == "text/calendar")
        #expect(response.body == "path=/calendar/x.ics query=a=1")
    }

    @Test("a route can decline with 404 rather than inventing content")
    func routeCanDecline() async {
        let route = MCPHTTPRoute(pathPrefix: "/calendar", requiresAuthentication: false) { _ in
            .notFound
        }
        let response = await route.respond(.init(path: "/calendar/nope.ics", query: nil))
        #expect(response.status == 404)
    }
}

@Suite("MCPServerBuilder — HTTP routes")
struct HTTPRouteBuilderTests {

    private static func route(_ prefix: String) -> MCPHTTPRoute {
        MCPHTTPRoute(pathPrefix: prefix, requiresAuthentication: false) { _ in
            .ok("", contentType: "text/calendar")
        }
    }

    @Test("a server registers no HTTP routes unless asked")
    func noRoutesByDefault() {
        #expect(MCPServer.builder().buildConfiguration().httpRoutes.isEmpty)
    }

    @Test("httpRoute registers one, and httpRoutes several, in order")
    func routesAreRegisteredInOrder() {
        let config = MCPServer.builder()
            .httpRoute(Self.route("/calendar"))
            .httpRoutes([Self.route("/feed"), Self.route("/ics")])
            .buildConfiguration()

        #expect(config.httpRoutes.map(\.pathPrefix) == ["/calendar", "/feed", "/ics"])
    }

    @Test("registering routes leaves the rest of the configuration alone")
    func registrationIsAdditive() {
        let config = MCPServer.builder()
            .serverName("Vault")
            .serverVersion("2.0.0")
            .httpRoute(Self.route("/calendar"))
            .buildConfiguration()

        #expect(config.serverName == "Vault")
        #expect(config.serverVersion == "2.0.0")
        #expect(config.httpRoutes.count == 1)
    }
}
