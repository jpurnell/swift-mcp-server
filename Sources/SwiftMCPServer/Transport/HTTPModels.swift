import Foundation

/// Platform-agnostic HTTP request representation
///
/// This value type provides a clean, testable representation of an HTTP request
/// that works across both Network framework and SwiftNIO implementations.
///
/// ## Usage Example
///
/// ```swift
/// let jsonData = Data(#"{"jsonrpc":"2.0","method":"tools/list","id":1}"#.utf8)
/// let request = HTTPRequest(
///     method: .post,
///     path: "/mcp",
///     headers: ["Content-Type": "application/json"],
///     body: jsonData
/// )
/// ```
///
/// ## Topics
///
/// ### Creating Requests
/// - ``init(method:path:headers:body:)``
///
/// ### Request Properties
/// - ``method``
/// - ``path``
/// - ``headers``
/// - ``body``
///
/// ### Helper Methods
/// - ``header(_:)``
public struct HTTPRequest: Sendable {
    /// HTTP method (GET, POST, OPTIONS, etc.)
    public let method: HTTPMethod

    /// Request path (e.g., "/mcp", "/health")
    public let path: String

    /// HTTP headers
    public let headers: [String: String]

    /// Request body (optional)
    public let body: Data?

    /// Initialize an HTTP request
    /// - Parameters:
    ///   - method: HTTP method
    ///   - path: Request path
    ///   - headers: HTTP headers (default: empty)
    ///   - body: Request body (default: nil)
    public init(
        method: HTTPMethod,
        path: String,
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    /// Get a header value (case-insensitive)
    /// - Parameter name: Header name
    /// - Returns: Header value if present
    public func header(_ name: String) -> String? {
        let lowercasedName = name.lowercased()
        return headers.first { $0.key.lowercased() == lowercasedName }?.value
    }
}

/// HTTP method enumeration
public enum HTTPMethod: String, Sendable {
    case get = "GET" // LIVE: public API for HTTP routing
    case post = "POST" // LIVE: public API for HTTP routing
    case put = "PUT" // LIVE: public API for HTTP routing
    case delete = "DELETE" // LIVE: public API for HTTP routing
    case patch = "PATCH" // LIVE: public API for HTTP routing
    case options = "OPTIONS" // LIVE: public API for HTTP routing
    case head = "HEAD" // LIVE: public API for HTTP routing
}

/// Platform-agnostic HTTP response representation
///
/// This value type provides a clean, testable representation of an HTTP response
/// that works across both Network framework and SwiftNIO implementations.
///
/// ## Usage Example
///
/// ```swift
/// let jsonData = Data(#"{"jsonrpc":"2.0","result":{},"id":1}"#.utf8)
/// let response = HTTPResponse(
///     statusCode: 200,
///     headers: ["Content-Type": "application/json"],
///     body: jsonData
/// )
/// ```
///
/// ## Topics
///
/// ### Creating Responses
/// - ``init(statusCode:headers:body:)``
/// - ``ok(body:contentType:)``
/// - ``notFound()``
/// - ``methodNotAllowed()``
/// - ``unauthorized()``
///
/// ### Response Properties
/// - ``statusCode``
/// - ``headers``
/// - ``body``
///
/// ### Converting to Data
/// - ``toData()``
public struct HTTPResponse: Sendable {
    /// HTTP status code (200, 404, etc.)
    public let statusCode: Int

    /// HTTP headers
    public let headers: [String: String]

    /// Response body
    public let body: Data

    /// Initialize an HTTP response
    /// - Parameters:
    ///   - statusCode: HTTP status code
    ///   - headers: HTTP headers (default: empty)
    ///   - body: Response body (default: empty)
    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    /// Create a 200 OK response
    /// - Parameters:
    ///   - body: Response body
    ///   - contentType: Content-Type header (default: "text/plain")
    /// - Returns: HTTP response
    public static func ok(body: Data, contentType: String = "text/plain") -> HTTPResponse {
        return HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": contentType],
            body: body
        )
    }

    /// Create a 404 Not Found response
    /// - Returns: HTTP response
    public static func notFound() -> HTTPResponse {
        return HTTPResponse(
            statusCode: 404,
            headers: ["Content-Type": "text/plain"],
            body: "Not Found".data(using: .utf8) ?? Data()
        )
    }

    /// Create a 405 Method Not Allowed response
    /// - Returns: HTTP response
    public static func methodNotAllowed() -> HTTPResponse {
        return HTTPResponse(
            statusCode: 405,
            headers: ["Content-Type": "text/plain"],
            body: "Method Not Allowed".data(using: .utf8) ?? Data()
        )
    }

    /// Create a 401 Unauthorized response
    /// - Returns: HTTP response
    public static func unauthorized() -> HTTPResponse {
        return HTTPResponse(
            statusCode: 401,
            headers: ["Content-Type": "text/plain"],
            body: "Unauthorized".data(using: .utf8) ?? Data()
        )
    }

    /// Convert response to raw HTTP/1.1 data
    /// - Returns: Complete HTTP response as Data
    public func toData() -> Data {
        let statusText = HTTPStatus.text(for: statusCode)

        // Build HTTP response headers
        var response = "HTTP/1.1 \(statusCode) \(statusText)\r\n"

        // Add headers
        var allHeaders = headers
        if !allHeaders.keys.contains(where: { $0.lowercased() == "content-length" }) {
            allHeaders["Content-Length"] = "\(body.count)"
        }
        if !allHeaders.keys.contains(where: { $0.lowercased() == "connection" }) {
            allHeaders["Connection"] = "close"
        }

        response += allHeaders.map { "\($0.key): \($0.value)\r\n" }.joined()
        response += "\r\n"

        // Combine headers and body
        var responseData = response.data(using: .utf8) ?? Data()
        responseData.append(body)

        return responseData
    }
}

/// HTTP status code utilities
///
/// Provides human-readable status text for HTTP status codes.
public enum HTTPStatus {
    /// Get status text for a status code
    /// - Parameter code: HTTP status code
    /// - Returns: Status text (e.g., "OK", "Not Found")
    public static func text(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return "Unknown"
        }
    }
}
