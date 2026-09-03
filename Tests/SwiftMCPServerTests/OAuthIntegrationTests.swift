import Testing
import Foundation
import SwiftOAuthCore
import SwiftOAuthProvider
@testable import SwiftMCPServer

/// Integration tests for OAuth 2.0 with HTTP Server
@Suite("OAuth Integration")
struct OAuthIntegrationTests {

    // MARK: - Test Helpers

    static func makeOAuthServer() async throws -> OAuthServer {
        let storage = try OAuthStorage(path: ":memory:")
        return OAuthServer(
                storage: storage, issuer: "http://localhost:8080",
                resourcePolicy: ResourceIndicatorPolicy(
                    known: [URL(string: "http://localhost:8080")].compactMap { $0 }
                        .reduce(into: Set<URL>()) { $0.insert($1) },
                    allowsUnspecified: true))
    }

    // MARK: - HTTPServerTransport OAuth Configuration

    @Suite("Transport Configuration")
    struct TransportConfigurationTests {

        @Test("Transport accepts OAuth server parameter")
        func transportAcceptsOAuthServer() async throws {
            let oauthServer = try await OAuthIntegrationTests.makeOAuthServer()

            // This should compile and not throw
            let transport = HTTPServerTransport(
                port: 0,  // Use any available port
                authenticator: nil,
                oauthServer: oauthServer
            )

            // Verify transport was created
            #expect(type(of: transport) == HTTPServerTransport.self)
        }

        @Test("Transport works without OAuth server")
        func transportWorksWithoutOAuth() async throws {
            // This should work exactly as before
            let transport = HTTPServerTransport(port: 0)
            #expect(type(of: transport) == HTTPServerTransport.self)
        }
    }

    // MARK: - OAuth Endpoint Flow Tests

    @Suite("OAuth Flow")
    struct OAuthFlowTests {

        @Test("Complete authorization code flow")
        func completeAuthorizationCodeFlow() async throws {
            // Create OAuth server and handler
            let storage = try OAuthStorage(path: ":memory:")
            let server = OAuthServer(
                storage: storage, issuer: "http://localhost:8080",
                resourcePolicy: ResourceIndicatorPolicy(
                    known: [URL(string: "http://localhost:8080")].compactMap { $0 }
                        .reduce(into: Set<URL>()) { $0.insert($1) },
                    allowsUnspecified: true))
            let handler = OAuthHTTPHandler(server: server)

            // Step 1: Register a client
            let registrationBody = """
            {
                "client_name": "Integration Test Client",
                "redirect_uris": ["http://localhost/callback"],
                "grant_types": ["authorization_code", "refresh_token"],
                "token_endpoint_auth_method": "client_secret_post"
            }
            """

            let regResponse = await handler.handleRegistrationRequest(body: registrationBody)
            #expect(regResponse.statusCode == 201)

            // Parse client credentials
            let regData = try #require(regResponse.body.data(using: .utf8))
            let client = try JSONDecoder().decode(ClientRegistrationResponse.self, from: regData)
            #expect(client.clientId.count >= 8)
            let secret = try #require(client.clientSecret)

            // Step 2: Get authorization code with PKCE
            let verifier = PKCE.generateCodeVerifier()
            let challenge = try PKCE.generateCodeChallenge(verifier: verifier, method: .s256)

            let authParams: [String: String] = [
                "response_type": "code",
                "client_id": client.clientId,
                "redirect_uri": "http://localhost/callback",
                "code_challenge": challenge,
                "code_challenge_method": "S256",
                "scope": "mcp:tools"
            ]

            // Get consent page
            let consentResponse = await handler.handleAuthorizationRequest(queryParams: authParams)
            #expect(consentResponse.statusCode == 200, "Should return consent page")

            // Extract CSRF token and submit consent
            let csrfToken = try #require(OAuthIntegrationTests.extractCSRFToken(from: consentResponse.body), "Should have CSRF token")

            let consentParams: [String: String] = [
                "action": "approve",
                "client_id": client.clientId,
                "redirect_uri": "http://localhost/callback",
                "csrf_token": csrfToken,
                "scope": "mcp:tools",
                "code_challenge": challenge,
                "code_challenge_method": "S256"
            ]

            let authResponse = await handler.handleConsentSubmission(formParams: consentParams)
            #expect(authResponse.statusCode == 302)

            // Extract code from redirect
            let location = try #require(authResponse.headers["Location"])
            let code = try #require(OAuthIntegrationTests.extractCode(from: location))

            // Step 3: Exchange code for tokens
            let tokenBody = buildFormBody([
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": "http://localhost/callback",
                "client_id": client.clientId,
                "client_secret": secret,
                "code_verifier": verifier
            ])

            let tokenResponse = await handler.handleTokenRequest(body: tokenBody, authHeader: nil)
            #expect(tokenResponse.statusCode == 200)

            let tokenData = try #require(tokenResponse.body.data(using: .utf8))
            let tokens = try JSONDecoder().decode(TokenResponse.self, from: tokenData)
            #expect(tokens.accessToken.count >= 10)
            _ = try #require(tokens.refreshToken)
            #expect(tokens.tokenType == "Bearer")

            // Step 4: Validate the token
            let validationResult = await handler.validateBearerToken(authHeader: "Bearer \(tokens.accessToken)")
            #expect(validationResult.isValid)

            if case .valid(let validatedClientId, let scope, _) = validationResult {
                #expect(validatedClientId == client.clientId)
                #expect(scope == "mcp:tools")
            }

            // Step 5: Refresh the token
            let refreshBody = buildFormBody([
                "grant_type": "refresh_token",
                "refresh_token": try #require(tokens.refreshToken),
                "client_id": client.clientId,
                "client_secret": try #require(client.clientSecret)
            ])

            let refreshResponse = await handler.handleTokenRequest(body: refreshBody, authHeader: nil)
            #expect(refreshResponse.statusCode == 200)

            let refreshData = try #require(refreshResponse.body.data(using: .utf8))
            let newTokens = try JSONDecoder().decode(TokenResponse.self, from: refreshData)
            #expect(newTokens.accessToken.count > 0)
            #expect(newTokens.accessToken != tokens.accessToken)  // Should be a new token

            // Verify new token works
            let newValidation = await handler.validateBearerToken(authHeader: "Bearer \(newTokens.accessToken)")
            #expect(newValidation.isValid)
        }

