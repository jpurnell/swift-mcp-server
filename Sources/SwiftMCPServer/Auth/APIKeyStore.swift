import Foundation
import Crypto
#if canImport(os)
import os
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private let keyStoreLogger = Logger(subsystem: "com.swiftmcp", category: "APIKeyStore")

// MARK: - APIKeyStoreError

/// Errors thrown by ``APIKeyStore``
public enum APIKeyStoreError: Error, Sendable, Equatable {
    /// The store's advisory lock could not be acquired, so a mutation was refused
    /// rather than risk overwriting a concurrent writer in another process.
    case lockUnavailable
}

// MARK: - APIKey Model

/// A persistent API key for authentication
///
/// API keys use the format `bm_<32-character-base64url>` for easy identification.
///
/// ## Example
/// ```swift
/// let key = APIKey.generate(name: "Claude Code")
/// print(key.key)  // bm_7Kx9mPqR2sT4vW6xY8zA0bC3dE5fG7hJ
/// ```
public struct APIKey: Codable, Sendable, Equatable {
    /// The full API key string (e.g., "bm_xxxx...")
    public let key: String

    /// Human-readable name for this key
    public let name: String

    /// When this key was created
    public let created: Date

    /// When this key was last used (nil if never used)
    public var lastUsed: Date?

    /// The key prefix for identification (e.g., "bm_7Kx9mP...")
    public var prefix: String {
        String(key.prefix(10)) + "..."
    }

    // MARK: - Key Generation

    /// Generates a new API key with the standard format
    ///
    /// - Parameters:
    ///   - name: Human-readable name for the key
    ///   - rng: Random number generator to use
    /// - Returns: A new API key
    public static func generate(name: String, using rng: inout some RandomNumberGenerator) -> APIKey {
        let randomBytes = (0..<24).map { _ in UInt8.random(in: 0...255, using: &rng) }
        let base64 = Data(randomBytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        // Take first 32 characters
        let keyValue = "bm_" + String(base64.prefix(32))

        return APIKey(
            key: keyValue,
            name: name,
            created: Date(),
            lastUsed: nil
        )
    }

    /// Generates a new API key with the standard format
    ///
    /// - Parameter name: Human-readable name for the key
    /// - Returns: A new API key
    public static func generate(name: String) -> APIKey {
        var rng = SystemRandomNumberGenerator() // stochastic:exempt convenience wrapper; injectable overload above
        return generate(name: name, using: &rng)
    }

    // MARK: - Validation

    /// Validates if a string matches the API key format
    ///
    /// - Parameter key: The key string to validate
    /// - Returns: `true` if the format is valid
    public static func isValidFormat(_ key: String) -> Bool {
        guard key.hasPrefix("bm_") else { return false }
        guard key.count == 35 else { return false }  // bm_ (3) + 32 chars

        // Check that remaining characters are base64url-safe
        let suffix = String(key.dropFirst(3))
        let validChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return suffix.unicodeScalars.allSatisfy { validChars.contains($0) }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case key
        case name
        case created
        case lastUsed = "last_used"
    }
}

// MARK: - APIKeySummary

/// A summary of an API key without exposing the full key value
public struct APIKeySummary: Sendable {
    /// The key prefix (e.g., "bm_7Kx9mP...")
    public let prefix: String

    /// Human-readable name
    public let name: String

    /// Creation date
    public let created: Date

