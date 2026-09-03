import Foundation
import SwiftOAuthCore
import SwiftOAuthProvider
import MCP
#if canImport(os)
import os
#endif

private let mcpLogger = Logger(subsystem: "com.swiftmcp", category: "MCPServer")

// MARK: - MCPServer

/// Main entry point for building and running MCP servers.
///
/// Use the builder pattern to configure the server:
/// ```swift
/// func serve(tools: [any MCPToolHandler]) async throws {
///     try await MCPServer.builder()
///         .serverName("My MCP Server")
///         .serverVersion("1.0.0")
///         .port(8080)
///         .tools(tools)
///         .run()
/// }
/// ```
public enum MCPServer {

    /// Create a new builder for configuring an MCP server.
    public static func builder() -> MCPServerBuilder {
        return MCPServerBuilder()
    }

    /// Parse command-line arguments into a structured representation.
    ///
    /// Recognized flags:
    /// - `--http [port]`: Run HTTP server. The port is optional; without it the value
    ///   from ``MCPServerBuilder/port(_:)`` is used.
    /// - `--tls-cert <path>`: TLS certificate path (PEM)
    /// - `--tls-key <path>`: TLS private key path (PEM)
    /// - `--verbose` / `-v`: Enable verbose logging
    /// - `--generate-key`: Generate a new API key
    /// - `--name <name>`: Name for generated key
    /// - `--list-keys`: List all API keys
    /// - `--revoke-key <prefix>`: Revoke a key by prefix
    /// - `--help` / `-h`: Show help
    public static func parseArguments(_ args: [String]) -> ParsedArguments {
        var parsed = ParsedArguments()

        // Check for key management / help commands first
        if args.contains("--help") || args.contains("-h") {
            parsed.command = .help
            return parsed
        }

        if args.contains("--generate-key") {
            parsed.command = .generateKey
            if let nameIndex = args.firstIndex(of: "--name"),
               nameIndex + 1 < args.count {
                parsed.keyName = args[nameIndex + 1]
            }
            return parsed
        }

        if args.contains("--list-keys") {
            parsed.command = .listKeys
            return parsed
        }

        if let revokeIndex = args.firstIndex(of: "--revoke-key"),
           revokeIndex + 1 < args.count {
            parsed.command = .revokeKey
            parsed.keyPrefix = args[revokeIndex + 1]
            return parsed
        }

        // Server mode
        parsed.command = .server

        // Transport
        // `--http` selects the HTTP transport on its own. A port may follow it, but the
        // flag alone is not an error: the port then comes from `MCPServerBuilder.port(_:)`,
        // matching how `--tls-cert`/`--tls-key` override builder-supplied defaults rather
        // than being the only way to supply them. Anything that is not a valid UInt16 is
        // left for the other flags to parse instead of being swallowed as a port.
        if let httpIndex = args.firstIndex(of: "--http") {
            parsed.transportMode = .http
            if httpIndex + 1 < args.count, let port = UInt16(args[httpIndex + 1]) {
                parsed.port = port
                parsed.explicitPort = port
            }
        }

        // TLS
        if let certIndex = args.firstIndex(of: "--tls-cert"),
           certIndex + 1 < args.count {
            parsed.tlsCertPath = args[certIndex + 1]
        }
        if let keyIndex = args.firstIndex(of: "--tls-key"),
           keyIndex + 1 < args.count {
            parsed.tlsKeyPath = args[keyIndex + 1]
        }

        // Verbose
        if args.contains("--verbose") || args.contains("-v") {
            parsed.verbose = true
        }

        return parsed
    }
}

// MARK: - ParsedArguments