        @Test("Public client flow without secret")
        func publicClientFlow() async throws {
            let storage = try OAuthStorage(path: ":memory:")
            let server = OAuthServer(
                storage: storage, issuer: "http://localhost:8080",
                resourcePolicy: ResourceIndicatorPolicy(
                    known: [URL(string: "http://localhost:8080")].compactMap { $0 }
                        .reduce(into: Set<URL>()) { $0.insert($1) },
                    allowsUnspecified: true))
            let handler = OAuthHTTPHandler(server: server)

            // Register a public client (no secret)
            let registrationBody = """
            {
                "client_name": "Public Client",
                "redirect_uris": ["http://localhost/callback"],
                "token_endpoint_auth_method": "none"
            }
            """

            let regResponse = await handler.handleRegistrationRequest(body: registrationBody)
            #expect(regResponse.statusCode == 201)

            let regData = try #require(regResponse.body.data(using: .utf8))
            let client = try JSONDecoder().decode(ClientRegistrationResponse.self, from: regData)
            #expect(client.clientSecret == nil)  // No secret for public client

            // Get authorization code with PKCE (required for public clients)
            let verifier = PKCE.generateCodeVerifier()
            let challenge = try PKCE.generateCodeChallenge(verifier: verifier, method: .s256)

            let authParams: [String: String] = [
                "response_type": "code",
                "client_id": client.clientId,
                "redirect_uri": "http://localhost/callback",
                "code_challenge": challenge,
                "code_challenge_method": "S256"
            ]

            // Get consent page
            let consentResponse = await handler.handleAuthorizationRequest(queryParams: authParams)
            #expect(consentResponse.statusCode == 200, "Should return consent page")

            // Extract CSRF token and submit consent
            let csrfToken = try #require(OAuthIntegrationTests.extractCSRFToken(from: consentResponse.body))

            let consentParams: [String: String] = [
                "action": "approve",
                "client_id": client.clientId,
                "redirect_uri": "http://localhost/callback",
                "csrf_token": csrfToken,
                "code_challenge": challenge,
                "code_challenge_method": "S256"
            ]

            let authResponse = await handler.handleConsentSubmission(formParams: consentParams)
            #expect(authResponse.statusCode == 302)

            let location = try #require(authResponse.headers["Location"])
            let code = try #require(OAuthIntegrationTests.extractCode(from: location))

            // Exchange code for tokens (no client_secret needed)
            let tokenBody = buildFormBody([
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": "http://localhost/callback",
                "client_id": client.clientId,
                "code_verifier": verifier
            ])

            let tokenResponse = await handler.handleTokenRequest(body: tokenBody, authHeader: nil)
            #expect(tokenResponse.statusCode == 200)

            let tokens = try JSONDecoder().decode(TokenResponse.self, from: #require(tokenResponse.body.data(using: .utf8)))
            #expect(tokens.accessToken.count > 0)
        }
    }

