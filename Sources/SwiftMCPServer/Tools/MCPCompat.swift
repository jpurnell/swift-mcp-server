import Foundation
import MCP

// MARK: - Compatibility Layer for Migration from Custom MCPSwift to Official SDK

/// Compatibility protocol matching our old MCPToolHandler
public protocol MCPToolHandler: Sendable {
    /// The tool's advertised definition: its name, description and input schema.
    ///
    /// This is what a client sees when it lists tools, so the schema here is the contract
    /// — an argument `execute` reads but this does not declare is one no caller can know
    /// to send.
    var tool: MCPTool { get }

    /// Runs the tool against decoded arguments and returns its result.
    ///
    /// - Parameter arguments: The caller's arguments, keyed by the property names declared
    ///   in ``tool``'s input schema. `nil` when the caller sent none.
    /// - Returns: The tool's output, as content blocks the client will render.
    /// - Throws: Whatever the tool needs to report as a failed call — a missing required
    ///   argument, or a domain error from the computation itself.
    func execute(arguments: [String: AnyCodable]?) async throws -> MCPToolCallResult
}

/// Compatibility type matching our old MCPTool
public struct MCPTool: Sendable {
    /// The tool name
    public let name: String
    /// A human-readable description of the tool
    public let description: String
    /// The JSON Schema describing the tool's input parameters
    public let inputSchema: MCPToolInputSchema

    /// Creates a new tool definition
    public init(name: String, description: String, inputSchema: MCPToolInputSchema) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    /// Convert to official SDK Tool
    func toSDKTool() throws -> Tool {
        return Tool(
            name: name,
            description: description,
            inputSchema: try inputSchema.toValue()
        )
    }
}

/// Compatibility type for tool input schema
public struct MCPToolInputSchema: Sendable {
    /// The JSON Schema type (typically "object")
    public let type: String
    /// Property definitions for this schema
    public let properties: [String: MCPSchemaProperty]?
    /// List of required property names
    public let required: [String]?

    /// Creates a new input schema
    public init(type: String = "object", properties: [String: MCPSchemaProperty]? = nil, required: [String]? = nil) {
        self.type = type
        self.properties = properties
        self.required = required
    }

    /// Convert to MCP.Value
    func toValue() throws -> MCP.Value {
        var dict: [String: MCP.Value] = [
            "type": .string(type)
        ]

        if let properties = properties {
            var propsDict: [String: MCP.Value] = [:]
            for (key, prop) in properties {
                propsDict[key] = try prop.toValue()
            }
            dict["properties"] = .object(propsDict)
        }

        if let required = required {
            dict["required"] = .array(required.map { .string($0) })
        }

        return .object(dict)
    }
}

/// Compatibility type for schema property
public struct MCPSchemaProperty: Sendable {
    /// The JSON Schema type of this property
    public let type: String
    /// A human-readable description of this property
    public let description: String?
    /// Allowed values for this property
    public let `enum`: [String]?
    /// Schema for array items
    public let items: MCPSchemaItems?

    /// Creates a new schema property
    public init(type: String, description: String? = nil, `enum`: [String]? = nil, items: MCPSchemaItems? = nil) {
        self.type = type
        self.description = description
        self.`enum` = `enum`
        self.items = items
    }

    /// Convert to MCP.Value
    func toValue() throws -> MCP.Value {
        var dict: [String: MCP.Value] = [
            "type": .string(type)
        ]

        if let description = description {
            dict["description"] = .string(description)
        }

        if let enumValues = `enum` {
            dict["enum"] = .array(enumValues.map { .string($0) })
        }

        if let items = items {
            dict["items"] = try items.toValue()
        }

        return .object(dict)
    }
}

/// Compatibility type for schema items
public struct MCPSchemaItems: Sendable {
    /// The JSON Schema type of the array items
    public let type: String

    /// Creates a new schema items definition
    public init(type: String) {
        self.type = type
    }

    /// Convert to MCP.Value
    func toValue() throws -> MCP.Value {
        return .object(["type": .string(type)])
    }
}

/// Compatibility type-erased wrapper
// Justification: wraps an immutable Any value set once at init and never mutated
public struct AnyCodable: @unchecked Sendable {
    /// The wrapped value
    public let value: Any

