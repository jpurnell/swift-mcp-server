# Getting Started with SwiftMCPServer

Build and run an MCP server that exposes a tool over stdio or HTTP.

## Overview

This article covers adding the package, writing a tool handler, assembling a
server with the builder, and selecting a transport at launch.

### Add the Package

Add SwiftMCPServer to your `Package.swift`:

<!-- docs:illustrative -->
```swift
dependencies: [
    .package(url: "https://github.com/jpurnell/SwiftMCPServer", from: "0.1.0")
]
```

Then add it to your target's dependencies and import it:

```swift
import SwiftMCPServer
```

### Write a Tool Handler

A tool is any `Sendable` type conforming to ``MCPToolHandler``. The ``MCPTool``
value describes the tool to clients, and `execute(arguments:)` performs the work:

```swift
import SwiftMCPServer

struct GreetTool: MCPToolHandler {
    var tool: MCPTool {
        MCPTool(
            name: "greet",
            description: "Return a greeting for the supplied name.",
            inputSchema: MCPToolInputSchema(
                properties: [
                    "name": MCPSchemaProperty(
                        type: "string",
                        description: "The name to greet."
                    )
                ],
                required: ["name"]
            )
        )
    }

    func execute(arguments: [String: AnyCodable]?) async throws -> MCPToolCallResult {
        guard let arguments else {
            throw ToolError.missingRequiredArgument("name")
        }
        let name = try arguments.getString("name")
        return .success(text: "Hello, \(name)!")
    }
}
```

Arguments arrive as `[String: AnyCodable]`. Typed accessors such as
`getString(_:)`, `getInt(_:)`, `getDouble(_:)`, and `getDoubleArray(_:)` throw
``ToolError/missingRequiredArgument(_:)`` or ``ToolError/invalidArguments(_:)``
rather than trapping, so a malformed request becomes an error result instead of
a crash.

### Assemble and Run the Server

``MCPServer/builder()`` returns an ``MCPServerBuilder``. Every setter returns
`self`, so configuration chains:

```swift
func startServer() async throws {
    try await MCPServer.builder()
        .serverName("My MCP Server")
        .serverVersion("1.0.0")
        .serverInstructions("Greets people by name.")
        .tool(GreetTool())
        .run()
}
```

In a real executable target, place that call in your `@main` entry point's
`main()` method.

``MCPServerBuilder/run()`` builds an ``MCPServerConfiguration``, registers the
tools in a ``ToolDefinitionRegistry``, wires the MCP method handlers, starts the
transport, and then waits until the server completes.

To inspect the configuration without starting anything — in tests, for example —
call ``MCPServerBuilder/buildConfiguration()`` instead.

### Choose a Transport

The transport is selected by command-line arguments, not by the builder. Running
the binary with no flags starts a stdio server:

```
$ my-server
```

Passing `--http` with a port starts the SwiftNIO HTTP transport on that port:

```
$ my-server --http 8080
```

Add `--tls-cert` and `--tls-key` to serve over HTTPS. Both PEM paths are
required for TLS:

```
$ my-server --http 8443 --tls-cert /path/cert.pem --tls-key /path/key.pem
```

``MCPServerBuilder/tls(certPath:keyPath:)`` supplies TLS defaults that the
`--tls-cert` and `--tls-key` flags override, and ``MCPServerBuilder/port(_:)``
now behaves the same way. `--http` selects the transport; the port after it is
optional, and when it is omitted the builder's port applies:

```swift
func startServerOnBuilderPort() async throws {
    try await MCPServer.builder()
        .serverName("My MCP Server")
        .port(9000)          // used when the binary is run as `my-server --http`
        .tool(GreetTool())
        .run()
}
```

Passing a port explicitly — `my-server --http 8080` — overrides it. Without
`--http` at all, the server runs over stdio and no port is opened.

### Serve Resources and Prompts

Tools are optional companions to resources and prompts. Conform a type to
``MCPResourceProvider`` or ``MCPPromptProvider`` and attach it to the builder;
the corresponding MCP method handlers are registered only when a provider is
present:

```swift
import MCP
import SwiftMCPServer

actor MyResources: MCPResourceProvider {
    func listResources() async -> [Resource] { [] }

    func readResource(uri: String) async throws -> ReadResource.Result {
        ReadResource.Result(contents: [])
    }
}

actor MyPrompts: MCPPromptProvider {
    func listPrompts() async -> [Prompt] { [] }

    func getPrompt(name: String, arguments: [String: String]?) async -> GetPrompt.Result {
        GetPrompt.Result(messages: [])
    }
}

func startServerWithProviders() async throws {
    try await MCPServer.builder()
        .serverName("My MCP Server")
        .resourceProvider(MyResources())
        .promptProvider(MyPrompts())
        .run()
}
```

### Manage API Keys

Over HTTP, requests are authenticated by default. The same binary manages the
persistent key store:

```
$ my-server --generate-key --name "laptop"
$ my-server --list-keys
$ my-server --revoke-key <prefix>
```

A generated key is printed once; `--list-keys` afterwards reports only names,
prefixes, and last-use timestamps, so record the value when it is printed.
Programmatic access to the same store is available through ``APIKeyStore`` and
``APIKeyAuthenticator``.

### Configure Behavior with Environment Variables

| Variable | Effect |
| --- | --- |
| `LOG_LEVEL` | Log level: `trace`, `debug`, `info`, `notice`, `warning`, `error`, `critical`. |
| `MCP_AUTH_REQUIRED` | Set to `false` to disable authentication. |
| `MCP_API_KEYS` | Comma-separated keys accepted in addition to the store. |
| `MCP_OAUTH_ENABLED` | Set to `true` to enable OAuth 2.0. |
| `MCP_OAUTH_ISSUER` | OAuth issuer URL. Defaults to `http://localhost:<port>`. |

Pass `--verbose` (or `-v`) to raise log verbosity for a single run. See
``LoggingConfiguration`` for the log-level resolution rules.
