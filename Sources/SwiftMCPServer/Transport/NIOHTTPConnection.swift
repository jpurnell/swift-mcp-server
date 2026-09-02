import Foundation
#if canImport(os)
import os
#endif
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOFoundationCompat

private let nioConnectionLogger = Logger(subsystem: "com.swiftmcp", category: "NIOHTTPConnection")

/// SwiftNIO implementation of HTTPConnection
///
/// This class wraps a SwiftNIO `Channel` and provides the `HTTPConnection`
/// interface for sending data and managing the connection lifecycle.
///
/// ## Usage Example
///
/// ```swift
/// import NIOCore
///
/// // The channel comes from the NIO pipeline that accepted the request.
/// func reply(on channel: Channel, with responseData: Data) async throws {
///     let connection = NIOHTTPConnection(channel: channel)
///     try await connection.send(responseData)
///     await connection.close()
/// }
/// ```
///
/// ## Topics
///
/// ### Creating Connections
/// - ``init(channel:)``
///
/// ### Connection Properties
/// - ``id``
/// - ``remoteAddress``
/// - ``isActive``
///
/// ### Sending Data
/// - ``send(_:)``
///
/// ### Connection Management
/// - ``close()``
// Justification: all mutable state is accessed through the NIO Channel's EventLoop which serializes access
public final class NIOHTTPConnection: HTTPConnection, @unchecked Sendable {
    /// The underlying NIO channel
    private let channel: Channel

    /// Unique identifier for this connection
    public let id: String

    /// Remote address of the connected client
    public let remoteAddress: String

    /// Whether the connection is currently active
    public var isActive: Bool {
        get async {
            return channel.isActive
        }
    }

    /// Initialize with a NIO channel
    /// - Parameter channel: The NIO channel to wrap
    public init(channel: Channel) {
        self.channel = channel
        // Use ObjectIdentifier for unique channel ID
        let hex = String(ObjectIdentifier(channel).hashValue, radix: 16, uppercase: false)
        self.id = String(repeating: "0", count: max(0, 16 - hex.count)) + hex
        self.remoteAddress = channel.remoteAddress?.description ?? "unknown"
    }

    /// Send raw data to the client (used for SSE streaming where .head was already sent)
    /// - Parameter data: Data to send as .body part
    /// - Throws: HTTPConnectionError if the operation fails
    public func send(_ data: Data) async throws {
        guard channel.isActive else {
            throw HTTPConnectionError.connectionInactive
        }

        do {
            // Convert Data to ByteBuffer
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)

            // Capture buffer immutably for sendable closure
            let finalBuffer = buffer

            // Ensure write happens on the EventLoop
            // Write as HTTPServerResponsePart.body for SSE streaming (head already sent)
            try await channel.eventLoop.submit {
                let part = HTTPServerResponsePart.body(.byteBuffer(finalBuffer))
                return self.channel.writeAndFlush(part)
            }.flatMap { $0 }.get()
        } catch {
            throw HTTPConnectionError.writeFailed(error)
        }
    }

    /// Send a complete HTTP response with proper NIO framing (.head, .body, .end)
    ///
    /// Unlike `send()` which only writes a `.body` part (for SSE streaming),
    /// this method writes the full `.head`, `.body`, `.end` sequence that
    /// NIO's HTTPResponseEncoder expects.
    public func sendHTTPResponse(statusCode: Int, headers: [(String, String)], body: Data) async throws {
        guard channel.isActive else {
            throw HTTPConnectionError.connectionInactive
        }

        do {
            var httpHeaders = HTTPHeaders()
            for (name, value) in headers {
                httpHeaders.add(name: name, value: value)
            }

            let status = HTTPResponseStatus(statusCode: statusCode)
            let responseHead = HTTPResponseHead(version: .http1_1, status: status, headers: httpHeaders)

            var buffer = channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            let finalBuffer = buffer

            // Write .head, .body, .end on the EventLoop in sequence
            try await channel.eventLoop.submit {
                self.channel.write(HTTPServerResponsePart.head(responseHead), promise: nil)
                self.channel.write(HTTPServerResponsePart.body(.byteBuffer(finalBuffer)), promise: nil)
                return self.channel.writeAndFlush(HTTPServerResponsePart.end(nil))
            }.flatMap { $0 }.get()
        } catch {
            throw HTTPConnectionError.writeFailed(error)
        }
    }

    /// Close the connection
    /// Sends the response head with a `200` status, leaving the body open.
    ///
    /// - Parameter headers: Response headers as (name, value) pairs.
    public func sendSSEHead(headers: [(String, String)]) async {
        let channel = self.channel
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            channel.eventLoop.execute {
                var httpHeaders = HTTPHeaders()
                for (name, value) in headers { httpHeaders.add(name: name, value: value) }
                let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: httpHeaders)
                channel.write(HTTPServerResponsePart.head(head), promise: nil)
                channel.flush()
                continuation.resume()
            }
        }
    }

    /// Closes the channel, ending any stream still open on it.
    public func close() async {
        do {
            try await channel.close()
        } catch {
            nioConnectionLogger.debug("Close error (best-effort): \(error.localizedDescription, privacy: .public)")
        }
    }
}
