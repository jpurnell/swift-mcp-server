# SwiftMCPServer

A Swift implementation of the Model Context Protocol server, serving revision **`2026-07-28`**
alongside the revisions before it — from one implementation, so a server can adopt the current
revision without stranding the clients it already has. A request that declares no protocol
version is answered by the rules of the revision it is actually on.

## Conformance

Measured against the official [MCP conformance suite][conformance] at `0.2.0-alpha.11`:

| Run | Result |
| :--- | :--- |
| `--requirements 2026-07-28` (50 scenarios) | **195 / 195** |
| `--suite all` | **227 / 227** |

One scenario, `tasks-status-notifications`, is skipped by the harness itself, which reports that
it needs a rewrite against the `subscriptions/listen` channel.

**Reproduce it** — the target the suite drives is in this package, so the numbers above are
checkable rather than asserted:

```bash
swift build --product conformance-server
"$(swift build --show-bin-path)/conformance-server" &     # listens on :3002

npx @modelcontextprotocol/conformance@0.2.0-alpha.11 \
  server --url http://localhost:3002/mcp --requirements 2026-07-28
```

Two things that will otherwise waste your afternoon: the version matters — `@latest` resolves to
a build that predates `2026-07-28` and tests mechanisms it removed — and the harness needs Node
22 or later for `fs.globSync`, failing on Node 20 with a module error that looks unrelated.

Those figures describe that harness build. A later one tests different things; quote the version
alongside the number or the claim cannot be checked.

## Features

- **Streamable HTTP transport**, serving `2026-07-28` and earlier revisions together
- **Stateless operation** (SEP-2575) — `server/discover`, per-request protocol carriage,
  `subscriptions/listen`
- **Multi Round-Trip Requests** (SEP-2322) — a server asks for what it needs and the client
  retries, with no callback channel required
- **Tasks extension** (SEP-2663) — work that outlives the request that asked for it
- **Routing headers** (SEP-2243), including `x-mcp-header` parameter mirroring
- **`Host`/`Origin` validation** against DNS rebinding ([GHSA-w48q-cv73-mx4w][ghsa])
- OAuth 2.0 with PKCE, API key authentication, TLS
- Cross-platform (macOS, Linux) via SwiftNIO

## Requirements

- Swift 6.2+
- macOS 14+ or Linux

## Dependencies

This package depends on two first-party artefacts: [swift-mcp-sdk][sdk] — a **fork** of the
official MCP Swift SDK, carrying `2026-07-28` support upstream does not have — and
[swift-oauth][oauth]. Both are published; neither is the official SDK.

## Usage

A tool is any `Sendable` type conforming to `MCPToolHandler`:

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

Assemble the server with the builder and run it:

```swift
func startServer() async throws {
    try await MCPServer.builder()
        .serverName("My Server")
        .serverVersion("1.0.0")
        .tool(GreetTool())
        .run()
}
```

The transport is chosen by command-line flags, not by the builder. With no flags
the server speaks stdio; `--http 8080` starts the SwiftNIO HTTP transport on that
port, and `--tls-cert`/`--tls-key` add HTTPS:

```
$ my-server
$ my-server --http 8080
$ my-server --http 8443 --tls-cert /path/cert.pem --tls-key /path/key.pem
```

See the `GettingStarted` article in the DocC catalogue for the full walkthrough.

## Publication

This repository is a published export. The development repository keeps the full record —
planning documents, decision logs, session summaries — and this carries what is needed to build
the package, read what changed, and check its claims. `CHANGELOG.md` is that history.

## License

MIT. See LICENSE.

[conformance]: https://github.com/modelcontextprotocol/conformance
[sdk]: https://github.com/jpurnell/swift-mcp-sdk
[oauth]: https://github.com/jpurnell/swift-oauth
[ghsa]: https://github.com/modelcontextprotocol/typescript-sdk/security/advisories/GHSA-w48q-cv73-mx4w
