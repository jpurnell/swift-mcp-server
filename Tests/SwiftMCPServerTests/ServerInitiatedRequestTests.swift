import Foundation
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SwiftMCPServer
import MCP

/// The pre-`2026-07-28` channel: a server asking the client something in the middle of handling
/// a request, and waiting for the answer.
///
/// **This mechanism is removed in `2026-07-28`.** A stateless server has nowhere to call back
/// to, which is why SEP-2322 replaced it: the server answers `resultType: "input_required"` and
/// the client retries with what it gathered. Both are implemented here, because this package
/// serves both revisions and a client on `2025-11-25` has only this one.
///
/// The exchange is three HTTP messages, not one: the POST's response becomes an SSE stream, the
/// server's question is an event on it, the client answers with a *separate* POST, and the
/// original stream then carries the result and closes.
@Suite("Server-initiated requests")
struct ServerInitiatedRequestTests {

    /// Collects the events arriving on a streamed response.
    // Justification: appended by the reading task and read after it has been awaited
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [[String: Any]] = []

        func append(_ message: [String: Any]) {
            lock.lock(); defer { lock.unlock() }
            messages.append(message)
        }

        var all: [[String: Any]] {
            lock.lock(); defer { lock.unlock() }
            return messages
        }
    }

    private func url(port: UInt16) throws -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "localhost"
        components.port = Int(port)
        components.path = "/mcp"
        return try #require(components.url)
    }

    /// A server whose one tool asks the client to elicit before it can answer.
    private func startServer(port: UInt16) async throws -> HTTPServerTransport {
        let transport = HTTPServerTransport(port: port)
        let server = Server(
            name: "asks-the-client", version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false)))

        await server.withMethodHandler(CallTool.self) { [weak server] _ in
            guard let server else { throw MCPError.internalError("server went away") }
            let answer = try await server.requestElicitation(
                message: "What is your name?",
                requestedSchema: .init(
                    properties: ["name": .object(["type": .string("string")])],
                    required: ["name"]))
            let name = answer.content?["name"]?.stringValue ?? "nobody"
            return CallTool.Result(
                content: [.text(text: "Hello, \(name)!", annotations: nil, _meta: nil)],
                isError: false, resultType: .complete)
        }
        try await server.start(transport: transport)
        try await Task.sleep(nanoseconds: 400_000_000)
        return transport
    }

    /// The exchange a pre-2026 client performs, end to end.
    @Test("A tool can ask the client a question and use the answer")
    func testServerAsksClientMidRequest() async throws {
        let transport = try await startServer(port: 9390)
        defer { Task { await transport.disconnect() } }

        var request = URLRequest(url: try url(port: 9390))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "ask", "arguments": [:]],
        ])

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(for: request)

        let http = try #require(response as? HTTPURLResponse)
        #expect(
            http.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true,
            "the response became a stream because the server had to ask something")

        // Read events until the tool's own result arrives. The question comes first; answering
        // it is what lets the result exist at all.
        let events = Events()
        for try await line in stream.lines where line.hasPrefix("data: ") {
            let payload = String(line.dropFirst("data: ".count))
            guard let message = try? JSONSerialization.jsonObject(with: Data(payload.utf8))
                as? [String: Any]
            else { continue }
            events.append(message)

            if message["method"] as? String == "elicitation/create" {
                try await answer(message, to: 9390)
                continue
            }
            if message["result"] != nil || message["error"] != nil { break }
        }

        let collected = events.all
        let question = try #require(
            collected.first { $0["method"] as? String == "elicitation/create" },
            "the server's question must arrive on the stream")
        let params = try #require(question["params"] as? [String: Any])
        #expect(params["message"] as? String == "What is your name?")

        let result = try #require(collected.last?["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        #expect(
            content.first?["text"] as? String == "Hello, Ada!",
            "the tool used what the client answered")
    }

    /// Answers the server's question with a separate POST, as a client does.
    private func answer(_ question: [String: Any], to port: UInt16) async throws {
        var request = URLRequest(url: try url(port: port))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": question["id"] ?? 0,
            "result": ["action": "accept", "content": ["name": "Ada"]],
        ])

        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        #expect(
            status == 202,
            "an answer is acknowledged, not answered — what it unblocks goes to the other stream")
    }
}