/// Parsed command-line arguments.
public struct ParsedArguments: Sendable {
    /// The command to execute.
    public var command: ServerCommand = .server
    /// Transport mode for server command.
    public var transportMode: TransportModeOption = .stdio
    /// Port for HTTP transport.
    ///
    /// Always populated, defaulting to 8080. Prefer ``explicitPort`` when deciding what to
    /// listen on: this property cannot distinguish a port the caller asked for from the
    /// default, so reading it discards a builder-supplied port.
    public var port: UInt16 = 8080
    /// The port carried by `--http`, or `nil` when the flag named none.
    ///
    /// `nil` means the caller selected HTTP without choosing a port, so the value from
    /// ``MCPServerBuilder/port(_:)`` applies — the same precedence the TLS flags follow.
    public var explicitPort: UInt16? = nil
    /// TLS certificate path.
    public var tlsCertPath: String? = nil
    /// TLS private key path.
    public var tlsKeyPath: String? = nil
    /// Enable verbose logging.
    public var verbose: Bool = false
    /// Key name for --generate-key.
    public var keyName: String? = nil
    /// Key prefix for --revoke-key.
    public var keyPrefix: String? = nil
}

/// Server command parsed from CLI arguments.
public enum ServerCommand: Sendable, Equatable {
    case server
    case generateKey
    case listKeys
    case revokeKey
    case help
}

/// Transport mode for the server.
public enum TransportModeOption: Sendable, Equatable {
    case stdio
    case http
}

// MARK: - MCPServerConfiguration

/// Immutable configuration produced by the builder.
public struct MCPServerConfiguration: Sendable {
    /// Server name reported in MCP server info.
    public let serverName: String
    /// Server version reported in MCP server info.
    public let serverVersion: String
    /// Optional instructions describing server capabilities.
    public let serverInstructions: String?
    /// Port to listen on (HTTP mode).
    public let port: UInt16
    /// Path to TLS certificate chain (PEM format).
    public let tlsCertPath: String?
    /// Path to TLS private key (PEM format).
    public let tlsKeyPath: String?
    /// Enable verbose debug logging.
    public let verbose: Bool
    /// Optional API key authenticator.
    public let authenticator: APIKeyAuthenticator?
    /// Optional OAuth server.
    public let oauthServer: OAuthServer?
    /// Registered tool handlers.
    public let toolHandlers: [any MCPToolHandler]
    /// Optional resource provider.
    public let resourceProvider: (any MCPResourceProvider)?
    /// Optional prompt provider.
    public let promptProvider: (any MCPPromptProvider)?
    /// Read-only HTTP endpoints served alongside the protocol routes.
    public let httpRoutes: [MCPHTTPRoute]
    /// Directory holding the data this server owns: its OAuth database and its API key file.
    ///
    /// Derived from ``serverName`` unless set explicitly. See ``ServerStorageDirectory``.
    public let storageDirectory: URL
}

// MARK: - MCPServerBuilder

/// Builder for constructing an MCPServerConfiguration.
///
/// All setter methods return `self` for fluent chaining:
/// ```swift
/// func serve(handler: any MCPToolHandler) async throws {
///     try await MCPServer.builder()
///         .serverName("My Server")
///         .serverVersion("2.0.0")
///         .port(9090)
///         .tool(handler)
///         .run()
/// }
/// ```
// Justification: all mutable state is only accessed during the build phase before run() is called
public final class MCPServerBuilder: @unchecked Sendable {
    private var _serverName: String = "MCP Server"
    private var _serverVersion: String = "1.0.0"
    private var _serverInstructions: String? = nil
    private var _port: UInt16 = 8080
    private var _tlsCertPath: String? = nil
    private var _tlsKeyPath: String? = nil
    private var _verbose: Bool = false
    private var _authenticator: APIKeyAuthenticator? = nil
    private var _oauthServer: OAuthServer? = nil
    private var _toolHandlers: [any MCPToolHandler] = []
    private var _resourceProvider: (any MCPResourceProvider)? = nil
    private var _promptProvider: (any MCPPromptProvider)? = nil
    private var _httpRoutes: [MCPHTTPRoute] = []
    private var _storageDirectory: URL? = nil

    /// Set the server name.
    @discardableResult
    public func serverName(_ name: String) -> MCPServerBuilder {
        _serverName = name
        return self
    }

    /// Set the server version.
    @discardableResult
    public func serverVersion(_ version: String) -> MCPServerBuilder {
        _serverVersion = version
        return self
    }

