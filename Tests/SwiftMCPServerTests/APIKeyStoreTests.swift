import Testing
import Foundation
@testable import SwiftMCPServer

/// Tests for API Key model and storage
@Suite("API Key Store")
struct APIKeyStoreTests {

    // MARK: - APIKey Model Tests

    @Suite("APIKey Model")
    struct APIKeyModelTests {

        @Test("Key has correct prefix")
        func keyHasCorrectPrefix() {
            let key = APIKey.generate(name: "Test")
            #expect(key.key.hasPrefix("bm_"))
        }

        @Test("Key has correct length")
        func keyHasCorrectLength() {
            let key = APIKey.generate(name: "Test")
            // bm_ (3) + 32 chars = 35 total
            #expect(key.key.count == 35)
        }

        @Test("Key stores name")
        func keyStoresName() {
            let key = APIKey.generate(name: "Claude Code")
            #expect(key.name == "Claude Code")
        }

        @Test("Key has creation date")
        func keyHasCreationDate() {
            let before = Date()
            let key = APIKey.generate(name: "Test")
            let after = Date()

            #expect(key.created >= before)
            #expect(key.created <= after)
        }

        @Test("Key initializes with nil lastUsed")
        func keyInitializesWithNilLastUsed() {
            let key = APIKey.generate(name: "Test")
            #expect(key.lastUsed == nil)
        }

        @Test("Generated keys are unique")
        func generatedKeysAreUnique() {
            let key1 = APIKey.generate(name: "Test1")
            let key2 = APIKey.generate(name: "Test2")
            #expect(key1.key != key2.key)
        }

        @Test("Key validates correct format")
        func keyValidatesCorrectFormat() {
            #expect(APIKey.isValidFormat("bm_7Kx9mPqR2sT4vW6xY8zA0bC3dE5fG7hJ"))
            #expect(APIKey.isValidFormat("bm_aB1cD2eF3gH4iJ5kL6mN7oP8qR9sT0uV"))
        }

        @Test("Key rejects invalid formats")
        func keyRejectsInvalidFormats() {
            // Wrong prefix
            #expect(!APIKey.isValidFormat("xx_7Kx9mPqR2sT4vW6xY8zA0bC3dE5fG7hJ"))
            // Too short
            #expect(!APIKey.isValidFormat("bm_abc"))
            // Too long
            #expect(!APIKey.isValidFormat("bm_7Kx9mPqR2sT4vW6xY8zA0bC3dE5fG7hJextra"))
            // No prefix
            #expect(!APIKey.isValidFormat("7Kx9mPqR2sT4vW6xY8zA0bC3dE5fG7hJ"))
            // Empty
            #expect(!APIKey.isValidFormat(""))
        }

        @Test("Key is Codable")
        func keyIsCodable() throws {
            let original = APIKey.generate(name: "Test")

            let encoder = JSONEncoder()
            let data = try encoder.encode(original)

            let decoder = JSONDecoder()
            let decoded = try decoder.decode(APIKey.self, from: data)

            #expect(decoded.key == original.key)
            #expect(decoded.name == original.name)
        }
    }

    // MARK: - APIKeyStore Tests

    @Suite("APIKeyStore Persistence")
    struct APIKeyStorePersistenceTests {

        @Test("Creates storage directory if missing")
        func createsStorageDirectory() async throws {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            let store = APIKeyStore(directory: tempDir)

            _ = try await store.generateKey(name: "Test")

            #expect((try? tempDir.standardized.checkResourceIsReachable()) == true)

            // Cleanup
            try? FileManager.default.removeItem(at: tempDir)
        }

        @Test("Saves and loads keys")
        func savesAndLoadsKeys() async throws {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)

            // Generate keys with first store
            let store1 = APIKeyStore(directory: tempDir)
            let key1 = try await store1.generateKey(name: "Key 1")
            let key2 = try await store1.generateKey(name: "Key 2")

            // Load with new store instance
            let store2 = APIKeyStore(directory: tempDir)
            let loadedKeys = try await store2.listKeys()

            #expect(loadedKeys.count == 2)
            #expect(loadedKeys.contains { $0.key == key1.key })
            #expect(loadedKeys.contains { $0.key == key2.key })

            // Cleanup
            try? FileManager.default.removeItem(at: tempDir)
        }

        @Test("Validates key exists")
        func validatesKeyExists() async throws {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            let store = APIKeyStore(directory: tempDir)

            let key = try await store.generateKey(name: "Test")

            #expect(await store.isValid(key: key.key))
            #expect(await !store.isValid(key: "bm_invalidKeyThatDoesNotExist1234"))

            // Cleanup
            try? FileManager.default.removeItem(at: tempDir)
        }

        @Test("Revokes key")
        func revokesKey() async throws {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            let store = APIKeyStore(directory: tempDir)

            let key = try await store.generateKey(name: "Test")
            #expect(await store.isValid(key: key.key))

            let revoked = try await store.revokeKey(prefix: String(key.key.prefix(10)))
            #expect(revoked)
            #expect(await !store.isValid(key: key.key))

            // Cleanup
            try? FileManager.default.removeItem(at: tempDir)
        }

        @Test("Updates lastUsed on validation")
        func updatesLastUsedOnValidation() async throws {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            let store = APIKeyStore(directory: tempDir)

            let key = try await store.generateKey(name: "Test")
            #expect(key.lastUsed == nil)

            // Bracket the validation, so the assertion is about ordering rather than about
            // how long anything took. A five-second window passes on an idle machine and
            // fails on a loaded one, while proving nothing a bracket does not.
            let beforeValidation = Date()
            _ = await store.isValid(key: key.key)
            let afterValidation = Date()

            let keys = try await store.listKeys()
            let updatedKey = keys.first { $0.key == key.key }
            let lastUsed = try #require(updatedKey?.lastUsed)
            #expect(lastUsed >= beforeValidation && lastUsed <= afterValidation,
                    "lastUsed was not stamped during this validation")

