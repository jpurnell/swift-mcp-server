import Foundation
#if canImport(os)
import os
#endif

/// Manages MCP Streamable HTTP sessions (spec 2025-03-26)
///
/// Each session is created when an `initialize` JSON-RPC request arrives.
/// The session ID is returned via the `Mcp-Session-Id` response header
/// and must be included on all subsequent requests.
public actor StreamableSessionManager {
    private let logger: os.Logger

    /// Active sessions keyed by Mcp-Session-Id
    private var sessions: [String: StreamableSession] = [:]

    /// Session timeout (default: 30 minutes)
    private let sessionTimeout: TimeInterval

    /// Cleanup task
    private var cleanupTask: Task<Void, Never>?

    /// Heartbeat task for SSE connections
    private var heartbeatTask: Task<Void, Never>?

    /// A Streamable HTTP session
    struct StreamableSession {
        let sessionId: String
        let createdAt: Date
        var lastActivityAt: Date
        /// SSE connections for server-initiated messages (GET /mcp streams)
        var sseConnections: [SSESession] = []
    }

    /// Creates a new session manager with the given timeout
    public init(
        sessionTimeout: TimeInterval = 1800.0
    ) {
        self.sessionTimeout = sessionTimeout
        self.logger = os.Logger(subsystem: "com.swiftmcp", category: "StreamableSessionManager")
    }

    // MARK: - Session Lifecycle

    /// Create a new session (called on `initialize` request)
    public func createSession() -> String {
        let sessionId = UUID().uuidString
        sessions[sessionId] = StreamableSession(
            sessionId: sessionId,
            createdAt: Date(),
            lastActivityAt: Date()
        )
        logger.info("Created streamable session: \(sessionId, privacy: .public)")
        return sessionId
    }

    /// Validate that a session ID exists and is active
    public func validateSession(_ sessionId: String) -> Bool {
        return sessions[sessionId] != nil
    }

    /// Update last activity time for a session
    public func touchSession(_ sessionId: String) {
        sessions[sessionId]?.lastActivityAt = Date()
    }

    /// Remove a session (called on DELETE /mcp)
    /// - Returns: true if session existed and was removed
    public func removeSession(_ sessionId: String) -> Bool {
        guard let session = sessions.removeValue(forKey: sessionId) else {
            return false
        }
        // Close any SSE connections
        for sse in session.sseConnections {
            Task { await sse.close() }
        }
        logger.info("Removed streamable session: \(sessionId, privacy: .public)")
        return true
    }

    /// Add an SSE connection to a session (for GET /mcp streams)
    public func addSSEConnection(_ sseSession: SSESession, to sessionId: String) {
        sessions[sessionId]?.sseConnections.append(sseSession)
        logger.debug("Added SSE connection to session \(sessionId, privacy: .public)")
    }

    /// Get active SSE connections for a session (for broadcasting server-initiated messages)
    public func getSSEConnections(for sessionId: String) -> [SSESession] {
        return sessions[sessionId]?.sseConnections ?? []
    }

    /// Broadcast data to all SSE connections across all sessions
    public func broadcastToAllSSE(_ data: Data) async -> Bool {
        guard let jsonString = String(data: data, encoding: .utf8) else { return false }
        var sent = false
        for session in sessions.values {
            for sse in session.sseConnections {
                await sse.sendEvent(event: "message", data: jsonString)
                sent = true
            }
        }
        return sent
    }

    /// Get count of active sessions
    public func activeSessionCount() -> Int {
        return sessions.count
    }

    // MARK: - Maintenance

    /// Starts periodic cleanup and heartbeat tasks
    public func startMaintenance() {
        guard cleanupTask == nil else { return }

        cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // silent: sleep cancellation is expected during shutdown
                await self?.cleanupExpiredSessions()
            }
        }

        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // silent: sleep cancellation is expected during shutdown
                await self?.sendHeartbeats()
            }
        }

        logger.info("Started streamable session maintenance")
    }

    /// Stops the periodic cleanup and heartbeat tasks
    public func stopMaintenance() {
        cleanupTask?.cancel()
        cleanupTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    /// Shuts down all sessions and cancels maintenance tasks
    public func shutdown() {
        stopMaintenance()
        for session in sessions.values {
            for sse in session.sseConnections {
                Task { await sse.close() }
            }
        }
        sessions.removeAll()
        logger.info("Streamable session manager shutdown complete")
    }

    private func cleanupExpiredSessions() {
        let now = Date()
        let expired = sessions.filter { now.timeIntervalSince($0.value.lastActivityAt) > sessionTimeout }
        for (id, session) in expired {
            sessions.removeValue(forKey: id)
            for sse in session.sseConnections {
                Task { await sse.close() }
            }
            logger.info("Cleaned up expired streamable session: \(id, privacy: .public)")
        }
    }

    private func sendHeartbeats() {
        for session in sessions.values {
            for sse in session.sseConnections {
                Task { await sse.sendHeartbeat() }
            }
        }
    }
}
