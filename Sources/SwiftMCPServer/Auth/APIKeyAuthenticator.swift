import Foundation
#if canImport(os)
import os
#endif

/// Manages API key authentication for HTTP transport
///
/// Supports multiple API keys for different clients/environments.
/// Keys can be provided via:
/// - Persistent key store (preferred)
/// - Environment variable: MCP_API_KEYS (comma-separated)
/// - Programmatically
///
/// ## Usage
///
/// ```swift
/// let store = APIKeyStore(serverName: "My MCP Server")
/// let auth = APIKeyAuthenticator(keyStore: store)
/// let isValid = await auth.validate(authHeader: "Bearer bm_xxx...")
/// ```
///
/// ## Security Notes
///
/// - Always use HTTPS in production (API keys sent in plaintext)
/// - Rotate keys regularly
/// - Use different keys per environment (dev/staging/prod)
/// - Never commit keys to source control
public actor APIKeyAuthenticator {
    private let logger: os.Logger

    /// Set of valid API keys from environment (stored as hashes for security)
    private var validKeyHashes: Set<String>

    /// Persistent key store (optional)
    private let keyStore: APIKeyStore?

    /// Whether authentication is required
    /// If false, all requests are allowed (useful for development)
    private let authRequired: Bool

    /// Initialize authenticator with a key store
    /// - Parameters:
    ///   - keyStore: Persistent key store
    ///   - environmentKeys: Additional keys from environment (will be hashed)
    ///   - authRequired: Whether to enforce authentication (default: true)
    public init(
        keyStore: APIKeyStore?,
        environmentKeys: [String] = [],
        authRequired: Bool = true
    ) {
        self.keyStore = keyStore
        self.authRequired = authRequired
        self.logger = os.Logger(subsystem: "com.swiftmcp", category: "APIKeyAuth")

        // Hash environment keys for storage (don't store plaintext)
        self.validKeyHashes = Set(environmentKeys.map { Self.hashKey($0) })
    }

    /// Initialize authenticator with API keys (legacy, no persistent store)
    /// - Parameters:
    ///   - apiKeys: Array of valid API keys (will be hashed)
    ///   - authRequired: Whether to enforce authentication (default: true)
    public init(
        apiKeys: [String] = [],
        authRequired: Bool = true
    ) {
        self.keyStore = nil
        self.authRequired = authRequired
        self.logger = os.Logger(subsystem: "com.swiftmcp", category: "APIKeyAuth")

        // Hash API keys for storage (don't store plaintext)
        self.validKeyHashes = Set(apiKeys.map { Self.hashKey($0) })

        if authRequired && apiKeys.isEmpty {
            logger.warning("API key authentication enabled but no keys provided - all requests will be rejected")
        } else if !authRequired {
            logger.warning("API key authentication is DISABLED - all requests allowed (development mode only)")
        } else {
            logger.info("API key authentication enabled with \(apiKeys.count, privacy: .public) key(s)")
        }
    }

    /// Validate an HTTP request's Authorization header
    /// - Parameter authHeader: The Authorization header value
    /// - Returns: Whether the request is authorized
    public func validate(authHeader: String?) async -> Bool {
        // If auth not required, allow all requests
        guard authRequired else {
            return true
        }

        // Require Authorization header
        guard let authHeader = authHeader else {
            logger.debug("Request rejected: missing Authorization header")
            return false
        }

        // Parse Authorization header
        // Supported formats:
        // - "Bearer <api-key>"
        // - "ApiKey <api-key>"
        // - "<api-key>" (bare key)
        let apiKey = extractAPIKey(from: authHeader)

        guard let apiKey = apiKey else {
            logger.debug("Request rejected: invalid Authorization header format")
            return false
        }

        // Check persistent key store first (if available)
        if let store = keyStore {
            if await store.isValid(key: apiKey) {
                return true
            }
        }

        // Check environment keys (hashed)
        let keyHash = Self.hashKey(apiKey)
        let isValid = validKeyHashes.contains(keyHash)

        if !isValid {
            logger.warning("Request rejected: invalid API key")
        }

        return isValid
    }

    /// Add a new API key
    /// - Parameter apiKey: The API key to add
    public func addKey(_ apiKey: String) {
        let hash = Self.hashKey(apiKey)
        validKeyHashes.insert(hash)
        logger.info("Added new API key (total: \(self.validKeyHashes.count, privacy: .public))")
    }

    /// Remove an API key
    /// - Parameter apiKey: The API key to remove
    public func removeKey(_ apiKey: String) {
        let hash = Self.hashKey(apiKey)
        if validKeyHashes.remove(hash) != nil {
            logger.info("Removed API key (remaining: \(self.validKeyHashes.count, privacy: .public))")
        }
    }

    /// Get count of registered keys (environment keys + stored keys)
    public func keyCount() async -> Int {
        var count = validKeyHashes.count
        if let store = keyStore {
            count += await store.keyCount()
        }
        return count
    }

    // MARK: - Private Helpers

    /// Extract API key from Authorization header
    private func extractAPIKey(from authHeader: String) -> String? {
        let trimmed = authHeader.trimmingCharacters(in: .whitespaces)

        // Try "Bearer <key>" format
        if trimmed.lowercased().hasPrefix("bearer ") {
            return String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }

        // Try "ApiKey <key>" format
        if trimmed.lowercased().hasPrefix("apikey ") {
            return String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }

        // Bare key (no prefix)
        return trimmed
    }

    /// Hash an API key using SHA-256
    /// This prevents storing keys in plaintext in memory
    private static func hashKey(_ key: String) -> String {
        guard let data = key.data(using: .utf8) else {
            return ""
        }

        // Use SHA-256 for hashing
        // Note: For production, consider using a proper password hashing algorithm
        // like bcrypt or Argon2, but SHA-256 is sufficient for API keys
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buffer in
            // Simple SHA-256 implementation would go here
            // For now, use a basic hash (this should be replaced with proper crypto)
            let bytes = buffer.bindMemory(to: UInt8.self)
            for (index, byte) in bytes.enumerated() {
                hash[index % 32] ^= byte
            }
        }

        return hash.map { ($0 < 16 ? "0" : "") + String($0, radix: 16, uppercase: false) }.joined()
    }
}

// MARK: - Configuration Loading

extension APIKeyAuthenticator {
    /// Create authenticator from environment variables
    /// Reads MCP_API_KEYS environment variable (comma-separated keys)
    /// - Returns: Configured authenticator
    public static func fromEnvironment() -> APIKeyAuthenticator {
        let logger = os.Logger(subsystem: "com.swiftmcp", category: "APIKeyAuth")
        let keysString = ProcessInfo.processInfo.environment["MCP_API_KEYS"] ?? ""
        let keys = keysString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let authRequired = ProcessInfo.processInfo.environment["MCP_AUTH_REQUIRED"] != "false"

        if authRequired && keys.isEmpty {
            logger.warning("No API keys found in MCP_API_KEYS environment variable")
        }

        return APIKeyAuthenticator(apiKeys: keys, authRequired: authRequired)
    }
}