    /// Set the server instructions (capability description).
    @discardableResult
    public func serverInstructions(_ instructions: String) -> MCPServerBuilder {
        _serverInstructions = instructions
        return self
    }

    /// Set the HTTP port.
    @discardableResult
    public func port(_ port: UInt16) -> MCPServerBuilder {
        _port = port
        return self
    }

    /// Set TLS certificate and key paths for HTTPS.
    @discardableResult
    public func tls(certPath: String, keyPath: String) -> MCPServerBuilder {
        _tlsCertPath = certPath
        _tlsKeyPath = keyPath
        return self
    }

    /// Enable or disable verbose logging.
    @discardableResult
    public func verbose(_ verbose: Bool) -> MCPServerBuilder {
        _verbose = verbose
        return self
    }

    /// Set the API key authenticator.
    @discardableResult
    public func authenticator(_ authenticator: APIKeyAuthenticator) -> MCPServerBuilder {
        _authenticator = authenticator
        return self
    }

    /// Set the OAuth server.
    @discardableResult
    public func oauthServer(_ server: OAuthServer) -> MCPServerBuilder {
        _oauthServer = server
        return self
    }

    /// Register a single tool handler.
    @discardableResult
    public func tool(_ handler: any MCPToolHandler) -> MCPServerBuilder {
        _toolHandlers.append(handler)
        return self
    }

    /// Register multiple tool handlers.
    @discardableResult
    public func tools(_ handlers: [any MCPToolHandler]) -> MCPServerBuilder {
        _toolHandlers.append(contentsOf: handlers)
        return self
    }

    /// Set the resource provider.
    @discardableResult
    public func resourceProvider(_ provider: any MCPResourceProvider) -> MCPServerBuilder {
        _resourceProvider = provider
        return self
    }

    /// Set the prompt provider.
    @discardableResult
    public func promptProvider(_ provider: any MCPPromptProvider) -> MCPServerBuilder {
        _promptProvider = provider
        return self
    }

    /// Pin the directory holding this server's OAuth database and API key file.
    ///
    /// Defaults to a directory derived from the server's name, which keeps each server's
    /// credentials separate without anyone having to configure it. Set this to survive a rename,
    /// or to place the data somewhere other than the user's home directory.
    ///
    /// - Parameter directory: Directory to store this server's data in.
    @discardableResult
    public func storageDirectory(_ directory: URL) -> MCPServerBuilder {
        _storageDirectory = directory
        return self
    }

    /// Build an immutable configuration from the current builder state.
    public func buildConfiguration() -> MCPServerConfiguration {
        return MCPServerConfiguration(
            serverName: _serverName,
            serverVersion: _serverVersion,
            serverInstructions: _serverInstructions,
            port: _port,
            tlsCertPath: _tlsCertPath,
            tlsKeyPath: _tlsKeyPath,
            verbose: _verbose,
            authenticator: _authenticator,
            oauthServer: _oauthServer,
            toolHandlers: _toolHandlers,
            resourceProvider: _resourceProvider,
            promptProvider: _promptProvider,
            httpRoutes: _httpRoutes,
            storageDirectory: _storageDirectory
                ?? ServerStorageDirectory.directory(forServerName: _serverName)
        )
    }

    /// Serve a read-only HTTP endpoint alongside the protocol routes.
    ///
    /// For clients that speak plain HTTP rather than MCP — a calendar subscription being
    /// the motivating case. Routes are `GET`-only, cannot shadow the protocol's own
    /// paths, and require authentication unless they opt out. See ``MCPHTTPRoute``.
    ///
    /// - Parameter route: The endpoint to serve.
    @discardableResult
    public func httpRoute(_ route: MCPHTTPRoute) -> MCPServerBuilder {
        _httpRoutes.append(route)
        return self
    }

    /// Serve several read-only HTTP endpoints.
    ///
    /// - Parameter routes: The endpoints to serve, in matching order.
    @discardableResult
    public func httpRoutes(_ routes: [MCPHTTPRoute]) -> MCPServerBuilder {
        _httpRoutes.append(contentsOf: routes)
        return self
    }

