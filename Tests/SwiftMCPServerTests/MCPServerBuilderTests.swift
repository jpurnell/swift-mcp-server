import Testing
import Foundation
import MCP
@testable import SwiftMCPServer

// MARK: - Test Tool Handler

/// Minimal tool handler for testing
struct EchoToolHandler: MCPToolHandler {
    let tool = MCPTool(
        name: "echo",
        description: "Echoes the input",
        inputSchema: MCPToolInputSchema(
            type: "object",
            properties: [
                "message": MCPSchemaProperty(type: "string", description: "Message to echo")
            ],
            required: ["message"]
        )
    )

    func execute(arguments: [String: AnyCodable]?) async throws -> MCPToolCallResult {
        let message = try arguments?.getString("message") ?? "empty"
        return .success(text: message)
    }
}

/// Another minimal tool for testing multiple registrations
struct AddToolHandler: MCPToolHandler {
    let tool = MCPTool(
        name: "add",
        description: "Adds two numbers",
        inputSchema: MCPToolInputSchema(
            type: "object",
            properties: [
                "a": MCPSchemaProperty(type: "number", description: "First number"),
                "b": MCPSchemaProperty(type: "number", description: "Second number")
            ],
            required: ["a", "b"]
        )
    )

    func execute(arguments: [String: AnyCodable]?) async throws -> MCPToolCallResult {
        let a = try arguments?.getDouble("a") ?? 0
        let b = try arguments?.getDouble("b") ?? 0
        return .success(text: "\(a + b)")
    }
}

// MARK: - Builder Tests

@Suite("MCPServer Builder Tests")
struct MCPServerBuilderTests {

    // MARK: - Builder Configuration

    @Test("Builder sets server name")
    func builderSetsServerName() {
        let config = MCPServer.builder()
            .serverName("Test Server")
            .buildConfiguration()

        #expect(config.serverName == "Test Server")
    }

    @Test("Builder sets server version")
    func builderSetsServerVersion() {
        let config = MCPServer.builder()
            .serverVersion("1.2.3")
            .buildConfiguration()

        #expect(config.serverVersion == "1.2.3")
    }

    @Test("Builder sets server instructions")
    func builderSetsServerInstructions() {
        let config = MCPServer.builder()
            .serverInstructions("Use this server for testing.")
            .buildConfiguration()

        #expect(config.serverInstructions == "Use this server for testing.")
    }

    @Test("Builder sets port")
    func builderSetsPort() {
        let config = MCPServer.builder()
            .port(9999)
            .buildConfiguration()

        #expect(config.port == 9999)
    }

    @Test("Builder default port is 8080")
    func builderDefaultPort() {
        let config = MCPServer.builder()
            .buildConfiguration()

        #expect(config.port == 8080)
    }

    @Test("Builder sets TLS paths")
    func builderSetsTLS() {
        let config = MCPServer.builder()
            .tls(certPath: "/path/to/cert.pem", keyPath: "/path/to/key.pem")
            .buildConfiguration()

        #expect(config.tlsCertPath == "/path/to/cert.pem")
        #expect(config.tlsKeyPath == "/path/to/key.pem")
    }

    @Test("Builder defaults have no TLS")
    func builderDefaultNoTLS() {
        let config = MCPServer.builder()
            .buildConfiguration()

        #expect(config.tlsCertPath == nil)
        #expect(config.tlsKeyPath == nil)
    }

    @Test("Builder enables verbose logging")
    func builderVerbose() {
        let config = MCPServer.builder()
            .verbose(true)
            .buildConfiguration()

        #expect(config.verbose == true)
    }

    @Test("Builder default is not verbose")
    func builderDefaultNotVerbose() {
        let config = MCPServer.builder()
            .buildConfiguration()

        #expect(config.verbose == false)
    }

    // MARK: - Tool Registration

    @Test("Builder registers a single tool handler")
    func builderRegistersSingleTool() {
        let config = MCPServer.builder()
            .tool(EchoToolHandler())
            .buildConfiguration()

        #expect(config.toolHandlers.count == 1)
        #expect(config.toolHandlers[0].tool.name == "echo")
    }

    @Test("Builder registers multiple tool handlers with tools()")
    func builderRegistersMultipleTools() {
        let config = MCPServer.builder()
            .tools([EchoToolHandler(), AddToolHandler()])
            .buildConfiguration()

        #expect(config.toolHandlers.count == 2)
        let names = Set(config.toolHandlers.map { $0.tool.name })
        #expect(names.contains("echo"))
        #expect(names.contains("add"))
    }

    @Test("Builder accumulates tools across multiple calls")
    func builderAccumulatesTools() {
        let config = MCPServer.builder()
            .tool(EchoToolHandler())
            .tool(AddToolHandler())
            .buildConfiguration()

        #expect(config.toolHandlers.count == 2)
    }

