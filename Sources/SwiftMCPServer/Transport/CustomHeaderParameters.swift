import Foundation
import MCP
#if canImport(os)
import os
#endif
@preconcurrency import NIOHTTP1

/// The arguments a tool mirrors into named HTTP headers (SEP-2243).
///
/// A tool may annotate an input-schema property with `x-mcp-header`, declaring that the same
/// value also travels in an `Mcp-Param-{Name}` header, where `{Name}` is the annotation's value.
/// The annotation names the *parameter*, not the whole field — a distinction worth stating,
/// because treating it as the field name produces a server that looks like it validates and
/// never finds the header, so every check that expects a rejection passes for the wrong reason.
///
/// An intermediary can then route or authorise on it without parsing the body — which only
/// works if the two always say the same thing. When
/// they disagree, the router and the executor are acting on different values, and that gap is
/// the vulnerability the rule closes. It is `Mcp-Name`'s rule, generalised to arguments a tool
/// nominates for itself.
///
/// Built from the tools a server serves, because the annotation lives in their schemas and the
/// transport has no other way to learn it.
public struct CustomHeaderParameters: Sendable {
    /// Tool name → (argument name → the `{Name}` its header is spelled with).
    private let byTool: [String: [String: String]]

    /// Reads the `x-mcp-header` annotations out of a set of tools.
    ///
    /// A tool whose annotations are invalid — a header name that is not a legal field name, two
    /// properties claiming one header — contributes nothing rather than contributing something
    /// half-checked. `XMCPHeaderPolicy` is the authority on what makes them valid; this only
    /// asks.
    ///
    /// - Parameter tools: The tools this server serves.
    public init(tools: [Tool]) {
        let logger = os.Logger(subsystem: "com.swiftmcp", category: "CustomHeaderParameters")
        var byTool: [String: [String: String]] = [:]
        for tool in tools {
            do {
                let names = try XMCPHeaderPolicy.headerNames(in: tool.inputSchema)
                guard !names.isEmpty else { continue }
                byTool[tool.name] = names
            } catch {
                // Loud, because the consequence is silent: a tool whose annotations do not
                // validate keeps working and simply stops having its headers checked, which
                // looks identical to a tool that never declared any.
                logger.error(
                    "Ignoring x-mcp-header annotations on '\(tool.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            }
        }
        self.byTool = byTool
    }

    /// The prefix every custom parameter header carries, per MCP `2026-07-28`.
    private static let headerPrefix = "Mcp-Param-"

    /// Whether any tool declares custom headers.
    public var isEmpty: Bool { byTool.isEmpty }

    /// Checks a request's custom headers against the arguments they mirror.
    ///
    /// - Parameters:
    ///   - headers: The request's HTTP headers.
    ///   - body: The decoded JSON-RPC request.
    /// - Returns: A message describing the disagreement, or `nil` when they agree.
    public func mismatch(headers: HTTPHeaders, body: [String: Any]) -> String? {
        guard body["method"] as? String == "tools/call",
            let params = body["params"] as? [String: Any],
            let tool = params["name"] as? String,
            let declared = byTool[tool]
        else { return nil }

        let arguments = params["arguments"] as? [String: Any] ?? [:]
        // Sorted so the message a client gets is the same one every time, rather than whichever
        // key the dictionary happened to yield first.
        for (argument, headerName) in declared.sorted(by: { $0.key < $1.key }) {
            guard let bodyValue = Self.string(arguments[argument]) else { continue }

            let field = Self.headerPrefix + headerName
            guard let raw = headers.first(name: field) else {
                // Omitting the header while the body carries the value is the same fault as
                // sending the wrong one: an intermediary routing on the header cannot see what
                // the executor is about to act on.
                return "\(field) is required when '\(argument)' is present in the body"
            }

            switch Self.decoded(raw.trimmingCharacters(in: .whitespaces)) {
            case .undecodable:
                return "\(field) claims Base64 encoding but does not decode"
            case .value(let headerValue):
                if headerValue != bodyValue {
                    return "\(field) '\(headerValue)' does not match the body's '\(bodyValue)'"
                }
            }
        }
        return nil
    }

    /// The scalar spelling of an argument, or `nil` when it has none.
    ///
    /// A header carries text, so only the types that have one canonical spelling can be mirrored
    /// into one. `XMCPHeaderPolicy` refuses an annotation on anything else at registration time;
    /// this is the matching read.
    private static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String: return text
        case let number as Int: return String(number)
        case let flag as Bool: return flag ? "true" : "false"
        default: return nil
        }
    }

    /// What a header value turned out to be.
    private enum Decoded {
        case value(String)
        case undecodable
    }

    /// Decodes a header value, if it is wrapped in the Base64 sentinel.
    ///
    /// **Only the complete sentinel means "decode this."** A value carrying half of it is a
    /// literal: guessing would mangle any argument that merely happened to look encoded, and the
    /// specification's own test table has cases for exactly that.
    private static func decoded(_ value: String) -> Decoded {
        let prefix = "=?base64?"
        let suffix = "?="
        guard value.hasPrefix(prefix), value.hasSuffix(suffix),
            value.count >= prefix.count + suffix.count
        else { return .value(value) }

        let start = value.index(value.startIndex, offsetBy: prefix.count)
        let end = value.index(value.endIndex, offsetBy: -suffix.count)
        let encoded = String(value[start..<end])

        // Well-formedness is checked here rather than left to Foundation, which is more
        // forgiving than the specification: it decodes `ZXUtd2VzdC0x=` — a length that is not a
        // multiple of four — as though the padding were right. The specification's test table
        // requires that to be refused, so accepting it would mean silently acting on a value
        // the sender did not send.
        guard isWellFormedBase64(encoded),
            let data = Data(base64Encoded: encoded),
            let text = String(data: data, encoding: .utf8)
        else { return .undecodable }
        return .value(text)
    }

    /// Whether `encoded` is canonical Base64: the standard alphabet, a length that is a multiple
    /// of four, and padding only at the end.
    private static func isWellFormedBase64(_ encoded: String) -> Bool {
        guard !encoded.isEmpty, encoded.count % 4 == 0 else { return false }

        let alphabet = Set(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        var padding = 0
        for character in encoded {
            if character == "=" {
                padding += 1
                continue
            }
            // A non-padding character after padding has begun means the `=` was data, not
            // padding — which canonical Base64 never produces.
            guard padding == 0, alphabet.contains(character) else { return false }
        }
        return padding <= 2
    }
}
