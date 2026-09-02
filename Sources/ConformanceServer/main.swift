import Foundation
import ConformanceFixtures
import MCP
import SwiftMCPServer

/// Runs the conformance target over HTTP so the official suite can drive it.
///
/// Everything about *what* the target exposes lives in ``ConformanceTarget``, which the package's
/// own tests use too. This file only opens the port.
///
/// Run it, then point the suite at `http://localhost:3002/mcp`.
@main
struct ConformanceServerMain {
    static func main() async throws {
        let port: UInt16 = UInt16(ProcessInfo.processInfo.environment["PORT"] ?? "") ?? 3002

        // `.loopback`, because this target *is* the localhost server GHSA-w48q-cv73-mx4w is
        // about: no TLS, no API key, reachable by anything that can resolve a name to 127.0.0.1.
        // The package's default is `.any` so deployed servers are not taken off the air on
        // upgrade; a server in this shape is the one that must opt in.
        let transport = HTTPServerTransport(
            port: port, allowedHosts: .loopback, tools: ConformanceTarget.tools,
            subscribableNotifications: ConformanceTarget.subscribableNotifications)
        let server = await ConformanceTarget.makeServer(
            subscriptions: SubscriptionState(), streams: transport.subscriptionStreams)

        try await server.start(transport: transport)
        FileHandle.standardError.write(Data("conformance server listening on \(port)\n".utf8))
        await server.waitUntilCompleted()
    }
}