    // MARK: - MCP Scope Tests

    @Suite("MCP Scopes")
    struct MCPScopeTests {

        @Test("Supports mcp:tools scope")
        func supportsMcpToolsScope() async throws {
            let storage = try OAuthStorage(path: ":memory:")
            let server = OAuthServer(
                storage: storage, issuer: "http://localhost:8080",
                resourcePolicy: ResourceIndicatorPolicy(
                    known: [URL(string: "http://localhost:8080")].compactMap { $0 }
                        .reduce(into: Set<URL>()) { $0.insert($1) },
                    allowsUnspecified: true))
            let handler = OAuthHTTPHandler(server: server)

            // Register client and get token with scope
            let client = try await registerTestClient(handler: handler)
            let tokens = try await getTokensWithScope(
                handler: handler,
                client: client,
                scope: "mcp:tools"
            )

            let result = await handler.validateBearerToken(authHeader: "Bearer \(tokens.accessToken)")
            if case .valid(_, let scope, _) = result {
                #expect(scope == "mcp:tools")
            }
        }

        @Test("Supports multiple MCP scopes")
        func supportsMultipleMcpScopes() async throws {
            let storage = try OAuthStorage(path: ":memory:")
            let server = OAuthServer(
                storage: storage, issuer: "http://localhost:8080",
                resourcePolicy: ResourceIndicatorPolicy(
                    known: [URL(string: "http://localhost:8080")].compactMap { $0 }
                        .reduce(into: Set<URL>()) { $0.insert($1) },
                    allowsUnspecified: true))
            let handler = OAuthHTTPHandler(server: server)

            let client = try await registerTestClient(handler: handler)
            let tokens = try await getTokensWithScope(
                handler: handler,
                client: client,
                scope: "mcp:tools mcp:resources"
            )

            let result = await handler.validateBearerToken(authHeader: "Bearer \(tokens.accessToken)")
            if case .valid(_, let scope, _) = result {
                #expect(scope?.contains("mcp:tools") == true)
                #expect(scope?.contains("mcp:resources") == true)
            }
        }
    }

    // MARK: - Metadata Tests

    @Suite("Server Metadata")
    struct ServerMetadataTests {

        @Test("Metadata includes MCP scopes")
        func metadataIncludesMcpScopes() async throws {
            let storage = try OAuthStorage(path: ":memory:")
            let server = OAuthServer(
                storage: storage, issuer: "http://localhost:8080",
                resourcePolicy: ResourceIndicatorPolicy(
                    known: [URL(string: "http://localhost:8080")].compactMap { $0 }
                        .reduce(into: Set<URL>()) { $0.insert($1) },
                    allowsUnspecified: true))
            let handler = OAuthHTTPHandler(server: server)

            let response = await handler.handleMetadataRequest()
            #expect(response.statusCode == 200)

            let data = try #require(response.body.data(using: .utf8))
            let metadata = try JSONDecoder().decode(ServerMetadata.self, from: data)

            #expect(metadata.scopesSupported?.contains("mcp:tools") == true)
            #expect(metadata.scopesSupported?.contains("mcp:resources") == true)
            #expect(metadata.scopesSupported?.contains("mcp:prompts") == true)
        }