    /// Build the configuration and run the server.
    ///
    /// This method:
    /// 1. Parses CLI arguments (overriding builder values where flags are present)
    /// 2. Handles key management commands (--generate-key, --list-keys, --revoke-key)
    /// 3. Registers tools with the MCP server
    /// 4. Starts the appropriate transport (stdio or HTTP)
    /// 5. Waits until the server completes
    public func run() async throws {
        let config = buildConfiguration()
        let args = MCPServer.parseArguments(CommandLine.arguments)

        switch args.command {
        case .help:
            MCPServer.printHelp(serverName: config.serverName)
            return
        case .generateKey:
            try await MCPServer.handleGenerateKey(
                name: args.keyName, storageDirectory: config.storageDirectory)
            return
        case .listKeys:
            await MCPServer.handleListKeys(storageDirectory: config.storageDirectory)
            return
        case .revokeKey:
            if let prefix = args.keyPrefix {
                try await MCPServer.handleRevokeKey(
                    prefix: prefix, storageDirectory: config.storageDirectory)
            }
            return
        case .server:
            break
        }

        // An explicit `--http <port>` wins; otherwise the builder's value applies.
        let port = args.explicitPort ?? config.port
        let tlsCertPath = args.tlsCertPath ?? config.tlsCertPath
        let tlsKeyPath = args.tlsKeyPath ?? config.tlsKeyPath

        let toolRegistry = try await registerTools(config: config)
        let server = createMCPServer(config: config)
        await registerServerHandlers(server: server, toolRegistry: toolRegistry, config: config)

        if args.transportMode == .http {
            let (authenticator, oauthServer) = await setupHTTPAuthentication(config: config, port: port)
            let scheme = tlsCertPath != nil ? "HTTPS" : "HTTP"
            MCPServer.writeStderr("Starting \(config.serverName) with \(scheme) transport on port \(port)\n")

            let httpTransport = HTTPServerTransport(
                port: port,
                authenticator: authenticator,
                oauthServer: oauthServer,
                tlsCertPath: tlsCertPath,
                tlsKeyPath: tlsKeyPath,
                serverName: config.serverName,
                serverVersion: config.serverVersion,
                httpRoutes: config.httpRoutes
            )
            try await server.start(transport: httpTransport)
        } else {
            MCPServer.writeStderr("Starting \(config.serverName) with stdio transport\n")
            try await server.start(transport: StdioTransport())
        }

        MCPServer.writeStderr("Server started successfully\n")
        await server.waitUntilCompleted()
    }

    // MARK: - Server Setup Helpers

    /// How long a client may cache `server/discover`.
    ///
    /// Discovery answers what the server *is* — its versions and capabilities — which changes
    /// only on redeploy, so an hour is generous without being stale in practice.
    private static let discoveryCacheLifetimeMs = 3_600_000

    /// How long a client may cache a list result.
    ///
    /// Tools, prompts and resources are registered at startup and do not change while the
    /// process runs, but a minute bounds how long a client can be wrong after a redeploy.
    private static let listCacheLifetimeMs = 60_000

    private func registerTools(config: MCPServerConfiguration) async throws -> ToolDefinitionRegistry {
        let toolRegistry = ToolDefinitionRegistry()
        for handler in config.toolHandlers {
            try await toolRegistry.register(handler.toToolDefinition())
        }
        let toolCount = await toolRegistry.listTools().count
        MCPServer.writeStderr("Registered \(toolCount) tools\n")
        return toolRegistry
    }

    private func createMCPServer(config: MCPServerConfiguration) -> Server {
        Server(
            name: config.serverName,
            version: config.serverVersion,
            instructions: config.serverInstructions,
            capabilities: Server.Capabilities(
                logging: Server.Capabilities.Logging(),
                prompts: Server.Capabilities.Prompts(listChanged: false),
                resources: Server.Capabilities.Resources(subscribe: false, listChanged: false),
                tools: Server.Capabilities.Tools(listChanged: false)
            )
        )
    }

