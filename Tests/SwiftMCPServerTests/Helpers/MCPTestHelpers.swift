import Testing
import Foundation
import MCP
@testable import SwiftMCPServer

// MARK: - MCPToolCallResult Convenience

extension MCPToolCallResult {
    /// Whether this result represents an error
    var isError: Bool {
        return result.isError ?? false
    }

    /// Extract the text content from the first content block
    var text: String {
        guard let firstContent = result.content.first else {
            return ""
        }
        switch firstContent {
        case .text(let text, _, _):
            return text
        default:
            return ""
        }
    }
}

// MARK: - Argument Construction Helpers

/// Build AnyCodable arguments from a JSON string, matching the MCP wire format path:
/// JSON -> MCP.Value -> AnyCodable (same conversion the real server performs)
func decodeArguments(_ json: String) throws -> [String: AnyCodable] {
    guard let data = json.data(using: .utf8) else {
        throw MCPTestError.invalidJson
    }
    let mcpValue = try JSONDecoder().decode(MCP.Value.self, from: data)
    guard case .object(let dict) = mcpValue else {
        throw MCPTestError.decodingFailed("JSON must be an object")
    }
    return dict.mapValues { AnyCodable($0) }
}

/// Build AnyCodable arguments from a JSON string literal.
/// Shorthand for decodeArguments that returns an empty dict on failure.
func argsFromJSON(_ json: String) -> [String: AnyCodable] {
    return (try? decodeArguments(json)) ?? [:]
}

// MARK: - Test Error Type

enum MCPTestError: Error, LocalizedError {
    case invalidJson
    case decodingFailed(String)
    case unexpectedResult(String)

    var errorDescription: String? {
        switch self {
        case .invalidJson:
            return "Invalid JSON in test"
        case .decodingFailed(let msg):
            return "Decoding failed: \(msg)"
        case .unexpectedResult(let msg):
            return "Unexpected result: \(msg)"
        }
    }
}

// MARK: - Tool Lookup Helper

/// Map of tool name -> tool handler for direct lookup
func toolHandlersByName(_ handlers: [any MCPToolHandler]) -> [String: any MCPToolHandler] {
    var map: [String: any MCPToolHandler] = [:]
    for handler in handlers {
        map[handler.tool.name] = handler
    }
    return map
}
