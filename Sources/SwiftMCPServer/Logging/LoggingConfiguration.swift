import Foundation
#if canImport(os)
import os
#endif

/// Configuration for verbose debug logging
///
/// `LoggingConfiguration` provides centralized control over logging behavior,
/// including log levels, channel ID tracking, and response content logging.
///
/// ## Overview
///
/// The configuration can be set via:
/// - CLI flags: `--verbose` or `-v`
/// - Environment variable: `LOG_LEVEL=debug`
///
/// ## Example
///
/// ```swift
/// // Parse from command line arguments
/// let config = LoggingConfiguration.parse(arguments: CommandLine.arguments)
///
/// // Create a logger with the configured subsystem and category
/// let logger = config.makeLogger(category: "my-component")
///
/// // Use verbose convenience factory
/// let verboseConfig = LoggingConfiguration.verbose()
/// ```
///
/// ## Security
///
/// When logging is enabled, sensitive data (API keys, tokens, secrets) is
/// automatically redacted using `sanitizeForLogging(_:)`.
public struct LoggingConfiguration: Sendable {

    // MARK: - Log Level

    /// Log level representation compatible with os.Logger
    ///
    /// os.Logger controls verbosity at the call site via `OSLogType`, not via a
    /// mutable property on the logger. This enum lets callers query the
    /// *configured* verbosity and decide whether to emit a message.
    public enum Level: String, Sendable, Equatable {
        case trace
        case debug
        case info
        case notice
        case warning
        case error
        case critical

        /// The corresponding `OSLogType` used when emitting a message at this level.
        public var osLogType: OSLogType {
            switch self {
            case .trace:   return .debug
            case .debug:   return .debug
            case .info:    return .info
            case .notice:  return .default
            case .warning: return .default
            case .error:   return .error
            case .critical: return .fault
            }
        }
    }

    // MARK: - Properties

    /// The log level for all loggers
    public var logLevel: Level

    /// Whether verbose mode is enabled
    public var isVerbose: Bool

    /// Whether to include channel IDs in log output
    public var includeChannelIds: Bool

    /// Whether to include response content in log output
    public var includeResponseContent: Bool

    /// Maximum length for logged content before truncation
    public var maxContentLength: Int

    // MARK: - Initialization

    /// Creates a new logging configuration with default values
    public init() {
        self.logLevel = .info
        self.isVerbose = false
        self.includeChannelIds = false
        self.includeResponseContent = false
        self.maxContentLength = 200
    }

    // MARK: - Factory Methods

    /// Creates a verbose configuration for debugging
    ///
    /// Enables debug log level and all verbose features:
    /// - Channel ID logging
    /// - Response content logging
    ///
    /// - Returns: A configuration with all verbose features enabled
    public static func verbose() -> LoggingConfiguration {
        var config = LoggingConfiguration()
        config.logLevel = .debug
        config.isVerbose = true
        config.includeChannelIds = true
        config.includeResponseContent = true
        return config
    }

    /// Creates a production configuration with minimal logging
    ///
    /// Uses info log level with no verbose features.
    ///
    /// - Returns: A minimal configuration suitable for production
    public static func production() -> LoggingConfiguration {
        return LoggingConfiguration()
    }

    // MARK: - Parsing

    /// Parses configuration from command line arguments
    ///
    /// Recognizes:
    /// - `--verbose` or `-v` flags to enable verbose mode
    ///
    /// - Parameter arguments: Command line arguments (typically `CommandLine.arguments`)
    /// - Returns: Parsed configuration
    public static func parse(arguments: [String]) -> LoggingConfiguration {
        return parse(arguments: arguments, environment: ProcessInfo.processInfo.environment)
    }

    /// Parses configuration from command line arguments and environment
    ///
    /// CLI flags take precedence over environment variables.
    ///
    /// - Parameters:
    ///   - arguments: Command line arguments
    ///   - environment: Environment variables
    /// - Returns: Parsed configuration
    public static func parse(arguments: [String], environment: [String: String]) -> LoggingConfiguration {
        var config = fromEnvironment(environment)

        // CLI flags override environment
        if arguments.contains("--verbose") || arguments.contains("-v") {
            config.logLevel = .debug
            config.isVerbose = true
            config.includeChannelIds = true
            config.includeResponseContent = true
        }

        return config
    }

