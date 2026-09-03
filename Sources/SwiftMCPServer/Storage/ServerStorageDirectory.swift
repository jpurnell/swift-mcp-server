import Foundation

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
