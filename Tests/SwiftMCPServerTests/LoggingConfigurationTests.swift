import Testing
import Foundation
import os
@testable import SwiftMCPServer

/// Test suite for verbose debug logging configuration
///
/// Following TDD - these tests are written FIRST before implementation.
/// Tests verify:
/// - CLI flag parsing (--verbose, -v)
/// - Environment variable support (LOG_LEVEL)
/// - Default behavior (verbose disabled)
/// - Security (secrets not logged)
@Suite("Logging Configuration Tests")
struct LoggingConfigurationTests {

    // MARK: - Default Behavior Tests

    @Test("Default log level is info")
    func testDefaultLogLevelIsInfo() async throws {
        let config = LoggingConfiguration()
        #expect(config.logLevel == .info)
    }

    @Test("Verbose mode disabled by default")
    func testVerboseModeDisabledByDefault() async throws {
        let config = LoggingConfiguration()
        #expect(config.isVerbose == false)
    }

    @Test("Channel ID logging disabled by default")
    func testChannelIdLoggingDisabledByDefault() async throws {
        let config = LoggingConfiguration()
        #expect(config.includeChannelIds == false)
    }

    @Test("Response content logging disabled by default")
    func testResponseContentLoggingDisabledByDefault() async throws {
        let config = LoggingConfiguration()
        #expect(config.includeResponseContent == false)
    }

    // MARK: - Verbose Flag Tests

    @Test("--verbose flag enables debug logging")
    func testVerboseFlagEnablesDebugLogging() async throws {
        let config = LoggingConfiguration.parse(arguments: ["server", "--http", "8080", "--verbose"])
        #expect(config.logLevel == .debug)
        #expect(config.isVerbose == true)
    }

    @Test("-v short flag enables debug logging")
    func testShortVerboseFlagEnablesDebugLogging() async throws {
        let config = LoggingConfiguration.parse(arguments: ["server", "--http", "8080", "-v"])
        #expect(config.logLevel == .debug)
        #expect(config.isVerbose == true)
    }

    @Test("Verbose flag enables channel ID logging")
    func testVerboseFlagEnablesChannelIdLogging() async throws {
        let config = LoggingConfiguration.parse(arguments: ["server", "--verbose"])
        #expect(config.includeChannelIds == true)
    }

    @Test("Verbose flag enables response content logging")
    func testVerboseFlagEnablesResponseContentLogging() async throws {
        let config = LoggingConfiguration.parse(arguments: ["server", "--verbose"])
        #expect(config.includeResponseContent == true)
    }

    @Test("Verbose flag position independent")
    func testVerboseFlagPositionIndependent() async throws {
        // Flag at start
        let config1 = LoggingConfiguration.parse(arguments: ["--verbose", "--http", "8080"])
        #expect(config1.isVerbose == true)

        // Flag at end
        let config2 = LoggingConfiguration.parse(arguments: ["--http", "8080", "--verbose"])
        #expect(config2.isVerbose == true)

        // Flag in middle
        let config3 = LoggingConfiguration.parse(arguments: ["--http", "--verbose", "8080"])
        #expect(config3.isVerbose == true)
    }

    // MARK: - Environment Variable Tests

    @Test("LOG_LEVEL=debug enables verbose mode")
    func testLogLevelEnvVarDebug() async throws {
        let config = LoggingConfiguration.fromEnvironment(["LOG_LEVEL": "debug"])
        #expect(config.logLevel == .debug)
        #expect(config.isVerbose == true)
    }

    @Test("LOG_LEVEL=trace enables trace level")
    func testLogLevelEnvVarTrace() async throws {
        let config = LoggingConfiguration.fromEnvironment(["LOG_LEVEL": "trace"])
        #expect(config.logLevel == .trace)
    }

    @Test("LOG_LEVEL=warning sets warning level")
    func testLogLevelEnvVarWarning() async throws {
        let config = LoggingConfiguration.fromEnvironment(["LOG_LEVEL": "warning"])
        #expect(config.logLevel == .warning)
    }

    @Test("LOG_LEVEL=error sets error level")
    func testLogLevelEnvVarError() async throws {
        let config = LoggingConfiguration.fromEnvironment(["LOG_LEVEL": "error"])
        #expect(config.logLevel == .error)
    }

    @Test("LOG_LEVEL case insensitive")
    func testLogLevelEnvVarCaseInsensitive() async throws {
        let config1 = LoggingConfiguration.fromEnvironment(["LOG_LEVEL": "DEBUG"])
        #expect(config1.logLevel == .debug)

        let config2 = LoggingConfiguration.fromEnvironment(["LOG_LEVEL": "Debug"])
        #expect(config2.logLevel == .debug)
    }

