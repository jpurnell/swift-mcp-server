import Foundation
#if canImport(os)
import os
#endif

/// Cross-platform expression evaluation
///
/// On macOS: Uses NSExpression for full formula evaluation
/// On Linux: Provides basic arithmetic operations
public enum ExpressionEvaluator {

    /// Evaluate a mathematical expression string
    /// - Parameter formula: Mathematical formula as a string (e.g., "2 + 3 * 4")
    /// - Returns: Result of the evaluation, or 0.0 if evaluation fails
    public static func evaluate(_ formula: String) -> Double {
        #if os(macOS)
        // Use NSExpression on macOS
        let expression = NSExpression(format: formula)
        if let result = expression.expressionValue(with: nil, context: nil) as? Double {
            return result
        } else if let result = expression.expressionValue(with: nil, context: nil) as? NSNumber {
            return result.doubleValue
        }
        return 0.0
        #else
        // On Linux, use basic evaluation
        return evaluateBasicExpression(formula)
        #endif
    }

    #if !os(macOS)
    /// Basic expression evaluator for Linux
    /// Handles simple arithmetic: +, -, *, /, ^
    private static func evaluateBasicExpression(_ formula: String) -> Double {
        // Remove whitespace
        let cleaned = formula.replacingOccurrences(of: " ", with: "")

        // Try to parse as a simple number first
        if let value = Double(cleaned) {
            return value
        }

        // Basic recursive descent parser for simple arithmetic
        // This is a simplified version - for production use a proper expression parser library
        do {
            let parser = SimpleExpressionParser(cleaned)
            return try parser.parse()
        } catch {
            Logger(subsystem: "com.swiftmcp", category: "ExpressionParser").debug("Parse error: \(error.localizedDescription, privacy: .public)")
            return 0.0
        }
    }

    /// Simple recursive descent parser for basic arithmetic
    private class SimpleExpressionParser {
        private let input: String
        private var position: String.Index

        init(_ input: String) {
            self.input = input
            self.position = input.startIndex
        }

        func parse() throws -> Double {
            return try parseExpression()
        }

        private func parseExpression() throws -> Double {
            var result = try parseTerm()

            while position < input.endIndex {
                let char = input[position]
                if char == "+" {
                    position = input.index(after: position)
                    result += try parseTerm()
                } else if char == "-" {
                    position = input.index(after: position)
                    result -= try parseTerm()
                } else {
                    break
                }
            }

            return result
        }

        private func parseTerm() throws -> Double {
            var result = try parseFactor()

            while position < input.endIndex {
                let char = input[position]
                if char == "*" {
                    position = input.index(after: position)
                    result *= try parseFactor()
                } else if char == "/" {
                    position = input.index(after: position)
                    let divisor = try parseFactor()
                    if divisor != 0 {
                        result /= divisor
                    }
                } else {
                    break
                }
            }

            return result
        }

        private func parseFactor() throws -> Double {
            if position >= input.endIndex {
                throw EvaluationError.unexpectedEnd
            }

            let char = input[position]

            // Handle parentheses
            if char == "(" {
                position = input.index(after: position)
                let result = try parseExpression()
                if position < input.endIndex && input[position] == ")" {
                    position = input.index(after: position)
                }
                return result
            }

            // Handle negative numbers
            if char == "-" {
                position = input.index(after: position)
                let factor = try parseFactor()
                return -factor
            }

            // Parse number
            return try parseNumber()
        }

        private func parseNumber() throws -> Double {
            let start = position

            while position < input.endIndex {
                let char = input[position]
                if char.isNumber || char == "." {
                    position = input.index(after: position)
                } else {
                    break
                }
            }

            let numberString = String(input[start..<position])
            if let value = Double(numberString) {
                return value
            }

            throw EvaluationError.invalidNumber
        }
    }

    enum EvaluationError: Error {
        case unexpectedEnd
        case invalidNumber
    }
    #endif
}