    /// Last used date (nil if never used)
    public let lastUsed: Date?
}

// MARK: - APIKeyStore

/// Actor for managing persistent API keys
///
/// Stores keys in `~/.businessmath-mcp/api-keys.json` by default.
///
/// ## Example
/// ```swift
/// let store = APIKeyStore()
/// let key = try await store.generateKey(name: "Claude Code")
/// print(key.key)  // Use this in Authorization header
/// ```
public actor APIKeyStore {
    /// Directory for storing keys
    private let directory: URL

    /// File path for the keys JSON file
    ///
    /// The directory is standardized first so any traversal sequences in a
    /// caller-supplied path are resolved before the file is touched.
    private var keysFile: URL {
        directory.standardized.appendingPathComponent("api-keys.json")
    }

    /// In-memory cache of keys
    private var keys: [APIKey] = []

    /// Whether keys have been loaded from disk
    private var loaded = false

    /// Modification date of the key file as of the last read, used to detect
    /// changes written by another process.
    private var loadedModificationDate: Date?

    // MARK: - Initialization

    /// Creates a key store with the default directory (~/.businessmath-mcp)
    public init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        self.directory = homeDir.appendingPathComponent(".businessmath-mcp")
    }

    /// Creates a key store with a custom directory
    ///
    /// - Parameter directory: Directory to store keys in
    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: - Key Management

    /// Generates and saves a new API key
    ///
    /// The key file is re-read under an exclusive lock before the new key is appended,
    /// so generating a key never discards keys written by another process — for example
    /// the CLI adding a key while a long-running server holds the same store open.
    ///
    /// - Parameter name: Human-readable name for the key
    /// - Returns: The generated key
    /// - Throws: ``APIKeyStoreError/lockUnavailable`` if the store cannot be locked,
    ///   or an encoding/IO error if the key cannot be saved.
    public func generateKey(name: String) throws -> APIKey {
        let lock = try acquireLock()
        defer { releaseLock(lock) }

        try loadFromDisk()

        let key = APIKey.generate(name: name)
        keys.append(key)
        try save()

        return key
    }

    /// Lists all stored keys
    ///
    /// Re-reads the key file if another process has modified it since the last read.
    ///
    /// - Returns: Array of all keys
    public func listKeys() throws -> [APIKey] {
        try ensureFresh()
        return keys
    }

    /// Lists key summaries without exposing full key values
    ///
    /// - Returns: Array of key summaries
    public func listKeySummaries() -> [APIKeySummary] {
        do {
            try ensureFresh()
        } catch {
            keyStoreLogger.debug("Failed to load keys: \(error.localizedDescription, privacy: .public)")
            return []
        }

        return keys.map { key in
            APIKeySummary(
                prefix: key.prefix,
                name: key.name,
                created: key.created,
                lastUsed: key.lastUsed
            )
        }
    }

    /// Validates if a key exists and is valid
    ///
    /// Writing the last-used timestamp is a read-modify-write of the shared key file,
    /// so it is performed under an exclusive lock against a freshly read copy. Without
    /// that, a long-running server would persist its stale in-memory snapshot and erase
    /// keys added by other processes.
    ///
    /// - Parameter key: The full key string to validate
    /// - Returns: `true` if the key is valid
    public func isValid(key: String) -> Bool {
        guard let lock = try? acquireLock() else { // silent: lock failure is handled by the degraded path below
            // Degraded path: answer from the freshest readable copy and skip the
            // timestamp write rather than risk clobbering a concurrent writer.
            try? ensureFresh() // silent: validation must still answer if the reload fails
            return keys.contains { $0.key == key }
        }
        defer { releaseLock(lock) }

        do {
            try loadFromDisk()
        } catch {
            keyStoreLogger.debug("Failed to load keys: \(error.localizedDescription, privacy: .public)")
            return false
        }

        guard let index = keys.firstIndex(where: { $0.key == key }) else {
            return false
        }

        // Update last used timestamp
        var updatedKey = keys[index]
        updatedKey.lastUsed = Date()
        keys[index] = updatedKey

        try? save() // silent: last-used timestamp update is non-critical

        return true
    }

