import Foundation
import MCP

// MARK: - Resource Provider Protocol

/// Protocol for providing MCP resources.
///
/// Consumers implement this to serve resources through the MCP server.
/// The framework handles registration with the MCP SDK.
///
/// ```swift
/// import MCP
///
/// actor MyResourceProvider: MCPResourceProvider {
///     func listResources() async -> [Resource] { [] }
///     func readResource(uri: String) async throws -> ReadResource.Result {
///         fatalError("return the contents for \(uri)")
///     }
/// }
/// ```
public protocol MCPResourceProvider: Sendable {
    /// List all available resources.
    func listResources() async -> [Resource]

    /// Read a resource by URI.
    func readResource(uri: String) async throws -> ReadResource.Result
}

// MARK: - Prompt Provider Protocol

/// Protocol for providing MCP prompts.
///
/// Consumers implement this to serve prompt templates through the MCP server.
/// The framework handles registration with the MCP SDK.
///
/// ```swift
/// import MCP
///
/// actor MyPromptProvider: MCPPromptProvider {
///     func listPrompts() async -> [Prompt] { [] }
///     func getPrompt(name: String, arguments: [String: String]?) async -> GetPrompt.Result {
///         fatalError("return the prompt named \(name)")
///     }
/// }
/// ```
public protocol MCPPromptProvider: Sendable {
    /// List all available prompts.
    func listPrompts() async -> [Prompt]

    /// Get a specific prompt by name with optional arguments.
    func getPrompt(name: String, arguments: [String: String]?) async -> GetPrompt.Result
}