        @Test("Metadata includes PKCE support")
        func metadataIncludesPkceSupport() async throws {
            let storage = try OAuthStorage(path: ":memory:")
            let server = OAuthServer(
                storage: storage, issuer: "http://localhost:8080",
                resourcePolicy: ResourceIndicatorPolicy(
                    known: [URL(string: "http://localhost:8080")].compactMap { $0 }
                        .reduce(into: Set<URL>()) { $0.insert($1) },
                    allowsUnspecified: true))
            let handler = OAuthHTTPHandler(server: server)

            let response = await handler.handleMetadataRequest()
            let data = try #require(response.body.data(using: .utf8))
            let metadata = try JSONDecoder().decode(ServerMetadata.self, from: data)

            #expect(metadata.codeChallengeMethodsSupported.contains("S256"))
        }
    }

    // MARK: - Helpers

    static func extractCode(from location: String) -> String? {
        guard let components = URLComponents(string: location),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            return nil
        }
        return code
    }

    static func extractCSRFToken(from html: String) -> String? {
        // Look for: name="csrf_token" value="..."
        guard let range = html.range(of: "name=\"csrf_token\" value=\"") else {
            return nil
        }
        let start = range.upperBound
        guard let endRange = html[start...].range(of: "\"") else {
            return nil
        }
        return String(html[start..<endRange.lowerBound])
    }

    static func buildFormBody(_ params: [String: String]) -> String {
        params.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
    }

    static func registerTestClient(handler: OAuthHTTPHandler) async throws -> ClientRegistrationResponse {
        let body = """
        {
            "client_name": "Test Client",
            "redirect_uris": ["http://localhost/callback"],
            "grant_types": ["authorization_code", "refresh_token"],
            "token_endpoint_auth_method": "client_secret_post"
        }
        """
        let response = await handler.handleRegistrationRequest(body: body)
        let data = try #require(response.body.data(using: .utf8))
        return try JSONDecoder().decode(ClientRegistrationResponse.self, from: data)
    }

    static func getTokensWithScope(handler: OAuthHTTPHandler, client: ClientRegistrationResponse, scope: String) async throws -> TokenResponse {
        let verifier = PKCE.generateCodeVerifier()
        let challenge = try PKCE.generateCodeChallenge(verifier: verifier, method: .s256)

        let authParams: [String: String] = [
            "response_type": "code",
            "client_id": client.clientId,
            "redirect_uri": "http://localhost/callback",
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "scope": scope
        ]

        // Step 1: Get consent page
        let consentResponse = await handler.handleAuthorizationRequest(queryParams: authParams)

        // Extract CSRF token from consent page HTML
        guard let csrfToken = extractCSRFToken(from: consentResponse.body) else {
            throw OAuthTestError.missingCSRFToken
        }

        // Step 2: Submit consent approval
        let consentParams: [String: String] = [
            "action": "approve",
            "client_id": client.clientId,
            "redirect_uri": "http://localhost/callback",
            "csrf_token": csrfToken,
            "scope": scope,
            "code_challenge": challenge,
            "code_challenge_method": "S256"
        ]

        let authResponse = await handler.handleConsentSubmission(formParams: consentParams)
        guard let location = authResponse.headers["Location"],
              let code = extractCode(from: location) else {
            throw OAuthTestError.missingAuthorizationCode
        }

        let tokenBody = buildFormBody([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": "http://localhost/callback",
            "client_id": client.clientId,
            "client_secret": try #require(client.clientSecret),
            "code_verifier": verifier
        ])

        let tokenResponse = await handler.handleTokenRequest(body: tokenBody, authHeader: nil)
        let data = try #require(tokenResponse.body.data(using: .utf8))
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }
}

/// Errors that can occur in OAuth tests
enum OAuthTestError: Error {
    case missingCSRFToken
    case missingAuthorizationCode
}

// Make helpers accessible to nested types
private func extractCode(from location: String) -> String? {
    OAuthIntegrationTests.extractCode(from: location)
}

private func buildFormBody(_ params: [String: String]) -> String {
    OAuthIntegrationTests.buildFormBody(params)
}

private func registerTestClient(handler: OAuthHTTPHandler) async throws -> ClientRegistrationResponse {
    try await OAuthIntegrationTests.registerTestClient(handler: handler)
}

private func getTokensWithScope(handler: OAuthHTTPHandler, client: ClientRegistrationResponse, scope: String) async throws -> TokenResponse {
    try await OAuthIntegrationTests.getTokensWithScope(handler: handler, client: client, scope: scope)
}
