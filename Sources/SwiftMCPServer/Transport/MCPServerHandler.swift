import Foundation
import MCP
import SwiftOAuthCore
import SwiftOAuthProvider
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOHTTP1
#if canImport(os)
import os
#endif

/// SwiftNIO channel handler for MCP Streamable HTTP server (spec 2025-03-26)
///
/// This handler processes incoming HTTP requests and routes them to appropriate handlers:
/// - GET /health - Health check endpoint
/// - GET /mcp - Server info (no Accept: text/event-stream) or SSE stream (with Accept: text/event-stream)
/// - POST /mcp - JSON-RPC requests (Streamable HTTP)
/// - DELETE /mcp - Terminate session
/// - OPTIONS * - CORS preflight
/// - GET <custom> - Read-only endpoints registered via ``MCPHTTPRoute``, which can never
///   shadow the paths above
///
/// ## Topics
///
/// ### Initialization
/// - ``init(transport:authenticator:oauthServer:serverName:serverVersion:)``
///
/// ### Channel Handling
/// - ``channelRead(context:data:)``
/// - ``errorCaught(context:error:)``
// Justification: NIO ChannelHandler is confined to its EventLoop; all state access occurs on that loop
final class MCPServerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    /// Reference to the parent transport (for accessing managers and stream)
    private weak var transport: HTTPServerTransport?

    /// API key authenticator (optional)
    private let authenticator: APIKeyAuthenticator?

    /// OAuth server for OAuth 2.0 authentication (optional)
    private let oauthServer: OAuthServer?

    /// OAuth HTTP handler (created lazily from OAuth server)
    private var oauthHandler: OAuthHTTPHandler? {
        guard let server = oauthServer else { return nil }
        return OAuthHTTPHandler(server: server)
    }

    /// Server name and version for protocol responses
    private let serverName: String
    private let serverVersion: String

    /// Consumer-registered read-only endpoints. Cannot shadow the protocol's own paths.
    private let routeTable: HTTPRouteTable

    /// Which `Host`/`Origin` values this server answers.
    private let allowedHosts: AllowedHosts

    /// Per-tool custom header parameters (SEP-2243).
    private let customHeaderParameters: CustomHeaderParameters

    /// The change notifications this server can actually produce.
    private let subscribableNotifications: Set<String>

    /// Logger
    private let logger: os.Logger

    /// Current request being processed
    private var currentRequest: HTTPRequestHead?
    private var requestBody: ByteBuffer?

    /// Initialize handler
    init(transport: HTTPServerTransport, authenticator: APIKeyAuthenticator?, oauthServer: OAuthServer?, serverName: String, serverVersion: String, routeTable: HTTPRouteTable = HTTPRouteTable(routes: []), allowedHosts: AllowedHosts = .any, customHeaderParameters: CustomHeaderParameters = CustomHeaderParameters(tools: []), subscribableNotifications: Set<String> = ["toolsListChanged"]) {
        self.subscribableNotifications = subscribableNotifications
        self.allowedHosts = allowedHosts
        self.customHeaderParameters = customHeaderParameters
        self.transport = transport
        self.authenticator = authenticator
        self.oauthServer = oauthServer
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.routeTable = routeTable
        self.logger = os.Logger(subsystem: "com.swiftmcp", category: "MCPServerHandler")
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let reqPart = unwrapInboundIn(data)

        switch reqPart {
        case .head(let head):
            currentRequest = head
            requestBody = nil

        case .body(var buffer):
            if requestBody == nil {
                requestBody = buffer
            } else {
                requestBody?.writeBuffer(&buffer)
            }

        case .end:
            guard let request = currentRequest else { return }

            // Process the complete request directly (synchronously in the event loop)
            handleRequest(context: context, head: request, body: requestBody)

            // Reset for next request
            currentRequest = nil
            requestBody = nil
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.debug("Channel error: \(error.localizedDescription, privacy: .public)")
        // Don't aggressively close - SSE connections should stay open
    }

    // MARK: - Request Handling

    private nonisolated func handleRequest(context: ChannelHandlerContext, head: HTTPRequestHead, body: ByteBuffer?) {
        // Justification: ChannelHandlerContext is confined to its EventLoop; used only within eventLoop.execute{}
        nonisolated(unsafe) let context = context

        // CRITICAL: Capture all context properties synchronously on the EventLoop
        // before creating any Tasks, as Tasks don't preserve EventLoop context
        // `self` is captured explicitly rather than implicitly: the EventLoop block runs
        // promptly and needs the handler alive to spawn the Task, so the capture is strong
        // and saying so keeps it from reading as an oversight next to the Task's `[weak self]`.
        context.eventLoop.execute { [self] in
            // Capture context properties while on EventLoop
            let channel = context.channel
            let eventLoop = context.eventLoop

            // Weak here, and deliberately different: the Task can outlive the handler.
            Task { [weak self] in
                await self?.processRequest(channel: channel, eventLoop: eventLoop, context: context, head: head, body: body)
            }
        }
    }

    private func processRequest(channel: Channel, eventLoop: EventLoop, context: ChannelHandlerContext, head: HTTPRequestHead, body: ByteBuffer?) async {
        let fullUri = head.uri
        let path = fullUri.split(separator: "?").first.map(String.init) ?? fullUri
        let query = fullUri.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init)
        let method = head.method

        // Ahead of everything, including the custom routes: a caller this server will not answer
        // must not reach a handler at all, and a public route is exactly the one an attacker's
        // page would find first.
        guard allowedHosts.admits(
            host: head.headers.first(name: "Host"),
            origin: head.headers.first(name: "Origin")
        ) else {
            logger.warning("Refused a request naming a host this server does not answer")
            sendResponse(context: context, status: .forbidden, body: "Forbidden")
            return
        }

        // Resolved before the auth check because a custom route may be public — a calendar
        // subscription cannot send an Authorization header — and before the protocol
        // switch because a matched route answers instead of falling through to 404. The
        // route table refuses reserved paths, so this cannot capture /mcp or OAuth.
        let customRoute = method == .GET ? routeTable.match(path: path) : nil

        if isAuthRequired(method: method, path: path, headers: head.headers, customRoute: customRoute) {
            let authorized = await checkAuthorization(headers: head.headers)
            if !authorized {
                sendResponse(context: context, status: .unauthorized, body: "Unauthorized")
                return
            }
        }

        if method == .OPTIONS {
            sendCORSPreflightResponse(context: context)
            return
        }

        if let customRoute {
            let response = await customRoute.respond(.init(path: path, query: query))
            sendResponse(
                context: context,
                status: HTTPResponseStatus(statusCode: response.status),
                body: response.body,
                contentType: response.contentType
            )
            return
        }

        // Route request
        // MCP 2026-07-28 removed the standalone GET stream and session termination. A client
        // declaring that revision must be told the method is not allowed rather than served a
        // mechanism its revision does not have — and the header is the only signal available,
        // since neither request carries a body to declare a version in.
        //
        // Conditional on the declared revision, not unconditional: a client on an earlier
        // revision legitimately uses both, and this package serves both.
        if (method == .GET || method == .DELETE), path == "/mcp",
           head.headers.first(name: "MCP-Protocol-Version") == "2026-07-28" {
            sendResponse(context: context, status: .methodNotAllowed, body: "Method Not Allowed")
            return
        }

        switch (method, path) {
        case (.GET, "/health"):
            handleHealthCheck(context: context)

        case (.GET, "/mcp"):
            // Streamable HTTP: Accept: text/event-stream means SSE stream request
            let acceptHeader = head.headers.first(name: "Accept") ?? ""
            if acceptHeader.contains("text/event-stream") {
                await processStreamableSSE(channel: channel, eventLoop: eventLoop, context: context, headers: head.headers)
            } else {
                handleServerInfo(context: context)
            }

        case (.POST, "/mcp"):
            await processStreamablePost(channel: channel, context: context, headers: head.headers, body: body)

        case (.DELETE, "/mcp"):
            await processSessionDelete(context: context, headers: head.headers)

        // Legacy SSE endpoint - maintained for backward compatibility
        case (.GET, "/mcp/sse"):
            await processLegacySSE(channel: channel, eventLoop: eventLoop, context: context)

        // OAuth 2.0 Endpoints
        case (.GET, "/.well-known/oauth-protected-resource"):
            await handleProtectedResourceMetadata(context: context)

        case (.GET, "/.well-known/oauth-authorization-server"):
            await handleOAuthMetadata(context: context)

        case (.POST, "/register"):
            await handleOAuthRegistration(context: context, body: body)

        case (.GET, "/authorize"):
            await handleOAuthAuthorization(context: context, uri: fullUri)

        case (.POST, "/authorize/consent"):
            await handleOAuthConsent(context: context, body: body)

        case (.POST, "/token"):
            await handleOAuthToken(context: context, body: body, headers: head.headers)

        case (_, "/health"), (_, "/mcp"):
            sendResponse(context: context, status: .methodNotAllowed, body: "Method Not Allowed")

        default:
            sendResponse(context: context, status: .notFound, body: "Not Found")
        }
    }

    // MARK: - Request Classification

    private static let oauthEndpoints: Set<String> = [
        "/.well-known/oauth-protected-resource", "/.well-known/oauth-authorization-server",
        "/register", "/authorize", "/authorize/consent", "/token"
    ]

    private func isAuthRequired(
        method: NIOHTTP1.HTTPMethod,
        path: String,
        headers: NIOHTTP1.HTTPHeaders,
        customRoute: MCPHTTPRoute?
    ) -> Bool {
        // A custom route decides for itself, and defaults to requiring authentication.
        // It cannot weaken a protocol endpoint: the route table never matches one.
        if let customRoute { return customRoute.requiresAuthentication }

        let isPublicEndpoint = path == "/health" || Self.oauthEndpoints.contains(path)
        guard !isPublicEndpoint else { return false }
        let isMcpGetWithoutSSE = method == .GET && path == "/mcp"
            && !(headers.first(name: "Accept")?.contains("text/event-stream") ?? false)
        return !isMcpGetWithoutSSE
    }

    // MARK: - Endpoint Handlers

    private func handleHealthCheck(context: ChannelHandlerContext) {
        sendResponse(context: context, status: .ok, body: "OK")
    }

    private func handleServerInfo(context: ChannelHandlerContext) {
        let info = """
        {
          "name": "\(serverName)",
          "version": "\(serverVersion)",
          "protocol": "MCP Streamable HTTP (2025-03-26)",
          "platform": "cross-platform",
          "endpoints": {
            "mcp": "POST /mcp - JSON-RPC requests",
            "sse": "GET /mcp (Accept: text/event-stream) - Server-initiated messages",
            "delete": "DELETE /mcp - Terminate session"
          },
          "authentication": "\(authenticator != nil ? "enabled" : "disabled")",
          "cors": "enabled"
        }
        """

        sendResponse(context: context, status: .ok, body: info, contentType: "application/json")
    }

    private func handleNoOAuthMetadata(context: ChannelHandlerContext) {
        // OAuth is not configured - return 404 so clients fall back to other auth methods (e.g., Bearer token)
        sendResponse(context: context, status: .notFound, body: "OAuth not configured. Use Bearer token authentication.")
    }

    // MARK: - OAuth Endpoint Handlers

    private func handleProtectedResourceMetadata(context: ChannelHandlerContext) async {
        if let handler = oauthHandler {
            let response = await handler.handleProtectedResourceMetadata()
            sendOAuthResponse(context: context, response: response)
        } else {
            handleNoOAuthMetadata(context: context)
        }
    }

    private func handleOAuthMetadata(context: ChannelHandlerContext) async {
        if let handler = oauthHandler {
            let response = await handler.handleMetadataRequest()
            sendOAuthResponse(context: context, response: response)
        } else {
            handleNoOAuthMetadata(context: context)
        }
    }

    private func handleOAuthRegistration(context: ChannelHandlerContext, body: ByteBuffer?) async {
        guard let handler = oauthHandler else {
            sendResponse(context: context, status: .notFound, body: "OAuth not configured")
            return
        }

        guard let bodyBuffer = body else {
            sendResponse(context: context, status: .badRequest, body: "Missing request body")
            return
        }

        let bodyString = String(buffer: bodyBuffer)
        let response = await handler.handleRegistrationRequest(body: bodyString)
        sendOAuthResponse(context: context, response: response)
    }

    private func handleOAuthAuthorization(context: ChannelHandlerContext, uri: String) async {
        guard let handler = oauthHandler else {
            sendResponse(context: context, status: .notFound, body: "OAuth not configured")
            return
        }

        // Parse query parameters from URI
        let queryParams = parseQueryParams(from: uri)
        let response = await handler.handleAuthorizationRequest(queryParams: queryParams)
        sendOAuthResponse(context: context, response: response)
    }

    private func handleOAuthConsent(context: ChannelHandlerContext, body: ByteBuffer?) async {
        guard let handler = oauthHandler else {
            sendResponse(context: context, status: .notFound, body: "OAuth not configured")
            return
        }

        guard let bodyBuffer = body else {
            sendResponse(context: context, status: .badRequest, body: "Missing request body")
            return
        }

        let bodyString = String(buffer: bodyBuffer)
        let formParams = parseFormBody(bodyString)
        let response = await handler.handleConsentSubmission(formParams: formParams)
        sendOAuthResponse(context: context, response: response)
    }

    private func handleOAuthToken(context: ChannelHandlerContext, body: ByteBuffer?, headers: HTTPHeaders) async {
        guard let handler = oauthHandler else {
            sendResponse(context: context, status: .notFound, body: "OAuth not configured")
            return
        }

        guard let bodyBuffer = body else {
            sendResponse(context: context, status: .badRequest, body: "Missing request body")
            return
        }

        let bodyString = String(buffer: bodyBuffer)
        let authHeader = headers.first(name: "Authorization")
        let response = await handler.handleTokenRequest(body: bodyString, authHeader: authHeader)
        sendOAuthResponse(context: context, response: response)
    }

    private func sendOAuthResponse(context: ChannelHandlerContext, response: OAuthHTTPResponse) {
        let eventLoop = context.eventLoop
        // Justification: context is captured for sendOAuthResponse dispatch; only accessed inside eventLoop.execute
        nonisolated(unsafe) let unsafeContext = context

        eventLoop.execute {
            self._sendOAuthResponse(context: unsafeContext, response: response)
        }
    }

    private func _sendOAuthResponse(context: ChannelHandlerContext, response: OAuthHTTPResponse) {
        let bodyData = response.body.data(using: .utf8) ?? Data()
        var buffer = context.channel.allocator.buffer(capacity: bodyData.count)
        buffer.writeBytes(bodyData)

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: response.contentType)
        headers.add(name: "Content-Length", value: "\(bodyData.count)")
        addCORSHeaders(to: &headers)

        // Add any custom headers from OAuth response
        for (name, value) in response.headers {
            headers.add(name: name, value: value)
        }

        // Determine if we should close connection (redirects keep-alive, others close)
        let status = HTTPResponseStatus(statusCode: response.statusCode)
        if status == .found || status == .seeOther {
            headers.add(name: "Connection", value: "close")
        } else {
            headers.add(name: "Connection", value: "close")
        }

        let responseHead = HTTPResponseHead(
            version: .http1_1,
            status: status,
            headers: headers
        )

        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)

        if status != .found && status != .seeOther {
            context.close(promise: nil)
        }
    }

    private func parseFormBody(_ body: String) -> [String: String] {
        var params: [String: String] = [:]

        for pair in body.split(separator: "&") {
            let keyValue = pair.split(separator: "=", maxSplits: 1)
            if keyValue.count == 2 {
                let key = String(keyValue[0]).removingPercentEncoding ?? String(keyValue[0])
                let value = String(keyValue[1]).removingPercentEncoding ?? String(keyValue[1])
                params[key] = value
            }
        }

        return params
    }

    private func parseQueryParams(from uri: String) -> [String: String] {
        guard let queryStart = uri.firstIndex(of: "?") else {
            return [:]
        }

        let queryString = String(uri[uri.index(after: queryStart)...])
        var params: [String: String] = [:]

        for pair in queryString.split(separator: "&") {
            let keyValue = pair.split(separator: "=", maxSplits: 1)
            if keyValue.count == 2 {
                let key = String(keyValue[0]).removingPercentEncoding ?? String(keyValue[0])
                let value = String(keyValue[1]).removingPercentEncoding ?? String(keyValue[1])
                params[key] = value
            }
        }

        return params
    }

    // MARK: - Streamable HTTP Endpoints (MCP 2025-03-26)

    /// Handle POST /mcp — Streamable HTTP JSON-RPC requests
    ///
    /// Per the MCP 2025-03-26 spec:
    /// - `initialize` requests create a new session (Mcp-Session-Id returned in response)
    /// - Notifications (no id) return 202 Accepted
    /// - Regular requests return JSON response directly with Mcp-Session-Id header
    private func processStreamablePost(channel: Channel, context: ChannelHandlerContext, headers: HTTPHeaders, body: ByteBuffer?) async {
        guard let transport = transport else { return }
        guard let bodyBuffer = body else {
            sendResponse(context: context, status: .badRequest, body: "Missing request body")
            return
        }

        let bodyData = Data(buffer: bodyBuffer)

        guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else { // silent: returns 400 for invalid JSON
            sendResponse(context: context, status: .badRequest, body: "Invalid JSON")
            return
        }

        let requestId = extractRequestId(from: bodyData)
        let sessionId = headers.first(name: "Mcp-Session-Id")

        // MCP 2026-07-28 requires `Mcp-Method` (and `Mcp-Name` where applicable) on a
        // Streamable HTTP POST, so an intermediary can route without parsing the body. The
        // header must agree with the body; a disagreement is a routing bug or a tampered
        // request, and the specification requires 400 with -32020 rather than picking a winner.
        //
        // Validated only when present. A client on an earlier revision sends no such header and
        // must not be refused for it — that is what keeps one server able to answer both.
        // A request declaring 2026-07-28 must carry its protocol version AND client capabilities
        // in _meta. One that does not is malformed: the server MUST answer -32602 with HTTP 400
        // rather than guess, because guessing capabilities means inventing what the client can
        // do. A request declaring no version is on an earlier revision and is not judged by this
        // rule, which is what keeps one server able to answer both.
        // Methods 2026-07-28 removed. A client declaring that revision must be told they do not
        // exist — 404 with -32601 — rather than served a mechanism its revision dropped. Earlier
        // clients still use both, so this is conditional on the declared version, exactly as the
        // GET and DELETE refusal is.
        if let method = json["method"] as? String,
           Self.methodsRemovedIn2026.contains(method),
           Self.declaredProtocolVersion(body: json, headers: headers) == "2026-07-28" {
            sendJSONRPCError(
                context: context, status: .notFound, requestId: requestId,
                code: -32601,
                message: "'\(method)' was removed in 2026-07-28")
            return
        }

        // Ordered ahead of the version check deliberately. A header carrying one version and a
        // body carrying another is a *disagreement between layers*, and stays one even when the
        // header's value also happens to be a revision this server never serves. Reporting
        // -32022 there tells the client to renegotiate, when what actually went wrong is that
        // its router and its body were built from different values — which renegotiating will
        // not fix.
        if let mismatch = customHeaderParameters.mismatch(headers: headers, body: json)
            ?? Self.headerMismatch(headers: headers, body: json)
        {
            sendJSONRPCError(
                context: context,
                status: .badRequest,
                requestId: requestId,
                code: -32020,
                message: mismatch
            )
            return
        }

        // An unsupported protocol version is refused with the versions this server does support,
        // so the client can pick one instead of guessing — and with the version it asked for, so
        // a client with several attempts in flight can tell which one was refused.
        if let declared = Self.declaredProtocolVersion(body: json, headers: headers),
           !Version.supported.contains(declared) {
            sendJSONRPCError(
                context: context, status: .badRequest, requestId: requestId,
                code: -32022,
                message: "Unsupported protocol version '\(declared)'",
                data: [
                    "requested": declared,
                    "supported": Array(Version.supported).sorted(by: >),
                ])
            return
        }

        if let missing = Self.missingRequiredMeta(body: json, headers: headers) {
            sendJSONRPCError(
                context: context,
                status: .badRequest,
                requestId: requestId,
                code: -32602,
                message: "A 2026-07-28 request must carry \(missing) in _meta"
            )
            return
        }

        // subscriptions/listen answers with a stream that stays open, not a single JSON object.
        // It is intercepted here rather than registered as an ordinary method handler because
        // the difference is in the response SHAPE — a handler can only return a value, and the
        // transport is the only layer that can decline to close the response.
        if json["method"] as? String == SubscriptionsListen.name {
            await handleSubscriptionsListen(
                transport: transport, channel: channel, eventLoop: context.eventLoop,
                context: context, requestId: requestId, body: json)
            return
        }

        // A body with an id but no method is a *response*: the client answering something this
        // server asked during a request that is still open. It is handed to the server to
        // correlate, and this POST is acknowledged immediately — the answer it enables will
        // arrive on the original request's stream, not here. Registering it as a pending
        // request instead would leave this connection waiting for a reply that goes elsewhere.
        if json["method"] == nil, json.keys.contains("id"),
           json["result"] != nil || json["error"] != nil {
            transport.receiveContinuation.yield(bodyData)
            sendResponse(context: context, status: .accepted, body: "")
            return
        }

        if json["method"] as? String == "initialize" {
            await handleStreamableInitialize(transport: transport, channel: channel, requestId: requestId, bodyData: bodyData)
        } else if !json.keys.contains("id") {
            await handleStreamableNotification(transport: transport, context: context, sessionId: sessionId, bodyData: bodyData)
        } else {
            // The originating request travels with it so a handler can observe the headers the
            // rules it implements are about — SEP-2243's custom `x-mcp-header` parameters can
            // only be checked against the headers that carried them.
            let httpRequest = MCP.HTTPRequest(
                method: "POST",
                headers: Dictionary(
                    headers.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first }),
                body: bodyData,
                path: "/mcp")
            await handleStreamableRequest(transport: transport, channel: channel, context: context, sessionId: sessionId, requestId: requestId, bodyData: bodyData, httpRequest: httpRequest)
        }
    }

    /// Methods the 2026-07-28 revision removed.
    ///
    /// They remain served for clients on earlier revisions; this set is only consulted when a
    /// request declares 2026-07-28.
    static let methodsRemovedIn2026: Set<String> = [
        "initialize", "notifications/initialized", "ping", "logging/setLevel",
        "resources/subscribe", "resources/unsubscribe",
    ]

    /// The protocol version a request declares, from `_meta` or the header that mirrors it.
    static func declaredProtocolVersion(body: [String: Any], headers: HTTPHeaders) -> String? {
        let meta = (body["_meta"] as? [String: Any])
            ?? ((body["params"] as? [String: Any])?["_meta"] as? [String: Any])
        if let fromMeta = meta?["io.modelcontextprotocol/protocolVersion"] as? String {
            return fromMeta
        }
        return headers.first(name: "MCP-Protocol-Version")
    }

    /// Methods that exist only in `2026-07-28`.
    ///
    /// A request reaching one of these is on that revision whether or not it says so — no
    /// earlier client knows the method to call it — so the revision's `_meta` requirements apply
    /// to it even when the request declared nothing. This is the mirror of
    /// ``methodsRemovedIn2026``: one set is what the revision took away, the other what it
    /// added, and both are only meaningful against a declared or implied version.
    static let methodsAddedIn2026: Set<String> = [
        "server/discover", "subscriptions/listen",
        "tasks/get", "tasks/update", "tasks/cancel",
    ]

    /// Names the required `_meta` field a 2026-07-28 request is missing, if any.
    ///
    /// Only requests on `2026-07-28` are checked — those that declare it, and those that call a
    /// method only it defines. A request declaring an earlier revision, or declaring none and
    /// calling a method that predates this one, is governed by that revision's rules, where
    /// these fields did not exist.
    private static func missingRequiredMeta(body: [String: Any], headers: HTTPHeaders) -> String? {
        let meta = (body["_meta"] as? [String: Any])
            ?? ((body["params"] as? [String: Any])?["_meta"] as? [String: Any])

        // A method the revision introduced cannot be reached by a client that predates it, so
        // there is no earlier client to protect here — and `_meta` is the only place such a
        // request states its version and capabilities. Without it the server has been told
        // nothing it can safely act on, which is what -32602 says.
        if let method = body["method"] as? String, methodsAddedIn2026.contains(method) {
            guard let meta else { return "io.modelcontextprotocol/protocolVersion" }
            if meta["io.modelcontextprotocol/protocolVersion"] == nil {
                return "io.modelcontextprotocol/protocolVersion"
            }
            if meta["io.modelcontextprotocol/clientCapabilities"] == nil {
                return "io.modelcontextprotocol/clientCapabilities"
            }
            return nil
        }

        // No declared version means an earlier revision; nothing to require.
        guard let meta else { return nil }
        guard let declared = meta["io.modelcontextprotocol/protocolVersion"] as? String else {
            // _meta present but no version: only a problem if capabilities say this is 2026.
            return meta["io.modelcontextprotocol/clientCapabilities"] != nil
                ? "io.modelcontextprotocol/protocolVersion" : nil
        }
        guard declared == "2026-07-28" else { return nil }

        if meta["io.modelcontextprotocol/clientCapabilities"] == nil {
            return "io.modelcontextprotocol/clientCapabilities"
        }
        return nil
    }

    // MARK: - Request metadata headers

    /// The sentinel wrapping a Base64-encoded header value: `=?base64?…?=`.
    ///
    /// A tool name, prompt name or resource URI that is not header-safe ASCII is carried
    /// encoded. The markers are case-sensitive and lowercase by specification.
    private static let base64SentinelPrefix = "=?base64?"
    private static let base64SentinelSuffix = "?="

    /// Decodes a header value that may be wrapped in the Base64 sentinel.
    ///
    /// A value must be decoded before it is compared to the body, or every non-ASCII name would
    /// look like a mismatch. A value that claims the sentinel but does not decode is returned
    /// unchanged, so it fails comparison rather than being silently accepted.
    private static func decodedHeaderValue(_ rawValue: String) -> String {
        // RFC 9110 §5.5 puts optional whitespace around a field value outside the value itself,
        // and requires a recipient to exclude it before evaluating. Comparing the raw bytes
        // would refuse a request any intermediary is entitled to send.
        let value = rawValue.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix(base64SentinelPrefix), value.hasSuffix(base64SentinelSuffix) else {
            return value
        }
        let start = value.index(value.startIndex, offsetBy: base64SentinelPrefix.count)
        let end = value.index(value.endIndex, offsetBy: -base64SentinelSuffix.count)
        guard start <= end,
              let data = Data(base64Encoded: String(value[start..<end])),
              let decoded = String(data: data, encoding: .utf8)
        else { return value }
        return decoded
    }

    /// The body field `Mcp-Name` mirrors for `method`, if that method has one.
    ///
    /// SEP-2243 §"Standard Headers" names `tools/call` and `prompts/get` (`params.name`) and
    /// `resources/read` (`params.uri`); SEP-2663 §"Streamable HTTP: Routing Headers" adds the
    /// tasks methods (`params.taskId`). Nothing else mirrors a name, including `tasks/result`
    /// and `tasks/list`, which v2 removed.
    ///
    /// - Parameters:
    ///   - method: The JSON-RPC method being called.
    ///   - params: Its parameters.
    /// - Returns: The value the header must match, or `nil` when this method has no such rule.
    static func nameShapedField(of method: String, in params: [String: Any]?) -> String? {
        switch method {
        case "tools/call", "prompts/get":
            return params?["name"] as? String
        case "resources/read":
            return params?["uri"] as? String
        case "tasks/get", "tasks/update", "tasks/cancel":
            return params?["taskId"] as? String
        default:
            return nil
        }
    }

    /// Checks the request-metadata headers against the body, returning a message when they
    /// disagree.
    ///
    /// MCP 2026-07-28 mirrors selected body fields into headers so intermediaries can route
    /// without parsing the body. A disagreement means a router and the executor are working from
    /// different values — the vulnerability this check closes — so the specification requires
    /// `400` with `-32020` rather than picking one.
    ///
    /// A client on an earlier revision sends none of these headers and must not be refused for
    /// it, which is what lets one server answer both. On `2026-07-28` they are **required**, not
    /// optional-but-checked: an intermediary that cannot see `Mcp-Method` cannot route at all,
    /// and a request it could not route must not then be executed as though it had been.
    private static func headerMismatch(headers: HTTPHeaders, body: [String: Any]) -> String? {
        let isCurrentRevision = declaredProtocolVersion(body: body, headers: headers) == "2026-07-28"
        let declaredMethod = headers.first(name: "Mcp-Method").map(decodedHeaderValue)

        if let actual = body["method"] as? String {
            if let declaredMethod, declaredMethod != actual {
                return "Mcp-Method '\(declaredMethod)' does not match the request body's '\(actual)'"
            }
            if declaredMethod == nil, isCurrentRevision {
                return "Mcp-Method is required and was not sent"
            }
        }

        // Mcp-Name mirrors whichever field names the thing being addressed, and SEP-2243
        // enumerates where that applies rather than leaving it to be inferred. Scoped to that
        // list on purpose: requiring the header wherever a name-shaped field happens to appear
        // means a method the server does not implement is refused for a missing header instead
        // of answered `-32601`, which tells the client its routing is wrong when the truth is
        // that the method does not exist.
        let params = body["params"] as? [String: Any]
        let nameShapedField = (body["method"] as? String).flatMap {
            Self.nameShapedField(of: $0, in: params)
        }
        if let declared = headers.first(name: "Mcp-Name") {
            if let nameShapedField, decodedHeaderValue(declared) != nameShapedField {
                return "Mcp-Name '\(declared)' does not match the request body's '\(nameShapedField)'"
            }
        } else if nameShapedField != nil, isCurrentRevision {
            return "Mcp-Name is required for a request naming a tool, prompt or resource"
        }

        // MCP-Protocol-Version mirrors the version declared in the body's _meta.
        if let declared = headers.first(name: "MCP-Protocol-Version").map(decodedHeaderValue) {
            let meta = (body["_meta"] as? [String: Any])
                ?? ((body["params"] as? [String: Any])?["_meta"] as? [String: Any])
            if let actual = meta?["io.modelcontextprotocol/protocolVersion"] as? String,
               declared != actual {
                return "MCP-Protocol-Version '\(declared)' does not match the request body's '\(actual)'"
            }
        }

        return nil
    }

    /// Send a JSON-RPC error frame with an HTTP status, preserving the request id so the client
    /// can correlate it.
    private func sendJSONRPCError(
        context: ChannelHandlerContext,
        status: HTTPResponseStatus,
        requestId: HTTPResponseManager.JSONRPCId?,
        code: Int,
        message: String,
        data: [String: Any]? = nil
    ) {
        var error: [String: Any] = ["code": code, "message": message]
        if let data { error["data"] = data }
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "error": error,
        ]
        switch requestId {
        case .string(let value): payload["id"] = value
        case .number(let value): payload["id"] = value
        case .null, .none: payload["id"] = NSNull()
        }

        let body: String
        if let data = try? JSONSerialization.data(withJSONObject: payload), // silent: a dictionary of literals cannot fail to serialise; the fallback keeps this path total
           let text = String(data: data, encoding: .utf8) {
            body = text
        } else {
            body = #"{"jsonrpc":"2.0","id":null,"error":{"code":\#(code),"message":"error"}}"#
        }
        sendResponse(context: context, status: status, body: body, contentType: "application/json")
    }

    /// Opens the long-lived stream a `subscriptions/listen` request asks for.
    ///
    /// MCP 2026-07-28 replaced the standalone GET stream and `resources/subscribe` with this:
    /// the response to a `subscriptions/listen` POST **is** an SSE stream that stays open and
    /// carries the change notifications the client opted into.
    ///
    /// The acknowledgement is the first event on it, and states the subset the server will
    /// actually honour — narrower than the request when the server has no such source. Saying so
    /// is the point: a client told nothing would wait for notifications that can never arrive.
    ///
    /// Request-scoped notifications — `notifications/progress`, `notifications/message` — do
    /// **not** belong here. They flow on the response stream of the request they relate to.
    private func handleSubscriptionsListen(
        transport: HTTPServerTransport,
        channel: Channel,
        eventLoop: EventLoop,
        context: ChannelHandlerContext,
        requestId: HTTPResponseManager.JSONRPCId?,
        body: [String: Any]
    ) async {
        let subscriptionId = UUID().uuidString

        // Resolved before the stream is registered: what the server agreed to honour is what
        // it will deliver, and the acknowledgement below says the same thing to the client.
        // Deriving it twice would let the two drift.
        let requested = ((body["params"] as? [String: Any])?["notifications"] as? [String: Any]) ?? [:]
        let honoured = Self.honouredSubscriptions(from: requested, producible: subscribableNotifications)

        let connection = NIOHTTPConnection(channel: channel)
        let sseSession = SSESession(connection: connection)
        await transport.subscriptionStreams.register(
            sseSession, id: subscriptionId, honouring: Set(honoured.keys))

        var sseHeaders = HTTPHeaders()
        sseHeaders.add(name: "Content-Type", value: "text/event-stream")
        sseHeaders.add(name: "Cache-Control", value: "no-cache")
        sseHeaders.add(name: "Connection", value: "keep-alive")
        sseHeaders.add(name: "X-Accel-Buffering", value: "no")
        addCORSHeaders(to: &sseHeaders)

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: sseHeaders)

        // Justification: context captured to write the SSE response head; scoped to eventLoop.execute
        nonisolated(unsafe) let unsafeContext = context
        eventLoop.execute {
            unsafeContext.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
            unsafeContext.flush()
        }

        // The acknowledgement, as the first event, tagged with the subscription it belongs to.
        let acknowledgement: [String: Any] = [
            "jsonrpc": "2.0",
            "method": SubscriptionsAcknowledged.name,
            "params": [
                "notifications": honoured,
                "_meta": ["io.modelcontextprotocol/subscriptionId": subscriptionId],
            ],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: acknowledgement), // silent: a dictionary of literals cannot fail to serialise
           let text = String(data: data, encoding: .utf8) {
            await sseSession.sendEvent(data: text)
        }

        logger.info("Subscription stream opened: \(subscriptionId, privacy: .public)")
    }

    /// The subset of requested notifications this server will actually send.
    ///
    /// Tool list changes are honoured. Resource and prompt notifications are not: this package
    /// registers no source that emits them, and claiming them would leave a client waiting for
    /// updates that cannot arrive — worse than declining, because the client cannot tell the
    /// difference between "subscribed and quiet" and "never coming".
    static func honouredSubscriptions(
        from requested: [String: Any], producible: Set<String>
    ) -> [String: Any] {
        var honoured: [String: Any] = [:]
        for kind in producible where requested[kind] as? Bool == true {
            honoured[kind] = true
        }
        return honoured
    }

    private func handleStreamableInitialize(transport: HTTPServerTransport, channel: Channel, requestId: HTTPResponseManager.JSONRPCId?, bodyData: Data) async {
        let newSessionId = await transport.streamableSessionManager.createSession()
        if let reqId = requestId, reqId != .null {
            let connection = NIOHTTPConnection(channel: channel)
            await transport.responseManager.registerRequest(
                requestId: reqId, connection: connection)
            await transport.responseManager.setSessionIdForRequest(reqId, sessionId: newSessionId)
        }
        transport.receiveContinuation.yield(bodyData)
    }

    private func handleStreamableNotification(transport: HTTPServerTransport, context: ChannelHandlerContext, sessionId: String?, bodyData: Data) async {
        if let sid = sessionId {
            guard await transport.streamableSessionManager.validateSession(sid) else {
                sendResponse(context: context, status: .notFound, body: "Session not found")
                return
            }
            await transport.streamableSessionManager.touchSession(sid)
        }
        transport.receiveContinuation.yield(bodyData)
        sendResponse(context: context, status: .accepted, body: "")
    }

    private func handleStreamableRequest(transport: HTTPServerTransport, channel: Channel, context: ChannelHandlerContext, sessionId: String?, requestId: HTTPResponseManager.JSONRPCId?, bodyData: Data, httpRequest: MCP.HTTPRequest? = nil) async {
        if let sid = sessionId {
            guard await transport.streamableSessionManager.validateSession(sid) else {
                sendResponse(context: context, status: .notFound, body: "Session not found")
                return
            }
            await transport.streamableSessionManager.touchSession(sid)
        }
        if let reqId = requestId, reqId != .null {
            let connection = NIOHTTPConnection(channel: channel)
            await transport.responseManager.registerRequest(
                requestId: reqId, connection: connection, httpRequest: httpRequest)
            if let sid = sessionId {
                await transport.responseManager.setSessionIdForRequest(reqId, sessionId: sid)
            }
        }
        transport.receiveContinuation.yield(bodyData)
    }

    /// Handle GET /mcp with Accept: text/event-stream — SSE stream for server-initiated messages
    private func processStreamableSSE(channel: Channel, eventLoop: EventLoop, context: ChannelHandlerContext, headers: HTTPHeaders) async {
        guard let transport = transport else { return }

        // Require Mcp-Session-Id for SSE streams
        guard let sessionId = headers.first(name: "Mcp-Session-Id") else {
            sendResponse(context: context, status: .badRequest, body: "Missing Mcp-Session-Id header")
            return
        }

        guard await transport.streamableSessionManager.validateSession(sessionId) else {
            sendResponse(context: context, status: .notFound, body: "Session not found")
            return
        }

        // Create SSE connection for server-initiated messages
        let connection = NIOHTTPConnection(channel: channel)
        let sseSession = SSESession(connection: connection)

        // Register with session
        await transport.streamableSessionManager.addSSEConnection(sseSession, to: sessionId)

        // Send SSE response headers (no endpoint event — that's the old protocol)
        var sseHeaders = HTTPHeaders()
        sseHeaders.add(name: "Content-Type", value: "text/event-stream")
        sseHeaders.add(name: "Cache-Control", value: "no-cache")
        sseHeaders.add(name: "Connection", value: "keep-alive")
        // Tells reverse proxies not to buffer the stream. Without it a proxy may accumulate
        // events and release them in batches, which turns a stream into a series of stalls.
        sseHeaders.add(name: "X-Accel-Buffering", value: "no")
        sseHeaders.add(name: "Mcp-Session-Id", value: sessionId)
        addCORSHeaders(to: &sseHeaders)

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: sseHeaders)

        // Justification: context captured to write Streamable HTTP SSE response head; scoped to eventLoop.execute
        nonisolated(unsafe) let unsafeContext = context
        eventLoop.execute {
            unsafeContext.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
            unsafeContext.flush()
        }

        logger.info("Streamable HTTP SSE stream opened for session \(sessionId, privacy: .public)")
    }

    /// Handle GET /mcp/sse — Legacy SSE endpoint for backward compatibility
    ///
    /// This endpoint supports the original MCP SSE transport protocol:
    /// 1. Client GETs /mcp/sse to establish SSE stream
    /// 2. Server sends "endpoint" event with POST URL containing session ID
    /// 3. Client POSTs JSON-RPC requests to the endpoint URL
    /// 4. Server sends responses back via the SSE stream
    private func processLegacySSE(channel: Channel, eventLoop: EventLoop, context: ChannelHandlerContext) async {
        guard let transport = transport else { return }

        let sessionId = UUID().uuidString
        let connection = NIOHTTPConnection(channel: channel)
        let session = SSESession(sessionId: sessionId, connection: connection)

        // Register with legacy SSE session manager
        await transport.sseSessionManager.registerSession(session)

        // Send SSE response headers
        var sseHeaders = HTTPHeaders()
        sseHeaders.add(name: "Content-Type", value: "text/event-stream")
        sseHeaders.add(name: "Cache-Control", value: "no-cache")
        sseHeaders.add(name: "Connection", value: "keep-alive")
        // Tells reverse proxies not to buffer the stream; see the note on the streamable path.
        sseHeaders.add(name: "X-Accel-Buffering", value: "no")
        sseHeaders.add(name: "X-Session-ID", value: sessionId)
        addCORSHeaders(to: &sseHeaders)

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: sseHeaders)

        // Justification: context captured to write legacy SSE response head and flush; scoped to eventLoop.execute
        nonisolated(unsafe) let unsafeContext = context
        eventLoop.execute {
            unsafeContext.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
            unsafeContext.flush()
        }

        // Send endpoint event with POST URL
        await session.sendEvent(event: "endpoint", data: "/mcp?sessionId=\(sessionId)")

        logger.info("Legacy SSE connection opened with session \(sessionId, privacy: .public)")
    }

    /// Handle DELETE /mcp — Terminate session
    private func processSessionDelete(context: ChannelHandlerContext, headers: HTTPHeaders) async {
        guard let transport = transport else { return }

        guard let sessionId = headers.first(name: "Mcp-Session-Id") else {
            sendResponse(context: context, status: .badRequest, body: "Missing Mcp-Session-Id header")
            return
        }

        let removed = await transport.streamableSessionManager.removeSession(sessionId)
        if removed {
            sendResponse(context: context, status: .ok, body: "Session terminated")
        } else {
            sendResponse(context: context, status: .notFound, body: "Session not found")
        }
    }

    // MARK: - Authentication

    private func checkAuthorization(headers: HTTPHeaders) async -> Bool {
        // If no authentication is configured, allow all requests
        if authenticator == nil && oauthServer == nil {
            return true
        }

        let authHeader = headers.first(name: "Authorization")

        // Try API key authentication first (if configured)
        // This allows API keys to work even when OAuth is enabled
        if let authenticator = authenticator {
            if await authenticator.validate(authHeader: authHeader) {
                return true
            }
        }

        // Try OAuth Bearer token validation (if OAuth is configured)
        if let handler = oauthHandler, let header = authHeader, header.lowercased().hasPrefix("bearer ") {
            let result = await handler.validateBearerToken(authHeader: header)
            if result.isValid {
                return true
            }
        }

        // If we get here and either auth method is configured, deny access
        if authenticator != nil || oauthServer != nil {
            return false
        }

        return true
    }

    // MARK: - Response Helpers

    private func sendResponse(
        context: ChannelHandlerContext,
        status: HTTPResponseStatus,
        body: String,
        contentType: String = "text/plain"
    ) {
        // Ensure this runs on the EventLoop
        let eventLoop = context.eventLoop
        // Justification: context captured to dispatch generic HTTP response write; scoped to eventLoop.execute
        nonisolated(unsafe) let unsafeContext = context

        eventLoop.execute {
            self._sendResponse(context: unsafeContext, status: status, body: body, contentType: contentType)
        }
    }

    private func _sendResponse(
        context: ChannelHandlerContext,
        status: HTTPResponseStatus,
        body: String,
        contentType: String
    ) {
        let bodyData = body.data(using: .utf8) ?? Data()
        var buffer = context.channel.allocator.buffer(capacity: bodyData.count)
        buffer.writeBytes(bodyData)

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: "\(bodyData.count)")
        headers.add(name: "Connection", value: "close")
        addCORSHeaders(to: &headers)

        let responseHead = HTTPResponseHead(
            version: .http1_1,
            status: status,
            headers: headers
        )

        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        // Don't close - allow HTTP keep-alive for connection reuse
    }

    private func sendCORSPreflightResponse(context: ChannelHandlerContext) {
        // Ensure this runs on the EventLoop
        let eventLoop = context.eventLoop
        // Justification: context captured to dispatch CORS preflight response; scoped to eventLoop.execute
        nonisolated(unsafe) let unsafeContext = context

        eventLoop.execute {
            self._sendCORSPreflightResponse(context: unsafeContext)
        }
    }

    private func _sendCORSPreflightResponse(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        addCORSHeaders(to: &headers)
        headers.add(name: "Access-Control-Max-Age", value: "86400")
        headers.add(name: "Connection", value: "close")

        let responseHead = HTTPResponseHead(
            version: .http1_1,
            status: .noContent,
            headers: headers
        )

        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        // Don't close - allow HTTP keep-alive for connection reuse
    }

    private func addCORSHeaders(to headers: inout HTTPHeaders) {
        headers.add(name: "Access-Control-Allow-Origin", value: "*")
        headers.add(name: "Access-Control-Allow-Methods", value: "GET, POST, DELETE, OPTIONS")
        headers.add(name: "Access-Control-Allow-Headers", value: "Content-Type, Authorization, Mcp-Session-Id")
        headers.add(name: "Access-Control-Expose-Headers", value: "Mcp-Session-Id")
    }

    // MARK: - Utilities

    private func extractRequestId(from data: Data) -> HTTPResponseManager.JSONRPCId? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { // silent: returns nil for non-JSON data
            return nil
        }

        guard let idValue = json["id"] else {
            return .null
        }

        if let stringId = idValue as? String {
            return .string(stringId)
        } else if let numberId = idValue as? Int {
            return .number(numberId)
        } else if idValue is NSNull {
            return .null
        }

        return nil
    }
}