    /// Parses configuration from environment variables
    ///
    /// Recognizes:
    /// - `LOG_LEVEL`: trace, debug, info, notice, warning, error, critical
    ///
    /// - Parameter environment: Environment variables dictionary
    /// - Returns: Parsed configuration
    public static func fromEnvironment(_ environment: [String: String]) -> LoggingConfiguration {
        var config = LoggingConfiguration()

        if let levelString = environment["LOG_LEVEL"]?.lowercased() {
            switch levelString {
            case "trace":
                config.logLevel = .trace
            case "debug":
                config.logLevel = .debug
                config.isVerbose = true
                config.includeChannelIds = true
                config.includeResponseContent = true
            case "info":
                config.logLevel = .info
            case "notice":
                config.logLevel = .notice
            case "warning":
                config.logLevel = .warning
            case "error":
                config.logLevel = .error
            case "critical":
                config.logLevel = .critical
            default:
                // Invalid level, keep default
                break
            }
        }

        return config
    }

    // MARK: - Logger Factory

    /// Creates an `os.Logger` with the given category under the SwiftMCP subsystem
    ///
    /// - Parameter category: The logger category (typically the component name)
    /// - Returns: A configured `os.Logger` instance
    public func makeLogger(category: String) -> os.Logger {
        return os.Logger(subsystem: "com.swiftmcp", category: category)
    }

    // MARK: - Content Formatting

    /// Truncates content for logging if it exceeds the maximum length
    ///
    /// - Parameter content: The content to potentially truncate
    /// - Returns: The original content if short enough, or truncated with "..."
    public func truncateForLogging(_ content: String) -> String {
        guard content.count > maxContentLength else {
            return content
        }
        return String(content.prefix(maxContentLength)) + "..."
    }

    /// Sanitizes content for logging by redacting sensitive data
    ///
    /// Redacts:
    /// - API keys (bm_xxx format)
    /// - Bearer tokens
    /// - OAuth access tokens
    /// - Client secrets
    ///
    /// - Parameter content: The content to sanitize
    /// - Returns: Content with sensitive data redacted
    public func sanitizeForLogging(_ content: String) -> String {
        var result = content

        let bmPrefixRedactor = #"bm_[A-Za-z0-9_\-]{20,}"#
        if let regex = try? NSRegularExpression(pattern: bmPrefixRedactor, options: []) { // silent: invalid regex is a programming error, not a runtime condition
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "bm_***[REDACTED]")
        }

        // Redact Bearer tokens in Authorization headers
        let bearerPattern = #"Bearer\s+[A-Za-z0-9_\-\.]+"#
        if let regex = try? NSRegularExpression(pattern: bearerPattern, options: []) { // silent: invalid regex is a programming error, not a runtime condition
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "Bearer [REDACTED]")
        }

        let oauthValueRedactor = #"access_token[=:]\s*[A-Za-z0-9_\-\.]+"#
        if let regex = try? NSRegularExpression(pattern: oauthValueRedactor, options: []) { // silent: invalid regex is a programming error, not a runtime condition
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "access_token=[REDACTED]")
        }

        let clientParamRedactor = #"client_secret[=:]\s*[A-Za-z0-9_\-]+"#
        if let regex = try? NSRegularExpression(pattern: clientParamRedactor, options: []) { // silent: invalid regex is a programming error, not a runtime condition
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "client_secret=[REDACTED]")
        }

        return result
    }

    /// Formats a channel ID as an 8-character hex string
    ///
    /// - Parameter channelId: The channel identifier (typically from ObjectIdentifier.hashValue)
    /// - Returns: Zero-padded 8-character hex string
    public func formatChannelId(_ channelId: Int) -> String {
        let hex = String(channelId & 0xFFFFFFFF, radix: 16, uppercase: false)
        return String(repeating: "0", count: max(0, 8 - hex.count)) + hex
    }
}
