import Foundation
import Testing

@testable import SwiftMCPServer
import MCP

/// Deterministic `tools/list` ordering, a `SHOULD` of MCP `2026-07-28`.
///
/// The specification asks servers to return tools in a deterministic order so clients can cache
/// the response and so an LLM's prompt cache hits. Swift randomises `Dictionary` iteration per
/// process, so returning `tools.values` directly gives a different order on every run — which
/// defeats both caches silently, without ever failing a request.
@Suite("Tool Ordering")
struct ToolOrderingTests {

    private struct StubTool: MCPToolHandler {
        let toolName: String
        var tool: MCPTool {
            MCPTool(
                name: toolName,
                description: "stub",
                inputSchema: MCPToolInputSchema(properties: [:], required: [])
            )
        }
        func execute(arguments: [String: AnyCodable]?) async throws -> MCPToolCallResult {
            .success(text: "ok")
        }
    }

    @Test("Tools are listed in a deterministic order regardless of registration order")
    func testDeterministicOrder() async throws {
        let registry = ToolDefinitionRegistry()
        // Registered deliberately out of alphabetical order.
        for name in ["zebra", "alpha", "mike", "bravo"] {
            try await registry.register(StubTool(toolName: name).toToolDefinition())
        }

        let names = await registry.listTools().map(\.name)
        #expect(names == ["alpha", "bravo", "mike", "zebra"], "listing must be sorted by name")
    }

    /// Determinism means the same answer every time, not merely a sorted one — repeated calls
    /// must agree, which is what makes a cached response safe to reuse.
    @Test("Repeated listings agree")
    func testRepeatedListingsAgree() async throws {
        let registry = ToolDefinitionRegistry()
        for name in ["delta", "charlie", "echo"] {
            try await registry.register(StubTool(toolName: name).toToolDefinition())
        }

        let first = await registry.listTools().map(\.name)
        let second = await registry.listTools().map(\.name)
        #expect(first == second)
        #expect(first == ["charlie", "delta", "echo"])
    }
}
