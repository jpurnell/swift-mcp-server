import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SwiftMCPServer

/// Frame-boundary parsing for the SSE test client.
///
/// The SSE grammar lets a line end with CRLF, a bare LF, or a bare CR, and a blank line ends
/// an event. Swift represents "\r\n" as a single `Character`, so a boundary search written
/// against `"\n\n"` matches only the all-LF stream — the one form these tests used to cover
/// exclusively, which is why the suite stayed green with CRLF frames undetectable.
@Suite("SSE Frame Parsing")
struct SSEFrameParsingTests {

    /// Build a two-event stream using `terminator` to end every line.
    private func stream(terminator: String) -> String {
        "event: endpoint\(terminator)data: /mcp?sessionId=abc\(terminator)\(terminator)"
            + "event: message\(terminator)data: {\"jsonrpc\":\"2.0\"}\(terminator)\(terminator)"
    }

    @Test("CRLF-terminated frames are detected", arguments: [
        ("CRLF", "\r\n"),
        ("LF", "\n"),
        ("CR", "\r")
    ])
    func framesParseUnderEveryTerminator(name: String, terminator: String) throws {
        let delegate = MCPSSEDelegate()
        delegate.ingest(stream(terminator: terminator))

        let events = delegate.getAllEvents()
        #expect(events.count == 2, "\(name): expected 2 events, got \(events.count)")

        let first = try #require(events.first, "\(name): no first event")
        #expect(first.type == "endpoint")
        #expect(first.data == "/mcp?sessionId=abc")

        let second = try #require(events.dropFirst().first, "\(name): no second event")
        #expect(second.type == "message")
        #expect(second.data == "{\"jsonrpc\":\"2.0\"}")
    }

    /// A CR arriving at the end of one chunk and its LF at the start of the next is one
    /// terminator, not two. Normalising each chunk as it lands would fabricate a blank line
    /// here and split a single event in half.
    @Test("A CRLF split across two chunks is not a frame boundary")
    func crlfSplitAcrossChunksIsNotABoundary() throws {
        let delegate = MCPSSEDelegate()
        delegate.ingest("event: message\rdata: first-half\r")
        delegate.ingest("\ndata: second-half\r\n\r\n")

        let events = delegate.getAllEvents()
        #expect(events.count == 1, "expected the chunks to join into 1 event, got \(events.count)")

        let event = try #require(events.first)
        #expect(event.data == "first-half\nsecond-half")
    }

    /// The failure mode the old parser produced: with no boundary ever found, nothing is
    /// emitted and every byte received stays in the buffer.
    @Test("An unterminated frame yields no event and is retained for the next chunk")
    func unterminatedFrameIsRetained() throws {
        let delegate = MCPSSEDelegate()
        delegate.ingest("event: message\r\ndata: partial\r\n")
        #expect(delegate.getAllEvents().isEmpty)

        delegate.ingest("\r\n")
        let events = delegate.getAllEvents()
        #expect(events.count == 1)
        #expect(try #require(events.first).data == "partial")
    }
}