    private func registerServerHandlers(server: Server, toolRegistry: ToolDefinitionRegistry, config: MCPServerConfiguration) async {
        // MCP 2026-07-28 requires servers to implement `server/discover`. It is also the
        // backward-compatibility probe, so registering it is what lets a 2026 client work
        // without the `initialize` handshake while an earlier client keeps using one.
        // Discovery must declare what this server actually handles. Advertising a capability it
        // does not serve, or omitting one it does, both mislead a client that has no handshake
        // to correct the picture — discovery is the only thing it can ask.
        let hasResources = config.resourceProvider != nil
        let hasPrompts = config.promptProvider != nil
        await server.withMethodHandler(Discover.self) { _ in
            Discover.Result(
                supportedVersions: Version.supported.sorted(by: >),
                capabilities: Server.Capabilities(
                    logging: Server.Capabilities.Logging(),
                    prompts: hasPrompts ? Server.Capabilities.Prompts(listChanged: false) : nil,
                    resources: hasResources
                        ? Server.Capabilities.Resources(subscribe: false, listChanged: false) : nil,
                    tools: Server.Capabilities.Tools(listChanged: false)
                ),
                instructions: config.serverInstructions,
                resultType: .complete,
                ttlMs: Self.discoveryCacheLifetimeMs,
                cacheScope: .public
            )
        }

        // MCP 2026-07-28 replaces the HTTP GET endpoint and resources/subscribe with a single
        // opt-in stream. The acknowledgement states the subset the server will actually honour,
        // which is narrower than what a client may ask for: this package registers no
        // subscription sources, so it acknowledges the request without claiming any.
        await server.withMethodHandler(SubscriptionsListen.self) { _ in
            SubscriptionsListen.Result(resultType: .complete)
        }

        await server.withMethodHandler(ListTools.self) { _ in
            let tools = await toolRegistry.listTools()
            return ListTools.Result(
                tools: tools,
                resultType: .complete,
                ttlMs: Self.listCacheLifetimeMs,
                cacheScope: .public
            )
        }

        await server.withMethodHandler(CallTool.self) { request in
            return try await toolRegistry.executeTool(
                name: request.name,
                arguments: request.arguments
            )
        }

        if let resourceProvider = config.resourceProvider {
            await server.withMethodHandler(ListResources.self) { _ in
                let resources = await resourceProvider.listResources()
                return ListResources.Result(
                    resources: resources,
                    resultType: .complete,
                    ttlMs: Self.listCacheLifetimeMs,
                    cacheScope: .public
                )
            }
            await server.withMethodHandler(ReadResource.self) { request in
                return try await resourceProvider.readResource(uri: request.uri)
            }
        }

        if let promptProvider = config.promptProvider {
            await server.withMethodHandler(ListPrompts.self) { _ in
                let prompts = await promptProvider.listPrompts()
                return ListPrompts.Result(
                    prompts: prompts,
                    resultType: .complete,
                    ttlMs: Self.listCacheLifetimeMs,
                    cacheScope: .public
                )
            }
            await server.withMethodHandler(GetPrompt.self) { request in
                let stringArgs: [String: String]? = request.arguments.flatMap { args in
                    let converted = args.reduce(into: [String: String]()) { result, pair in
                        result[pair.key] = "\(pair.value)"
                    }
                    return converted.isEmpty ? nil : converted
                }
                return await promptProvider.getPrompt(name: request.name, arguments: stringArgs)
            }
        }
    }

    private func setupHTTPAuthentication(config: MCPServerConfiguration, port: UInt16) async -> (APIKeyAuthenticator?, OAuthServer?) {
        var authenticator = config.authenticator
        var oauthServer = config.oauthServer

        if authenticator == nil {
            authenticator = await setupAPIKeyAuth(
                existingOAuth: oauthServer, storageDirectory: config.storageDirectory)
        }

        if oauthServer == nil {
            oauthServer = setupOAuth(port: port, storageDirectory: config.storageDirectory)
        }

        return (authenticator, oauthServer)
    }