            // Cleanup
            try? FileManager.default.removeItem(at: tempDir)
        }

        @Test("Lists keys without exposing full key")
        func listsKeysSecurely() async throws {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            let store = APIKeyStore(directory: tempDir)

            let key = try await store.generateKey(name: "Test Key")
            let summaries = await store.listKeySummaries()

            #expect(summaries.count == 1)
            #expect(summaries[0].name == "Test Key")
            #expect(summaries[0].prefix.hasPrefix("bm_"))
            #expect(summaries[0].prefix.count < key.key.count) // Prefix is shorter

            // Cleanup
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Integration with Authenticator

    @Suite("Authenticator Integration")
    struct AuthenticatorIntegrationTests {

        @Test("Authenticator validates stored keys")
        func authenticatorValidatesStoredKeys() async throws {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            let store = APIKeyStore(directory: tempDir)

            let key = try await store.generateKey(name: "Test")

            let authenticator = APIKeyAuthenticator(keyStore: store)
            let valid = await authenticator.validate(authHeader: "Bearer \(key.key)")

            #expect(valid)

            // Cleanup
            try? FileManager.default.removeItem(at: tempDir)
        }

        @Test("Authenticator rejects invalid keys")
        func authenticatorRejectsInvalidKeys() async throws {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            let store = APIKeyStore(directory: tempDir)

            let authenticator = APIKeyAuthenticator(keyStore: store)
            let valid = await authenticator.validate(authHeader: "Bearer bm_invalidkey12345678901234567890")

            #expect(!valid)

            // Cleanup
            try? FileManager.default.removeItem(at: tempDir)
        }

        @Test("Authenticator supports both store and environment keys")
        func authenticatorSupportsBothSources() async throws {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            let store = APIKeyStore(directory: tempDir)

            // Create authenticator with both store and env key
            let envKey = "env_test_key_12345"
            let authenticator = APIKeyAuthenticator(keyStore: store, environmentKeys: [envKey])

            // Store key should work
            let storedKey = try await store.generateKey(name: "Stored")
            #expect(await authenticator.validate(authHeader: "Bearer \(storedKey.key)"))

            // Env key should also work
            #expect(await authenticator.validate(authHeader: "Bearer \(envKey)"))

            // Cleanup
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Cross-Process Consistency Tests

    /// A long-running server and a short-lived CLI both open the same key file.
    /// Each `APIKeyStore` instance stands in for one process.
    @Suite("APIKeyStore Cross-Process Consistency")
    struct APIKeyStoreCrossProcessTests {

        @Test("Validation does not clobber keys added by another instance")
        func validationPreservesExternallyAddedKeys() async throws {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)

            // Long-running server loads its key set into memory.
            let server = APIKeyStore(directory: tempDir)
            let serverKey = try await server.generateKey(name: "Server")

            // A separate CLI process adds a key while the server is running.
            let cli = APIKeyStore(directory: tempDir)
            let cliKey = try await cli.generateKey(name: "CLI")

            // The server handles a request, which updates lastUsed and saves.
            #expect(await server.isValid(key: serverKey.key))

            // The CLI's key must survive the server's write.
            let onDisk = try await APIKeyStore(directory: tempDir).listKeys()
            #expect(onDisk.contains { $0.key == cliKey.key })
            #expect(onDisk.count == 2)

            try? FileManager.default.removeItem(at: tempDir)
        }

        @Test("Server accepts a key generated by another instance")
        func serverSeesExternallyAddedKey() async throws {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)

            let server = APIKeyStore(directory: tempDir)
            _ = try await server.generateKey(name: "Server")

            let cli = APIKeyStore(directory: tempDir)
            let cliKey = try await cli.generateKey(name: "CLI")

            // Without re-reading, the server would reject a key it never loaded.
            #expect(await server.isValid(key: cliKey.key))

            try? FileManager.default.removeItem(at: tempDir)
        }

        @Test("Revocation by another instance is not resurrected")
        func revocationIsNotResurrected() async throws {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)

            let server = APIKeyStore(directory: tempDir)
            let doomed = try await server.generateKey(name: "Doomed")
            let keeper = try await server.generateKey(name: "Keeper")

            // CLI revokes one key.
            let cli = APIKeyStore(directory: tempDir)
            #expect(try await cli.revokeKey(prefix: String(doomed.key.prefix(10))))

            // Server write must not bring the revoked key back.
            #expect(await server.isValid(key: keeper.key))

            let onDisk = try await APIKeyStore(directory: tempDir).listKeys()
            #expect(!onDisk.contains { $0.key == doomed.key })
            #expect(onDisk.count == 1)

            // And the revoked key must no longer authenticate.
            #expect(await !server.isValid(key: doomed.key))

            try? FileManager.default.removeItem(at: tempDir)
        }

        @Test("Generation merges with keys added since load")
        func generationMergesExternalAdditions() async throws {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)

            let server = APIKeyStore(directory: tempDir)
            let first = try await server.generateKey(name: "First")

            let cli = APIKeyStore(directory: tempDir)
            let external = try await cli.generateKey(name: "External")

            // Server generates again; all three keys must coexist.
            let third = try await server.generateKey(name: "Third")

            let onDisk = try await APIKeyStore(directory: tempDir).listKeys()
            #expect(onDisk.count == 3)
            for expected in [first.key, external.key, third.key] {
                #expect(onDisk.contains { $0.key == expected })
            }

            try? FileManager.default.removeItem(at: tempDir)
        }
    }
}