    /// Creates a new type-erased codable value
    public init<T: Codable & Sendable>(_ value: T) {
        self.value = value
    }

    /// Convert from MCP.Value
    init(_ mcpValue: MCP.Value) {
        switch mcpValue {
        case .null:
            self.value = Optional<Int>.none as Any
        case .bool(let v):
            self.value = v
        case .int(let v):
            self.value = v
        case .double(let v):
            self.value = v
        case .string(let v):
            self.value = v
        case .data(_, let v):
            self.value = v
        case .array(let v):
            self.value = v.map { AnyCodable($0) }
        case .object(let v):
            self.value = v.mapValues { AnyCodable($0) }
        }
    }

    /// Recursively unwrap to JSON-compatible native types.
    /// Converts [AnyCodable] → [Any] and [String: AnyCodable] → [String: Any]
    /// so the result can be passed to JSONSerialization.
    public var jsonValue: Any {
        if let arr = value as? [AnyCodable] {
            return arr.map { $0.jsonValue }
        } else if let dict = value as? [String: AnyCodable] {
            return dict.mapValues { $0.jsonValue }
        } else {
            return value
        }
    }
}

/// Compatibility result type
public struct MCPToolCallResult: Sendable {
    /// The underlying SDK call tool result
    public let result: CallTool.Result

    /// Creates a new result wrapping an SDK result
    public init(_ result: CallTool.Result) {
        self.result = result
    }

    /// Creates a successful result with the given text
    public static func success(text: String) -> MCPToolCallResult {
        return MCPToolCallResult(CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false))
    }

    /// Creates an error result with the given message
    public static func error(message: String) -> MCPToolCallResult {
        return MCPToolCallResult(CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true))
    }
}

/// Compatibility error type
public enum ToolError: Error, LocalizedError {
    case toolNotFound(String)
    case invalidArguments(String)
    case executionFailed(String, String)
    case missingRequiredArgument(String)

    /// A localized description of the error
    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let name):
            return "Tool not found: \(name)"
        case .invalidArguments(let message):
            return "Invalid arguments: \(message)"
        case .executionFailed(let tool, let message):
            return "Execution failed for \(tool): \(message)"
        case .missingRequiredArgument(let key):
            return "Missing required argument: \(key)"
        }
    }
}

// MARK: - Conversion Helpers

extension Dictionary where Key == String, Value == AnyCodable {
    /// Get required string
    public func getString(_ key: String) throws -> String {
        guard let value = self[key] else {
            throw ToolError.missingRequiredArgument(key)
        }
        guard let stringValue = value.value as? String else {
            throw ToolError.invalidArguments("\(key) must be a string")
        }
        return stringValue
    }

    /// Get optional string
    public func getStringOptional(_ key: String) -> String? {
        return self[key]?.value as? String
    }

    /// Get required int
    public func getInt(_ key: String) throws -> Int {
        guard let value = self[key] else {
            throw ToolError.missingRequiredArgument(key)
        }
        guard let intValue = value.value as? Int else {
            throw ToolError.invalidArguments("\(key) must be an integer")
        }
        return intValue
    }

    /// Get optional int
    public func getIntOptional(_ key: String) -> Int? {
        return self[key]?.value as? Int
    }

    /// Get required double
    public func getDouble(_ key: String) throws -> Double {
        guard let value = self[key] else {
            throw ToolError.missingRequiredArgument(key)
        }
        if let doubleValue = value.value as? Double {
            return doubleValue
        } else if let intValue = value.value as? Int {
            return Double(intValue)
        } else {
            throw ToolError.invalidArguments("\(key) must be a number")
        }
    }

    /// Get optional double
    public func getDoubleOptional(_ key: String) -> Double? {
        if let doubleValue = self[key]?.value as? Double {
            return doubleValue
        } else if let intValue = self[key]?.value as? Int {
            return Double(intValue)
        }
        return nil
    }

    /// Get required bool
    public func getBool(_ key: String) throws -> Bool {
        guard let value = self[key] else {
            throw ToolError.missingRequiredArgument(key)
        }
        guard let boolValue = value.value as? Bool else {
            throw ToolError.invalidArguments("\(key) must be a boolean")
        }
        return boolValue
    }

