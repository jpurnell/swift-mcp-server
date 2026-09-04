import Foundation
import Testing
import SwiftOAuthProvider

@testable import SwiftMCPServer

/// The consent step as a browser performs it: render the page, post back exactly what it
/// contained.
///
/// Every other test here posts the consent fields directly, which is what a test client does and
/// not what a browser does. A browser submits the form's own inputs and nothing else, so any
/// value the authorization request carried and the page failed to render is silently dropped —
/// and under a strict resource-indicator policy that turns into `invalid_target` at a step the
/// client did nothing wrong at.
///
/// This is the case neither this package's suite nor the upstream one reached: upstream asserts
/// the hidden field is present in the rendered HTML, which is a different claim from a round
/// trip actually preserving it.
@Suite("Consent round trip")
struct ConsentRoundTripTests {

    private static let issuer = "http://localhost:8080"

    /// The fields a browser would submit: every `<input>` the page rendered, and nothing else.
    private func renderedFields(in html: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in html.components(separatedBy: "<input").dropFirst() {
            guard let nameRange = line.range(of: #"name="#),
                let valueRange = line.range(of: #"value="#)
            else { continue }
            func quoted(after range: Range<String.Index>) -> String? {
                let rest = line[range.upperBound...]
                guard let open = rest.firstIndex(of: "\""),
                    let close = rest[rest.index(after: open)...].firstIndex(of: "\"")
                else { return nil }
                return String(rest[rest.index(after: open)..<close])
            }
            guard let name = quoted(after: nameRange), let value = quoted(after: valueRange)
            else { continue }
            fields[name] = value
        }
        return fields
    }

    @Test("A browser round trip preserves the resource indicator under a strict policy")
    func testRoundTripPreservesResource() async throws {
        let storage = try OAuthStorage(path: ":memory:")
        // Built through URLComponents so the scheme and host are checked as parsed fields; the
        // issuer is a literal here, but the shape should match production, which validates it.
        let components = try #require(URLComponents(string: Self.issuer))
        let resource = try #require(components.url)
        let server = OAuthServer(
            storage: storage, issuer: Self.issuer,
            scopesSupported: MCPServer.mcpScopes, served: .core,
            resourceIdentity: .colocated,
            resourcePolicy: ResourceIndicatorPolicy(known: [resource]))
        let handler = OAuthHTTPHandler(server: server)

        let client = try await server.registerClient(
            ClientRegistrationRequest(
                clientName: "round-trip", redirectUris: ["http://localhost/callback"]))

        // Step 1: the authorization request names the resource.
        let page = await handler.handleAuthorizationRequest(queryParams: [
            "response_type": "code",
            "client_id": client.clientId,
            "redirect_uri": "http://localhost/callback",
            "code_challenge": "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
            "code_challenge_method": "S256",
            "scope": "mcp:tools",
            "resource": Self.issuer,
        ])
        #expect(page.statusCode == 200, "the consent page should render")

        // Step 2: submit only what the page rendered — this is the whole point.
        var fields = renderedFields(in: page.body)
        #expect(
            fields["resource"] == Self.issuer,
            "the page must carry the resource forward; a browser cannot send what it never saw")
        fields["action"] = "approve"

        let redirect = await handler.handleConsentSubmission(formParams: fields)

        // Step 3: an authorization code, not invalid_target.
        let location = try #require(redirect.headers["Location"])
        #expect(
            !location.contains("invalid_target"),
            "a round trip that dropped the resource fails here: \(location)")
        #expect(location.contains("code="), "expected an authorization code, got \(location)")
    }
}