    @Test("Builder accumulates tools() and tool() calls")
    func builderAccumulatesMixedCalls() {
        let config = MCPServer.builder()
            .tools([EchoToolHandler()])
            .tool(AddToolHandler())
            .buildConfiguration()

        #expect(config.toolHandlers.count == 2)
    }

    // MARK: - Authentication

    @Test("Builder sets API key authenticator")
    func builderSetsAuthenticator() throws {
        let auth = APIKeyAuthenticator(apiKeys: ["test-key"])
        let config = MCPServer.builder()
            .authenticator(auth)
            .buildConfiguration()

        _ = try #require(config.authenticator)
    }

    @Test("Builder default has no authenticator")
    func builderDefaultNoAuth() {
        let config = MCPServer.builder()
            .buildConfiguration()

        #expect(config.authenticator == nil)
    }

    // MARK: - Builder Chaining

    @Test("Builder supports full method chaining")
    func builderFullChaining() throws {
        let auth = APIKeyAuthenticator(apiKeys: ["key"])
        let config = MCPServer.builder()
            .serverName("My Server")
            .serverVersion("1.0.0")
            .serverInstructions("Instructions here")
            .port(3000)
            .tls(certPath: "/cert.pem", keyPath: "/key.pem")
            .verbose(true)
            .authenticator(auth)
            .tool(EchoToolHandler())
            .tools([AddToolHandler()])
            .buildConfiguration()

        #expect(config.serverName == "My Server")
        #expect(config.serverVersion == "1.0.0")
        #expect(config.serverInstructions == "Instructions here")
        #expect(config.port == 3000)
        #expect(config.tlsCertPath == "/cert.pem")
        #expect(config.tlsKeyPath == "/key.pem")
        #expect(config.verbose == true)
        _ = try #require(config.authenticator)
        #expect(config.toolHandlers.count == 2)
    }

    // MARK: - Default Server Name/Version

    @Test("Builder has sensible defaults for name and version")
    func builderDefaults() {
        let config = MCPServer.builder()
            .buildConfiguration()

        #expect(config.serverName == "MCP Server")
        #expect(config.serverVersion == "1.0.0")
        #expect(config.serverInstructions == nil)
    }
}

// MARK: - Test Resource/Prompt Providers

/// Minimal resource provider for testing
struct TestResourceProvider: MCPResourceProvider {
    func listResources() async -> [Resource] {
        return [
            Resource(
                name: "Test Resource",
                uri: "test://resource",
                description: "A test resource",
                mimeType: "text/plain"
            )
        ]
    }

    func readResource(uri: String) async throws -> ReadResource.Result {
        return ReadResource.Result(contents: [
            .text("Test content", uri: uri, mimeType: "text/plain")
        ])
    }
}

/// Minimal prompt provider for testing
struct TestPromptProvider: MCPPromptProvider {
    func listPrompts() async -> [Prompt] {
        return [
            Prompt(
                name: "test_prompt",
                description: "A test prompt",
                arguments: [
                    Prompt.Argument(name: "input", description: "Test input", required: true)
                ]
            )
        ]
    }

    func getPrompt(name: String, arguments: [String: String]?) async -> GetPrompt.Result {
        return GetPrompt.Result(
            description: "Test prompt result",
            messages: [
                .user(.text(text: "Hello from test prompt"))
            ]
        )
    }
}

// MARK: - Resource/Prompt Provider Builder Tests

@Suite("Resource/Prompt Provider Builder Tests")
struct ProviderBuilderTests {

    @Test("Builder sets resource provider")
    func builderSetsResourceProvider() throws {
        let config = MCPServer.builder()
            .resourceProvider(TestResourceProvider())
            .buildConfiguration()

        _ = try #require(config.resourceProvider)
    }

    @Test("Builder default has no resource provider")
    func builderDefaultNoResourceProvider() {
        let config = MCPServer.builder()
            .buildConfiguration()

        #expect(config.resourceProvider == nil)
    }

    @Test("Builder sets prompt provider")
    func builderSetsPromptProvider() throws {
        let config = MCPServer.builder()
            .promptProvider(TestPromptProvider())
            .buildConfiguration()

        _ = try #require(config.promptProvider)
    }

    @Test("Builder default has no prompt provider")
    func builderDefaultNoPromptProvider() {
        let config = MCPServer.builder()
            .buildConfiguration()

        #expect(config.promptProvider == nil)
    }

    @Test("Builder supports resource and prompt providers in chain")
    func builderChainsProviders() throws {
        let config = MCPServer.builder()
            .serverName("Provider Test")
            .tool(EchoToolHandler())
            .resourceProvider(TestResourceProvider())
            .promptProvider(TestPromptProvider())
            .buildConfiguration()

        #expect(config.serverName == "Provider Test")
        #expect(config.toolHandlers.count == 1)
        _ = try #require(config.resourceProvider)
        _ = try #require(config.promptProvider)
    }
}