    private func setupAPIKeyAuth(
        existingOAuth: OAuthServer?, storageDirectory: URL
    ) async -> APIKeyAuthenticator? {
        let envKeysString = ProcessInfo.processInfo.environment["MCP_API_KEYS"] ?? ""
        let envKeys = envKeysString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let authRequired = ProcessInfo.processInfo.environment["MCP_AUTH_REQUIRED"] != "false"

        let keyStore = APIKeyStore(directory: storageDirectory)
        let storedKeyCount = await keyStore.keyCount()
        if storedKeyCount > 0 {
            MCPServer.writeStderr("  Loaded \(storedKeyCount) API key(s) from persistent store\n")
        }

        let auth = APIKeyAuthenticator(keyStore: keyStore, environmentKeys: envKeys, authRequired: authRequired)
        let keyCount = await auth.keyCount()

        if authRequired && existingOAuth == nil {
            if keyCount > 0 {
                MCPServer.writeStderr("  API Key Authentication: ENABLED (\(keyCount) key(s))\n")
            } else {
                MCPServer.writeStderr("  API Key Authentication: ENABLED but NO KEYS configured\n")
            }
        } else if !authRequired {
            MCPServer.writeStderr("  Authentication: DISABLED (MCP_AUTH_REQUIRED=false)\n")
        }

        guard authRequired || keyCount > 0 else { return nil }
        return auth
    }

    private func setupOAuth(port: UInt16, storageDirectory: URL) -> OAuthServer? {
        let oauthEnabled = ProcessInfo.processInfo.environment["MCP_OAUTH_ENABLED"] == "true"
        guard oauthEnabled else {
            MCPServer.writeStderr("  OAuth 2.0: DISABLED\n")
            return nil
        }

        do {
            // Created 0700 and resolved before use: the directory can come from
            // `storageDirectory(_:)`, which accepts any URL a caller supplies.
            let directory = try ServerStorageDirectory.prepare(storageDirectory)
            MCPServer.warnIfLegacyStorageExists(inUse: directory)

            let database = directory.appendingPathComponent("oauth.db")
            let oauthStorage = try OAuthStorage(path: database.path)
            // After opening, because SQLite creates the file 0644 and it holds access tokens.
            ServerStorageDirectory.restrict(fileAt: database)

            let issuer = ProcessInfo.processInfo.environment["MCP_OAUTH_ISSUER"]
                ?? "http://localhost:\(port)"

            // Staging, deliberately, and the reason is written here rather than left to a
            // release note. RFC 8707 validation is strict by default: a token request naming no
            // `resource` is refused with `invalid_target`, and every client written before that
            // names none. Accepting them keeps this server reachable while its clients are
            // migrated to send one.
            //
            // Removing `allowsUnspecified` is the second half and a separate decision, because
            // it changes who can connect rather than what this package depends on. Until then a
            // token issued here is good at every resource, which is worth knowing.
            // Validated: the issuer comes from the environment and becomes the audience tokens
            // are bound to. An unusable one yields an empty known-set rather than a malformed
            // entry, and is reported — a policy built around a value nobody can match would
            // refuse every client for an invisible reason.
            var known: Set<URL> = []
            if let identifier = ServerStorageDirectory.resourceIdentifier(forIssuer: issuer) {
                known.insert(identifier)
            } else {
                mcpLogger.error(
                    "MCP_OAUTH_ISSUER is not an absolute http(s) URL; no resource identifier will be advertised for matching")
            }
            let policy = ResourceIndicatorPolicy(known: known, allowsUnspecified: true)
            let server = OAuthServer(
                storage: oauthStorage, issuer: issuer, resourcePolicy: policy)
            MCPServer.writeStderr("  OAuth 2.0: ENABLED (issuer: \(issuer))\n")
            return server
        } catch {
            mcpLogger.error("OAuth init failed: \(error.localizedDescription, privacy: .public)")
            MCPServer.writeStderr("  OAuth 2.0: FAILED to initialize - \(error.localizedDescription)\n")
            return nil
        }
    }

}

// MARK: - MCPServer Static Helpers

extension MCPServer {