    /// Revokes a key by its prefix
    ///
    /// Re-reads the key file under an exclusive lock before removing, so a revocation
    /// cannot resurrect keys deleted by another process or be undone by one.
    ///
    /// - Parameter prefix: The key prefix (at least 6 characters)
    /// - Returns: `true` if a key was revoked
    /// - Throws: ``APIKeyStoreError/lockUnavailable`` if the store cannot be locked,
    ///   or an encoding/IO error if the change cannot be saved.
    public func revokeKey(prefix: String) throws -> Bool {
        let lock = try acquireLock()
        defer { releaseLock(lock) }

        try loadFromDisk()

        let initialCount = keys.count
        keys.removeAll { $0.key.hasPrefix(prefix) }

        guard keys.count != initialCount else { return false }

        try save()
        return true
    }

    /// Returns the number of stored keys
    public func keyCount() -> Int {
        do {
            try ensureFresh()
        } catch {
            keyStoreLogger.debug("Failed to load keys: \(error.localizedDescription, privacy: .public)")
            return 0
        }
        return keys.count
    }

    // MARK: - Persistence

    /// Reads the key file only when it is stale.
    ///
    /// The store is shared between processes, so an in-memory copy can be outdated at
    /// any time. Comparing the file's modification date against the one captured at the
    /// last read keeps the common case to a single `stat` while still picking up writes
    /// made elsewhere.
    private func ensureFresh() throws {
        guard loaded, fileModificationDate() == loadedModificationDate else {
            try loadFromDisk()
            return
        }
    }

    /// Unconditionally reads the key file into memory, replacing the cache.
    private func loadFromDisk() throws {
        // Create directory if needed (standardize path to prevent traversal)
        let standardizedDirectory = directory.standardized
        try FileManager.default.createDirectory(
            at: standardizedDirectory,
            withIntermediateDirectories: true
        )

        // Load existing keys if file exists
        if (try? keysFile.checkResourceIsReachable()) == true { // silent: file may not exist yet

            let data = try Data(contentsOf: keysFile)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let container = try decoder.decode(KeysContainer.self, from: data)
            keys = container.keys
        } else {
            keys = []
        }

        loadedModificationDate = fileModificationDate()
        loaded = true
    }

    /// Modification date of the key file, or `nil` if it does not exist yet.
    ///
    /// Reads through the URL resource API rather than a string path, so no filesystem
    /// call is made against an unvalidated path string.
    private func fileModificationDate() -> Date? {
        let values = try? keysFile.resourceValues(forKeys: [.contentModificationDateKey]) // silent: absent file is a valid state, reported as nil
        return values?.contentModificationDate
    }

    private func save() throws {
        let container = KeysContainer(keys: keys)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(container)
        try data.write(to: keysFile, options: .atomic)

        // Set restrictive permissions (owner read/write only)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: keysFile.path
        )

        // The cache now matches what is on disk; record the new stamp so the next
        // freshness check does not trigger a redundant reload.
        loadedModificationDate = fileModificationDate()
    }

    // MARK: - Cross-Process Locking

    /// Acquires an exclusive advisory lock covering the key file.
    ///
    /// A dedicated lock file is used rather than the key file itself, because saving
    /// writes atomically via a replacement inode — a lock held on the old file would
    /// not be seen by the next writer.
    ///
    /// - Returns: The open file descriptor holding the lock.
    /// - Throws: ``APIKeyStoreError/lockUnavailable`` if the lock cannot be taken.
    private func acquireLock() throws -> Int32 {
        let standardizedDirectory = directory.standardized
        try FileManager.default.createDirectory(
            at: standardizedDirectory,
            withIntermediateDirectories: true
        )

        let lockPath = standardizedDirectory.appendingPathComponent(".api-keys.lock").path
        let descriptor = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else {
            throw APIKeyStoreError.lockUnavailable
        }

        guard flock(descriptor, LOCK_EX) == 0 else {
            close(descriptor)
            throw APIKeyStoreError.lockUnavailable
        }

        return descriptor
    }

    /// Releases a lock previously taken by ``acquireLock()``.
    ///
    /// - Parameter descriptor: The descriptor returned by ``acquireLock()``.
    private func releaseLock(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    /// Container for JSON serialization
    private struct KeysContainer: Codable {
        let keys: [APIKey]
    }
}