// MARK: - MCPServerConfiguration Tests

@Suite("MCPServerConfiguration Tests")
struct MCPServerConfigurationTests {

    @Test("Configuration is Sendable")
    func configurationIsSendable() async {
        let config = MCPServer.builder()
            .serverName("Sendable Test")
            .buildConfiguration()

        // Verify we can pass it across isolation boundaries
        let name = await Task {
            config.serverName
        }.value

        #expect(name == "Sendable Test")
    }

    @Test("Configuration stores tool handlers")
    func configurationStoresHandlers() {
        let config = MCPServer.builder()
            .tool(EchoToolHandler())
            .tool(AddToolHandler())
            .buildConfiguration()

        #expect(config.toolHandlers.count == 2)
    }
}

// MARK: - CLI Argument Parsing Tests

@Suite("CLI Argument Parsing Tests")
struct CLIArgumentParsingTests {

    @Test("Parse --http flag with port")
    func parseHTTPPort() {
        let args = ["server", "--http", "9090"]
        let parsed = MCPServer.parseArguments(args)

        #expect(parsed.port == 9090)
        #expect(parsed.transportMode == .http)
    }

    @Test("Parse --tls-cert and --tls-key flags")
    func parseTLSFlags() {
        let args = ["server", "--http", "8080", "--tls-cert", "/path/cert.pem", "--tls-key", "/path/key.pem"]
        let parsed = MCPServer.parseArguments(args)

        #expect(parsed.tlsCertPath == "/path/cert.pem")
        #expect(parsed.tlsKeyPath == "/path/key.pem")
    }

    @Test("Parse --verbose flag")
    func parseVerbose() {
        let args = ["server", "--http", "8080", "--verbose"]
        let parsed = MCPServer.parseArguments(args)

        #expect(parsed.verbose == true)
    }

    @Test("Parse -v flag")
    func parseShortVerbose() {
        let args = ["server", "--http", "8080", "-v"]
        let parsed = MCPServer.parseArguments(args)

        #expect(parsed.verbose == true)
    }

    @Test("--http with no port selects HTTP and defers the port to the builder")
    func httpWithoutPortSelectsHTTP() {
        let parsed = MCPServer.parseArguments(["server", "--http"])

        #expect(parsed.transportMode == .http)
        #expect(parsed.explicitPort == nil, "no port on the flag means the builder's value should win")
    }

    @Test("--http with a trailing non-numeric argument selects HTTP without consuming it")
    func httpWithNonNumericNextArgument() {
        let parsed = MCPServer.parseArguments(["server", "--http", "--verbose"])

        #expect(parsed.transportMode == .http)
        #expect(parsed.explicitPort == nil)
        #expect(parsed.verbose == true, "--verbose must still be parsed, not swallowed as a port")
    }

    @Test("--http with a port records it as explicit")
    func httpWithPortIsExplicit() {
        let parsed = MCPServer.parseArguments(["server", "--http", "9090"])

        #expect(parsed.transportMode == .http)
        #expect(parsed.explicitPort == 9090)
        #expect(parsed.port == 9090, "port stays populated for existing callers")
    }

    @Test("A port too large for UInt16 is not treated as an explicit port")
    func httpWithOutOfRangePort() {
        let parsed = MCPServer.parseArguments(["server", "--http", "99999"])

        #expect(parsed.transportMode == .http)
        #expect(parsed.explicitPort == nil)
    }

    @Test("Default transport mode is stdio")
    func defaultTransportIsStdio() {
        let args = ["server"]
        let parsed = MCPServer.parseArguments(args)

        #expect(parsed.transportMode == .stdio)
    }

    @Test("Parse --generate-key command")
    func parseGenerateKey() {
        let args = ["server", "--generate-key", "--name", "Test Key"]
        let parsed = MCPServer.parseArguments(args)

        #expect(parsed.command == .generateKey)
        #expect(parsed.keyName == "Test Key")
    }

    @Test("Parse --list-keys command")
    func parseListKeys() {
        let args = ["server", "--list-keys"]
        let parsed = MCPServer.parseArguments(args)

        #expect(parsed.command == .listKeys)
    }

    @Test("Parse --revoke-key command")
    func parseRevokeKey() {
        let args = ["server", "--revoke-key", "bm_abc"]
        let parsed = MCPServer.parseArguments(args)

        #expect(parsed.command == .revokeKey)
        #expect(parsed.keyPrefix == "bm_abc")
    }

    @Test("Parse --help command")
    func parseHelp() {
        let args = ["server", "--help"]
        let parsed = MCPServer.parseArguments(args)

        #expect(parsed.command == .help)
    }

    @Test("Parse -h shorthand for help")
    func parseShortHelp() {
        let args = ["server", "-h"]
        let parsed = MCPServer.parseArguments(args)

        #expect(parsed.command == .help)
    }
}