    /// Reports the abandoned shared directory when it is still on disk.
    ///
    /// Every server built on this package used to write into `~/.businessmath-mcp`, so an
    /// upgrade silently repoints a server at an empty directory: its keys and tokens appear to
    /// have vanished. They have not, and this says where they went.
    ///
    /// It deliberately does not move anything. The old directory holds credentials commingled
    /// from every server that ever ran, so there is no single server it can be handed to —
    /// copying it into each would duplicate live keys into several places, where revoking one
    /// would leave the others working.
    ///
    /// - Parameter directory: The directory this server is actually using.
    static func warnIfLegacyStorageExists(inUse directory: URL) {
        // Standardized before it reaches the filesystem: `directory` is public API taking an
        // arbitrary URL, so both sides of the comparison and the probe below are resolved forms
        // rather than whatever the caller wrote.
        let legacy = ServerStorageDirectory.legacySharedDirectory.standardized
        let inUse = directory.standardized
        guard legacy != inUse else { return }

        // Asked of the URL rather than of a string path, matching how the key store probes its
        // own file. A missing directory is the ordinary case — most installations will never
        // have had one — so absence is the answer, not an error to report.
        // silent: a directory that is not there is exactly what this is checking for
        guard (try? legacy.checkResourceIsReachable()) == true else { return }

        writeStderr(
            """
              NOTE: \(legacy.path) still exists. Servers used to share it; this one now
                    uses \(inUse.path). Nothing was moved — the old directory may hold
                    credentials belonging to several servers, so copying them would put live
                    keys in more than one place. Move what this server needs, then remove
                    the rest.

            """)
    }

    /// Thread-safe stderr writer
    static func writeStderr(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }

    /// Handle --generate-key
    static func handleGenerateKey(name: String?, storageDirectory: URL) async throws {
        let keyName = name ?? "API Key \(Date().formatted(.dateTime))"
        let store = APIKeyStore(directory: storageDirectory)
        let key = try await store.generateKey(name: keyName)
        writeStderr("""
        Generated API key for "\(keyName)":

          \(key.key)

        Save this key securely - it cannot be retrieved later.

        """)
    }

    /// Handle --list-keys
    static func handleListKeys(storageDirectory: URL) async {
        let store = APIKeyStore(directory: storageDirectory)
        let summaries = await store.listKeySummaries()

        if summaries.isEmpty {
            writeStderr("No API keys found.\n")
            return
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        writeStderr("API Keys:\n")
        for summary in summaries {
            let lastUsed = summary.lastUsed.map { dateFormatter.string(from: $0) } ?? "never"
            writeStderr("  \(summary.prefix)  \(summary.name)  (last used: \(lastUsed))\n")
        }
    }

    /// Handle --revoke-key
    static func handleRevokeKey(prefix: String, storageDirectory: URL) async throws {
        let store = APIKeyStore(directory: storageDirectory)
        let revoked = try await store.revokeKey(prefix: prefix)
        if revoked {
            writeStderr("Key revoked successfully.\n")
        } else {
            writeStderr("No key found with prefix: \(prefix)\n")
        }
    }

    /// Print help text
    static func printHelp(serverName: String) {
        writeStderr("""
        \(serverName)

        USAGE:
          <binary> [OPTIONS]

        SERVER OPTIONS:
          --http [port]           Run HTTP server (port optional; defaults to the
                                  port supplied to the builder, else 8080)
          --tls-cert <path>       Path to TLS certificate chain (PEM format)
          --tls-key <path>        Path to TLS private key (PEM format)
          --verbose, -v           Enable verbose debug logging
          (default)               Run stdio server

        KEY MANAGEMENT:
          --generate-key          Generate a new API key
            --name <name>         Optional name for the key
          --list-keys             List all API keys
          --revoke-key <prefix>   Revoke a key by its prefix

        ENVIRONMENT:
          LOG_LEVEL               Set log level (trace, debug, info, warning, error)
          MCP_OAUTH_ENABLED       Set to "true" to enable OAuth 2.0
          MCP_OAUTH_ISSUER        OAuth issuer URL (default: http://localhost:<port>)
          MCP_API_KEYS            Comma-separated API keys (legacy)
          MCP_AUTH_REQUIRED       Set to "false" to disable authentication

        """)
    }
}
