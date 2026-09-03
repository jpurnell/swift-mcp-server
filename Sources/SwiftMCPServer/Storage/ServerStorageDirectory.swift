import Foundation
#if canImport(os)
import os
#endif

private let mcpStorageLogger = Logger(subsystem: "com.swiftmcp", category: "ServerStorageDirectory")

/// Where a server keeps the data it owns: its OAuth database and its API key file.
///
/// This package hardcoded `~/.businessmath-mcp` for both, a name belonging to a different
/// project. That was harmless while there was one server and wrong as soon as there were
/// several: every server built on this package shared one token store and one key file, so a key
/// generated for one authenticated against all of them, and tokens issued by different issuers
/// sat in a single table. Resource indicators exist to stop a token being usable at a service it
/// was not issued for, which is difficult to argue while the services share a database.
///
/// The directory is now derived from the server's own name — the one identifier a server already
/// has and already sets distinctly — and can be overridden outright with
/// ``MCPServerBuilder/storageDirectory(_:)``.
///
/// ## Renaming a server moves its data
///
/// The name is the key, so changing it points the server at a fresh directory and leaves the old
/// keys and tokens where they were. That is the cost of deriving rather than requiring, and it is
/// the better trade: a default that is wrong in the same way for every consumer is worse than one
/// that is right until someone renames a server. Set ``MCPServerBuilder/storageDirectory(_:)``
/// explicitly to pin a location across a rename.
public enum ServerStorageDirectory {

    /// The directory every server used before this existed.
    ///
    /// Kept nameable so its presence can be reported — a running server checks for it and says
    /// so, because the alternative is an operator whose keys appear to have vanished.
    public static var legacySharedDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            ".businessmath-mcp")
    }

    /// Used when a server's name contains nothing that survives normalisation.
    ///
    /// An empty slug would resolve to the home directory itself, and a server writing
    /// `api-keys.json` into `~` is a worse outcome than an unhelpfully generic folder name.
    public static let fallbackSlug = "mcp-server"

    /// The directory a server with this name owns.
    ///
    /// - Parameter serverName: The server's configured name.
    /// - Returns: A dotted directory directly beneath the user's home directory.
    public static func directory(forServerName serverName: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "." + slug(for: serverName))
    }

    /// Creates the directory if needed and restricts it to its owner.
    ///
    /// Separating servers stops one reading another's credentials. It says nothing about
    /// everything *else* on the host, and the default answer there is wrong: a directory created
    /// without attributes is `0755`. Existing directories are tightened rather than left as
    /// found, because the interesting case is the one already on disk from before this existed.
    ///
    /// Tightening rather than refusing is a deliberate difference from `VaultMCP`'s
    /// `CredentialDirectory`, which refuses a loose directory outright so that whoever loosened
    /// it is told. That is the stronger policy and the right one for a server that knows what it
    /// is guarding. Here the directory is created by the package itself on a path the package
    /// chose, so there is no third party to inform — and a library that refuses to start over a
    /// permission it set itself last release helps nobody.
    ///
    /// - Parameter directory: The directory to prepare.
    /// - Returns: The standardized directory.
    /// - Throws: If the directory cannot be created or its permissions cannot be set.
    @discardableResult
    public static func prepare(_ directory: URL) throws -> URL {
        let standardized = directory.standardized
        try FileManager.default.createDirectory(
            at: standardized, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: standardized.path)
        return standardized
    }

    /// Restricts a credential file to its owner.
    ///
    /// The OAuth database is created by SQLite rather than by this package, and SQLite makes a
    /// new file `0644` — which is how a shared `oauth.db` came to be world-readable while
    /// holding live access tokens. It is therefore tightened after the fact, the same split the
    /// key store already makes between the file it writes and the lock it opens.
    ///
    /// Absence is not an error: on a first run the database does not exist until something opens
    /// it, and a server that refused to start over a file it had not created yet would be
    /// reporting its own startup order as a fault.
    ///
    /// - Parameter file: The file to restrict.
    public static func restrict(fileAt file: URL) {
        let resolved = file.standardized
        // Asked of the URL rather than of a string path, matching the key store's own probe.
        // silent: a database that is not there yet is exactly what this is checking for
        guard (try? resolved.checkResourceIsReachable()) == true else { return }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: resolved.path)
        } catch {
            // Reported rather than thrown: the database is already open and working at this
            // point, so failing the server here would trade a working server for a permission
            // the operator can still fix. Silence is the one option that is not acceptable.
            mcpStorageLogger.error(
                "Could not restrict \(resolved.path, privacy: .public) to its owner: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The resource identifier a server publishes, as a URL, if the issuer is a usable one.
    ///
    /// `MCP_OAUTH_ISSUER` is read from the environment, so it is attacker-adjacent input in the
    /// same way a server name is: it becomes the audience that tokens are bound to, and RFC 8707
    /// compares client-sent resources against it. A relative string, a `file:` URL, or one with
    /// no host cannot be any of those things, and quietly building a policy around it would
    /// produce a server that refuses every client for a reason nobody could see.
    ///
    /// - Parameter issuer: The configured issuer string.
    /// - Returns: The issuer as an absolute `http`/`https` URL, or `nil` if it is not one.
    /// Built through `URLComponents` so the scheme and host are checked as parsed fields rather
    /// than inferred from a string that happened to parse. Note what this value is *for*: it is
    /// an identifier compared for exact equality under RFC 8707, and nothing ever fetches it, so
    /// the question is whether it can name a service — not whether it is safe to request.
    public static func resourceIdentifier(forIssuer issuer: String) -> URL? {
        guard let components = URLComponents(string: issuer),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host, !host.isEmpty
        else { return nil }
        return components.url
    }

    /// Reduces a server name to a single lowercase hyphenated path component.
    ///
    /// The name is free text supplied by whoever built the server, and it is about to become a
    /// directory name, so this is the boundary where it stops being text and starts being a
    /// path. Everything outside `[a-z0-9]` becomes a separator — which is what makes `../../.ssh`
    /// and `/etc/passwd` inert rather than traversals, since the separators they rely on are not
    /// in the surviving set.
    ///
    /// - Parameter serverName: The server's configured name.
    /// - Returns: A non-empty component safe to append to a directory URL.
    public static func slug(for serverName: String) -> String {
        let permitted = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        let lowered = serverName.lowercased()

        var slug = ""
        var pendingSeparator = false
        for character in lowered {
            if permitted.contains(character) {
                if pendingSeparator, !slug.isEmpty { slug.append("-") }
                pendingSeparator = false
                slug.append(character)
            } else {
                // Runs of punctuation collapse rather than producing repeated hyphens, and a run
                // at either end contributes nothing, so no slug begins or ends with a separator.
                pendingSeparator = true
            }
        }

        return slug.isEmpty ? fallbackSlug : slug
    }
}
