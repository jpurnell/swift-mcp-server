import Foundation
import SwiftOAuthCore
import SwiftOAuthProvider
import MCP
import Logging
#if canImport(os)
import os
#endif
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOHTTP1
@preconcurrency import NIOSSL

// OAuth must be imported after Foundation
// Import OAuth types


/// HTTP server transport for MCP using SwiftNIO (Streamable HTTP, spec 2025-03-26)
///
/// This transport implements MCP Streamable HTTP:
/// - Cross-platform (macOS, Linux) using SwiftNIO
/// - Listens on a specified port
/// - POST /mcp - JSON-RPC requests, returns JSON response with Mcp-Session-Id header
/// - GET /mcp (Accept: text/event-stream) - SSE stream for server-initiated messages
/// - DELETE /mcp - Terminate session
///
/// Architecture:
/// 1. Client POSTs initialize to /mcp, receives JSON response with Mcp-Session-Id
/// 2. Client includes Mcp-Session-Id header on all subsequent requests
/// 3. Server routes responses directly as JSON via HTTPResponseManager
public actor HTTPServerTransport: Transport, HTTPContextProviding {
    /// Logger required by MCP Transport protocol (swift-log)
    public let logger: Logging.Logger

    /// os.Logger for transport-level diagnostics
    private let osLogger: os.Logger

    private let port: UInt16

    // SwiftNIO server components
    private var serverChannel: Channel?
    private var eventLoopGroup: MultiThreadedEventLoopGroup?

    private let receiveStream: AsyncThrowingStream<Data, Error>

    /// Receive continuation - accessible to handler for forwarding requests
    internal let receiveContinuation: AsyncThrowingStream<Data, Error>.Continuation

    /// Response manager - accessible to handler for routing responses
    internal let responseManager: HTTPResponseManager

    /// SSE session manager (legacy, kept for backward compat)
    internal let sseSessionManager: SSESessionManager

    /// Streamable HTTP session manager (MCP 2025-03-26)
    internal let streamableSessionManager: StreamableSessionManager
    /// The open `subscriptions/listen` streams.
    public let subscriptionStreams: SubscriptionStreamRegistry

    private let authenticator: APIKeyAuthenticator?

    /// OAuth server for OAuth 2.0 authentication (optional)
    internal let oauthServer: OAuthServer?

    /// TLS certificate and key paths (optional, enables HTTPS)
    private let tlsCertPath: String?
    private let tlsKeyPath: String?

    /// Server name and version from configuration
    internal let serverName: String
    internal let serverVersion: String

    /// Consumer-registered read-only endpoints, and the reserved paths they cannot claim.
    internal let routeTable: HTTPRouteTable

    /// Which `Host` and `Origin` values this server will answer.
    internal let allowedHosts: AllowedHosts

    /// Per-tool custom header parameters, from the tools' `x-mcp-header` annotations.
    internal let customHeaderParameters: CustomHeaderParameters

    /// The change notifications this server can actually produce.
    internal let subscribableNotifications: Set<String>

    /// Initialize HTTP server transport
    /// - Parameters:
    ///   - port: Port number to listen on (default: 8080)
    ///   - authenticator: Optional API key authenticator (if nil, no auth required)
    ///   - oauthServer: Optional OAuth server for OAuth 2.0 authentication
    ///   - tlsCertPath: Path to TLS certificate chain (PEM format)
    ///   - tlsKeyPath: Path to TLS private key (PEM format)
    ///   - serverName: Server name for MCP protocol responses
    ///   - serverVersion: Server version for MCP protocol responses
    ///   - httpRoutes: Read-only `GET` endpoints served alongside the protocol routes.
    ///   - allowedHosts: Which `Host`/`Origin` values to answer. See ``AllowedHosts``.
    ///   - subscribableNotifications: Which `subscriptions/listen` notification kinds this
    ///     server can actually emit — `toolsListChanged`, `promptsListChanged`,
    ///     `resourcesListChanged`. A subscription to anything outside this set is acknowledged
    ///     as *not* honoured, because promising updates that cannot arrive is worse than
    ///     declining: the client cannot tell "subscribed and quiet" from "never coming". The
    ///     default is tools alone, which every server can produce.
    ///   - tools: The tools this server serves, read only for their `x-mcp-header` annotations
    ///     (SEP-2243). Supplied here because the check is a *transport* rule — the header and
    ///     the body must agree before anything dispatches — and the transport cannot otherwise
    ///     know which arguments a tool mirrors into headers.
    public init(
        port: UInt16 = 8080,
        authenticator: APIKeyAuthenticator? = nil,
        oauthServer: OAuthServer? = nil,
        tlsCertPath: String? = nil,
        tlsKeyPath: String? = nil,
        serverName: String = "MCP Server",
        serverVersion: String = "1.0.0",
        httpRoutes: [MCPHTTPRoute] = [],
        allowedHosts: AllowedHosts = .any,
        tools: [Tool] = [],
        subscribableNotifications: Set<String> = ["toolsListChanged"]
    ) {
        self.subscribableNotifications = subscribableNotifications
        self.allowedHosts = allowedHosts
        self.customHeaderParameters = CustomHeaderParameters(tools: tools)
        self.port = port
        self.logger = Logging.Logger(label: "http-server-transport")
        self.osLogger = os.Logger(subsystem: "com.swiftmcp", category: "HTTPServerTransport")
        self.authenticator = authenticator
        self.oauthServer = oauthServer
        self.tlsCertPath = tlsCertPath
        self.tlsKeyPath = tlsKeyPath
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.routeTable = HTTPRouteTable(routes: httpRoutes)
        self.responseManager = HTTPResponseManager()
        self.sseSessionManager = SSESessionManager()
        self.streamableSessionManager = StreamableSessionManager()
        self.subscriptionStreams = SubscriptionStreamRegistry()

        // Create receive stream
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        self.receiveStream = AsyncThrowingStream { cont in
            continuation = cont
        }
        self.receiveContinuation = continuation
    }

    /// The HTTP request that carried a JSON-RPC request, while it is still in flight.
    ///
    /// `withMethodHandler` takes decoded parameters and nothing else, which is right for almost
    /// everything: a tool should not care how it was reached. Some rules are *about* the
    /// transport though — SEP-2243's custom `x-mcp-header` parameters must be checked against
    /// the headers that carried them — and this is how a handler reaches them, through
    /// `Server.currentHandlerContext`.
    ///
    /// - Parameter id: The JSON-RPC request id.
    /// - Returns: The originating HTTP request, or `nil` once its response has been delivered.
    public func httpRequestContext(for id: ID) async -> MCP.HTTPRequest? {
        let requestId: HTTPResponseManager.JSONRPCId
        switch id {
        case .string(let value): requestId = .string(value)
        case .number(let value): requestId = .number(value)
        }
        return await responseManager.httpRequest(for: requestId)
    }

    /// Starts the HTTP server and begins listening for connections
    public func connect() async throws {
        // Start response manager cleanup task
        await responseManager.startCleanup()

        // Start SSE session maintenance (cleanup + heartbeat)
        await sseSessionManager.startMaintenance()

        // Start streamable session maintenance
        await streamableSessionManager.startMaintenance()

        // Create event loop group
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.eventLoopGroup = group

        // Configure TLS if certificate and key paths are provided
        var sslContext: NIOSSLContext? = nil
        if let certPath = tlsCertPath, let keyPath = tlsKeyPath {
            let certificateChain = try NIOSSLCertificate.fromPEMFile(certPath)
            let privateKey = try NIOSSLPrivateKey(file: keyPath, format: .pem)
            var tlsConfig = TLSConfiguration.makeServerConfiguration(
                certificateChain: certificateChain.map { .certificate($0) },
                privateKey: .privateKey(privateKey)
            )
            tlsConfig.minimumTLSVersion = .tlsv12
            sslContext = try NIOSSLContext(configuration: tlsConfig)
            osLogger.info("TLS enabled with cert: \(certPath, privacy: .public)")
        }

        // Configure and bind server with SwiftNIO
        do {
            let bootstrap = NIOPosix.ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { [sslContext] channel in
                    do {
                        if let sslContext = sslContext {
                            let sslHandler = NIOSSLServerHandler(context: sslContext)
                            try channel.pipeline.syncOperations.addHandler(sslHandler)
                        }
                        let decoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .dropBytes))
                        try channel.pipeline.syncOperations.addHandler(decoder)
                        let encoder = HTTPResponseEncoder()
                        try channel.pipeline.syncOperations.addHandler(encoder)
                        let handler = MCPServerHandler(transport: self, authenticator: self.authenticator, oauthServer: self.oauthServer, serverName: self.serverName, serverVersion: self.serverVersion, routeTable: self.routeTable, allowedHosts: self.allowedHosts, customHeaderParameters: self.customHeaderParameters, subscribableNotifications: self.subscribableNotifications)
                        try channel.pipeline.syncOperations.addHandler(handler)
                        return channel.eventLoop.makeSucceededVoidFuture()
                    } catch {
                        self.osLogger.error("Failed to configure channel pipeline: \(error, privacy: .public)")
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
            let channel: Channel = try await bootstrap.bind(host: "0.0.0.0", port: Int(port)).get()
            self.serverChannel = channel

            let scheme = sslContext != nil ? "HTTPS" : "HTTP"
            osLogger.info("\(scheme, privacy: .public) server listening on port \(self.port, privacy: .public)")
        } catch {
            osLogger.error("Failed to bind to port \(self.port, privacy: .public): \(error, privacy: .public)")
            try? await group.shutdownGracefully() // silent: cleanup during error path, best-effort
            throw HTTPServerError.failedToCreateListener
        }
    }

    /// Gracefully shuts down the server and all active sessions
    public func disconnect() async {
        // Stop response manager cleanup task
        await responseManager.stopCleanup()

        // Shutdown SSE sessions
        await sseSessionManager.shutdown()

        // Shutdown streamable sessions
        await streamableSessionManager.shutdown()

        // Close server channel
        if let channel = serverChannel {
            try? await channel.close() // silent: channel may already be closed
            serverChannel = nil
        }

        // Shutdown event loop group
        if let group = eventLoopGroup {
            do {
                try await group.shutdownGracefully()
            } catch {
                osLogger.error("Error shutting down event loop group: \(error.localizedDescription, privacy: .public)")
            }
            eventLoopGroup = nil
        }

        // Finish receive stream
        receiveContinuation.finish()
    }

    /// Routes outgoing response data to the appropriate client connection
    public func send(_ data: Data) async throws {
        // Anything the server emits *while handling a request* belongs on that request's
        // response stream: a question it needs answered before it can finish (the pre-2026
        // sampling/elicitation channel), and equally the progress and log notifications that
        // describe the work in flight. Which request that is comes from the SDK's per-dispatch
        // task-local — the outgoing bytes carry no back-reference to what provoked them.
        //
        // Request-scoped, not broadcast: a progress notification means nothing except in
        // relation to the call that is producing it, and a client that did not make that call
        // has no way to attribute it.
        if Self.belongsToInFlightRequest(data), let origin = Server.currentHandlerContext?.id {
            let requestId: HTTPResponseManager.JSONRPCId
            switch origin {
            case .string(let value): requestId = .string(value)
            case .number(let value): requestId = .number(value)
            }
            await responseManager.beginStreaming(for: requestId)
            if await responseManager.sendEvent(for: requestId, message: data) { return }
        }

        // Primary path: route through HTTP response manager (Streamable HTTP)
        let httpRouted = await responseManager.routeResponse(data)

        if httpRouted {
            return
        }

        // Fallback: broadcast to SSE streams (for server-initiated messages)
        let sseRouted = await streamableSessionManager.broadcastToAllSSE(data)

        if !sseRouted {
            // Try legacy SSE manager as last resort
            let legacyRouted = await sseSessionManager.routeResponse(data)
            if !legacyRouted {
                osLogger.warning("Failed to route response (\(data.count, privacy: .public) bytes) - no pending request found")
            }
        }
    }

    /// Notification methods that describe an in-flight request rather than the server at large.
    ///
    /// The change notifications — tools/prompts/resources list-changed — are deliberately absent:
    /// those are facts about the server, they reach subscribers through `subscriptions/listen`,
    /// and attributing one to whichever request happened to be open when it fired would be
    /// wrong.
    private static let requestScopedNotifications: Set<String> = [
        "notifications/progress", "notifications/message",
    ]

    /// Whether an outgoing message belongs to the request currently being handled.
    ///
    /// Two kinds do. A **request** the server is making of the client carries `method` and an
    /// `id`, and has to reach the client before this server can finish. A **request-scoped
    /// notification** — progress, or a log line — carries `method` and no id, and is meaningless
    /// except beside the call producing it.
    ///
    /// A response has neither and is routed by id in the ordinary way.
    ///
    /// - Parameter data: The outgoing message.
    /// - Returns: `true` when it belongs on the in-flight request's stream.
    private static func belongsToInFlightRequest(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], // silent: a body that will not parse is routed by the paths below, which log
            let method = json["method"] as? String
        else { return false }

        if json["id"] != nil { return true }
        return requestScopedNotifications.contains(method)
    }

    /// Returns the stream of incoming request data from clients
    public func receive() -> AsyncThrowingStream<Data, Error> {
        return receiveStream
    }
}

// MARK: - Supporting Types

enum HTTPServerError: Error, LocalizedError {
    case failedToCreateListener
    case notConnected

    var errorDescription: String? {
        switch self {
        case .failedToCreateListener:
            return "Failed to create network listener"
        case .notConnected:
            return "HTTP server is not connected"
        }
    }
}