    @Test("Invalid LOG_LEVEL defaults to info")
    func testInvalidLogLevelDefaultsToInfo() async throws {
        let config = LoggingConfiguration.fromEnvironment(["LOG_LEVEL": "invalid"])
        #expect(config.logLevel == .info)
    }

    @Test("CLI flag overrides environment variable")
    func testCLIFlagOverridesEnvVar() async throws {
        // Environment says warning, CLI says verbose
        let config = LoggingConfiguration.parse(
            arguments: ["server", "--verbose"],
            environment: ["LOG_LEVEL": "warning"]
        )
        #expect(config.logLevel == .debug)
        #expect(config.isVerbose == true)
    }

    // MARK: - Logger Factory Tests

    @Test("Creates logger with category")
    func testCreatesLoggerWithCategory() async throws {
        let config = LoggingConfiguration()
        let logger = config.makeLogger(category: "test")
        #expect(type(of: logger) == os.Logger.self)
    }

    @Test("Creates logger with custom category")
    func testCreatesLoggerWithCustomCategory() async throws {
        let config = LoggingConfiguration()
        let logger = config.makeLogger(category: "my-custom-category")
        #expect(type(of: logger) == os.Logger.self)
    }

    // MARK: - Content Truncation Tests

    @Test("Response content truncated to 200 chars in verbose mode")
    func testResponseContentTruncation() async throws {
        let config = LoggingConfiguration.verbose()
        let longContent = String(repeating: "a", count: 500)

        let truncated = config.truncateForLogging(longContent)

        #expect(truncated.count <= 203) // 200 + "..."
        #expect(truncated.hasSuffix("..."))
    }

    @Test("Short response content not truncated")
    func testShortContentNotTruncated() async throws {
        let config = LoggingConfiguration.verbose()
        let shortContent = "Hello, world!"

        let truncated = config.truncateForLogging(shortContent)

        #expect(truncated == shortContent)
        #expect(!truncated.hasSuffix("..."))
    }

    // MARK: - Security Tests

    @Test("API keys are redacted in logs")
    func testApiKeysRedacted() async throws {
        let config = LoggingConfiguration.verbose()
        let content = "Authorization: Bearer bm_ZSOKlBNtFOx_1Utphiinm-Hk15uitr0t"

        let sanitized = config.sanitizeForLogging(content)

        #expect(!sanitized.contains("bm_ZSOKlBNtFOx_1Utphiinm-Hk15uitr0t"))
        #expect(sanitized.contains("[REDACTED]") || sanitized.contains("bm_***"))
    }

    @Test("OAuth tokens are redacted in logs")
    func testOAuthTokensRedacted() async throws {
        let config = LoggingConfiguration.verbose()
        let content = "access_token=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"

        let sanitized = config.sanitizeForLogging(content)

        #expect(!sanitized.contains("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"))
        #expect(sanitized.contains("[REDACTED]"))
    }

    @Test("Client secrets are redacted in logs")
    func testClientSecretsRedacted() async throws {
        let config = LoggingConfiguration.verbose()
        let content = "client_secret=super_secret_value_12345"

        let sanitized = config.sanitizeForLogging(content)

        #expect(!sanitized.contains("super_secret_value_12345"))
        #expect(sanitized.contains("[REDACTED]"))
    }

    @Test("Regular content not redacted")
    func testRegularContentNotRedacted() async throws {
        let config = LoggingConfiguration.verbose()
        let content = "method: tools/list, id: 123"

        let sanitized = config.sanitizeForLogging(content)

        #expect(sanitized == content)
    }

    // MARK: - Channel ID Formatting Tests

    @Test("Channel ID formatted as hex")
    func testChannelIdFormattedAsHex() async throws {
        let config = LoggingConfiguration.verbose()
        let channelId = 305419896 // 0x12345678

        let formatted = config.formatChannelId(channelId)

        #expect(formatted == "12345678")
    }

    @Test("Channel ID padded to 8 chars")
    func testChannelIdPaddedTo8Chars() async throws {
        let config = LoggingConfiguration.verbose()
        let channelId = 255 // 0x000000ff

        let formatted = config.formatChannelId(channelId)

        #expect(formatted.count == 8)
        #expect(formatted == "000000ff")
    }

    // MARK: - Convenience Factory Tests

    @Test("verbose() factory creates verbose config")
    func testVerboseFactoryCreatesVerboseConfig() async throws {
        let config = LoggingConfiguration.verbose()

        #expect(config.isVerbose == true)
        #expect(config.logLevel == .debug)
        #expect(config.includeChannelIds == true)
        #expect(config.includeResponseContent == true)
    }

    @Test("production() factory creates minimal config")
    func testProductionFactoryCreatesMinimalConfig() async throws {
        let config = LoggingConfiguration.production()

        #expect(config.isVerbose == false)
        #expect(config.logLevel == .info)
        #expect(config.includeChannelIds == false)
        #expect(config.includeResponseContent == false)
    }
}
