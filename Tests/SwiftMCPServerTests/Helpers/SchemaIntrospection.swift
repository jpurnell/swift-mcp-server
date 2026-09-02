import Foundation
import MCP
@testable import SwiftMCPServer

/// Extracted schema metadata for a single tool, suitable for test assertions.
struct ToolSchemaInfo: Sendable {
    let name: String
    let description: String
    let requiredParams: [String]
    let allParams: [String]
    let paramTypes: [String: String]
    let paramEnums: [String: [String]]
    let paramDescriptions: [String: String]
    let hasItems: [String: String]
}

/// Extract testable schema info from any MCPToolHandler.
func extractSchema(_ handler: any MCPToolHandler) -> ToolSchemaInfo {
    let schema = handler.tool.inputSchema

    var allParams: [String] = []
    var paramTypes: [String: String] = [:]
    var paramEnums: [String: [String]] = [:]
    var paramDescriptions: [String: String] = [:]
    var hasItems: [String: String] = [:]

    if let props = schema.properties {
        for (key, prop) in props {
            allParams.append(key)
            paramTypes[key] = prop.type
            if let desc = prop.description {
                paramDescriptions[key] = desc
            }
            if let enumVals = prop.`enum` {
                paramEnums[key] = enumVals
            }
            if let items = prop.items {
                hasItems[key] = items.type
            }
        }
    }

    return ToolSchemaInfo(
        name: handler.tool.name,
        description: handler.tool.description,
        requiredParams: schema.required ?? [],
        allParams: allParams.sorted(),
        paramTypes: paramTypes,
        paramEnums: paramEnums,
        paramDescriptions: paramDescriptions,
        hasItems: hasItems
    )
}

/// Extract schemas for a list of tool handlers.
func toolSchemas(_ handlers: [any MCPToolHandler]) -> [ToolSchemaInfo] {
    return handlers.map { extractSchema($0) }
}

/// Generate minimal valid arguments for a tool based on its schema metadata.
/// Only populates required params with type-appropriate defaults.
/// The goal is "no crash" — the tool may still return an error for domain-specific reasons.
func generateMinimalValidArgs(_ schema: ToolSchemaInfo) -> [String: AnyCodable] {
    var args: [String: AnyCodable] = [:]

    for param in schema.requiredParams {
        let type = schema.paramTypes[param] ?? "string"

        switch type {
        case "number":
            args[param] = AnyCodable(100000.0)

        case "integer":
            args[param] = AnyCodable(5)

        case "boolean":
            args[param] = AnyCodable(false)

        case "string":
            if let enumValues = schema.paramEnums[param], let first = enumValues.first {
                args[param] = AnyCodable(first)
            } else {
                args[param] = AnyCodable("TestValue")
            }

        case "array":
            let itemType = schema.hasItems[param] ?? "number"
            switch itemType {
            case "number":
                args[param] = AnyCodable([1.0, 2.0, 3.0])
            case "string":
                args[param] = AnyCodable(["A", "B", "C"])
            case "object":
                args[param] = AnyCodable([["key": "value"]])
            default:
                args[param] = AnyCodable([[1.0, 2.0], [3.0, 4.0]])
            }

        case "object":
            args[param] = AnyCodable(MCP.Value.object([:]))

        default:
            args[param] = AnyCodable("TestValue")
        }
    }

    return args
}