    /// Get optional bool
    public func getBoolOptional(_ key: String) -> Bool? {
        return self[key]?.value as? Bool
    }

    /// Get double array
    public func getDoubleArray(_ key: String) throws -> [Double] {
        guard let value = self[key] else {
            throw ToolError.missingRequiredArgument(key)
        }
        guard let arrayValue = value.value as? [AnyCodable] else {
            throw ToolError.invalidArguments("\(key) must be an array")
        }

        var result: [Double] = []
        for (index, item) in arrayValue.enumerated() {
            if let doubleValue = item.value as? Double {
                result.append(doubleValue)
            } else if let intValue = item.value as? Int {
                result.append(Double(intValue))
            } else {
                throw ToolError.invalidArguments("\(key)[\(index)] must be a number")
            }
        }
        return result
    }

    /// Get string array
    public func getStringArray(_ key: String) throws -> [String] {
        guard let value = self[key] else {
            throw ToolError.missingRequiredArgument(key)
        }
        guard let arrayValue = value.value as? [AnyCodable] else {
            throw ToolError.invalidArguments("\(key) must be an array")
        }

        var result: [String] = []
        for (index, item) in arrayValue.enumerated() {
            guard let stringValue = item.value as? String else {
                throw ToolError.invalidArguments("\(key)[\(index)] must be a string")
            }
            result.append(stringValue)
        }
        return result
    }

    /// Get 2D double array (matrix)
    public func getDoubleMatrix(_ key: String) throws -> [[Double]] {
        guard let value = self[key] else {
            throw ToolError.missingRequiredArgument(key)
        }
        guard let outerArray = value.value as? [AnyCodable] else {
            throw ToolError.invalidArguments("\(key) must be an array of arrays")
        }

        return try outerArray.enumerated().map { rowIndex, row in
            guard let innerArray = row.value as? [AnyCodable] else {
                throw ToolError.invalidArguments("\(key)[\(rowIndex)] must be an array of numbers")
            }
            return try innerArray.enumerated().map { colIndex, item in
                try convertToDouble(item, context: "\(key)[\(rowIndex)][\(colIndex)]")
            }
        }
    }

    private func convertToDouble(_ item: AnyCodable, context: String) throws -> Double {
        if let doubleValue = item.value as? Double {
            return doubleValue
        }
        if let intValue = item.value as? Int {
            return Double(intValue)
        }
        throw ToolError.invalidArguments("\(context) must be a number")
    }

    /// Check if a key exists
    public func hasKey(_ key: String) -> Bool {
        return self[key] != nil
    }

    /// Get a double from a nested object
    public func getDoubleFromObject(_ objectKey: String, key: String) throws -> Double {
        guard let objectValue = self[objectKey] else {
            throw ToolError.missingRequiredArgument(objectKey)
        }

        guard let dict = objectValue.value as? [String: AnyCodable] else {
            throw ToolError.invalidArguments("\(objectKey) must be an object")
        }

        guard let value = dict[key] else {
            throw ToolError.missingRequiredArgument("\(objectKey).\(key)")
        }

        if let doubleVal = value.value as? Double {
            return doubleVal
        } else if let intVal = value.value as? Int {
            return Double(intVal)
        } else {
            throw ToolError.invalidArguments("\(objectKey).\(key) must be a number")
        }
    }
}

// MARK: - Tool Handler Conversion

extension MCPToolHandler {
    /// Convert to ToolDefinition for use with official SDK
    public func toToolDefinition() throws -> ToolDefinition {
        let sdkTool = try tool.toSDKTool()
        let handler = self

        // Create a properly structured ToolDefinition manually
        return ToolDefinition(
            tool: sdkTool,
            execute: { arguments in
                // Convert MCP.Value arguments to AnyCodable
                let compatArgs: [String: AnyCodable]? = arguments.map { dict in
                    dict.mapValues { AnyCodable($0) }
                }

                // Execute with compatibility layer
                let result = try await handler.execute(arguments: compatArgs)
                return result.result
            }
        )
    }
}
