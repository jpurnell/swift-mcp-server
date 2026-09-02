# ``SwiftMCPServer``

A Swift implementation of the Model Context Protocol (MCP) server with HTTP transport.

## Overview

SwiftMCPServer hosts MCP tools, resources, and prompts over either stdio or a
SwiftNIO-backed HTTP transport. It provides:

- **Streamable HTTP transport** implementing MCP spec 2025-03-26, including
  Server-Sent Events for server-initiated messages.
- **Authentication** via persistent API keys, environment-supplied keys, or
  OAuth 2.0 with PKCE (supplied by the `SwiftOAuth` package).
- **TLS/HTTPS** termination from PEM certificate and key files.
- **Cross-platform** operation on macOS and Linux.

Servers are assembled with a fluent builder. Register tool handlers, optionally
attach resource and prompt providers, then run:

```swift
import SwiftMCPServer

func startServer() async throws {
    try await MCPServer.builder()
        .serverName("My MCP Server")
        .serverVersion("1.0.0")
        .run()
}
```

Tools are registered with `tool(_:)` or `tools(_:)`, each conforming to
``MCPToolHandler``.

``MCPServerBuilder/run()`` parses the process's command-line arguments, so the
same binary handles server startup, transport selection, and API key management:
it serves stdio by default and switches to HTTP when launched with `--http
<port>`. See <doc:GettingStarted> for a complete walkthrough.

## Topics

### Essentials

- <doc:GettingStarted>
- ``MCPServer``
- ``MCPServerBuilder``
- ``MCPServerConfiguration``

### Command-Line Interface

- ``ParsedArguments``
- ``ServerCommand``
- ``TransportModeOption``

### Defining Tools

- ``MCPToolHandler``
- ``MCPTool``
- ``MCPToolInputSchema``
- ``MCPSchemaProperty``
- ``MCPSchemaItems``
- ``MCPToolCallResult``
- ``AnyCodable``
- ``ToolError``

### Tool Registration

- ``ToolDefinition``
- ``ToolDefinitionRegistry``

### Resources and Prompts

- ``MCPResourceProvider``
- ``MCPPromptProvider``

### Authentication

- ``APIKeyAuthenticator``
- ``APIKeyStore``
- ``APIKey``
- ``APIKeySummary``
- ``APIKeyStoreError``

### HTTP Transport

- ``HTTPServerTransport``
- ``HTTPConnection``
- ``NIOHTTPConnection``
- ``HTTPConnectionError``
- ``HTTPResponseManager``

### HTTP Model Types

- ``HTTPRequest``
- ``HTTPResponse``
- ``HTTPMethod``
- ``HTTPStatus``

### Sessions and Streaming

- ``SSESession``
- ``SSESessionManager``
- ``StreamableSessionManager``

### Logging

- ``LoggingConfiguration``

### Utilities

- ``ExpressionEvaluator``
- ``ValueExtractionError``
