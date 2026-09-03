import Foundation
import Testing

@testable import SwiftMCPServer

/// Where a server keeps the data it owns.
///
/// This package hardcoded `~/.businessmath-mcp` for both the OAuth database and the API key
/// file — a name belonging to a different project, in a package with four independent
/// consumers. Every server built on it therefore shared one token store and one key file, so a
/// key generated for one server authenticated against all of them and a token issued by one sat
/// in the same table as the rest.
///
/// The directory is now derived from the server's own name, which is the one thing a server
/// already has and already sets distinctly.
@Suite("Server storage directory")
struct ServerStorageDirectoryTests {

    // MARK: - Deriving a directory name

    /// The four real consumers, and the point of the exercise: they must not collide.
    @Test("Each server's name yields its own directory", arguments: [
        ("Dev Guidelines MCP Server", "dev-guidelines-mcp-server"),
        ("GeoSEO MCP Server", "geoseo-mcp-server"),
        ("VaultMCP", "vaultmcp"),
        ("Search Operator MCP Server", "search-operator-mcp-server"),
    ])
    func testSlugForRealConsumers(serverName: String, expected: String) {
        #expect(ServerStorageDirectory.slug(for: serverName) == expected)
    }

    @Test("The four real consumers all differ")
    func testRealConsumersDoNotCollide() {
        let names = [
            "Dev Guidelines MCP Server", "GeoSEO MCP Server", "VaultMCP",
            "Search Operator MCP Server",
        ]
        let slugs = Set(names.map { ServerStorageDirectory.slug(for: $0) })
        #expect(slugs.count == names.count, "a collision here is the bug this fixes")
    }

    /// Punctuation and case are normalised rather than carried into a path.
    @Test("Names are normalised to one lowercase hyphenated form", arguments: [
        ("My Server", "my-server"),
        ("MY  SERVER", "my-server"),
        ("My_Server", "my-server"),
        ("My.Server", "my-server"),
        ("  Padded  ", "padded"),
        ("Trailing---", "trailing"),
    ])
    func testNormalisation(serverName: String, expected: String) {
        #expect(ServerStorageDirectory.slug(for: serverName) == expected)
    }

    // MARK: - The name is untrusted input

    /// A server name is free text that becomes a directory name. It must not be able to leave
    /// the directory it is being placed in — a name of `../../.ssh` writing a key file is the
    /// whole reason this is normalised rather than interpolated.
    @Test("A name cannot escape its parent directory", arguments: [
        "../../.ssh",
        "../evil",
        "/etc/passwd",
        "..",
        ".",
        "a/b/c",
    ])
    func testNoTraversal(serverName: String) {
        let slug = ServerStorageDirectory.slug(for: serverName)
        #expect(!slug.contains("/"), "a path separator would place the directory elsewhere")
        #expect(slug != "..", "a bare parent reference escapes")
        #expect(slug != ".", "a bare current reference is not a directory of its own")

        let directory = ServerStorageDirectory.directory(forServerName: serverName)
        let home = FileManager.default.homeDirectoryForCurrentUser.standardized.path
        #expect(
            directory.standardized.path.hasPrefix(home),
            "\(serverName) resolved outside the home directory: \(directory.standardized.path)")
    }

    /// A name with nothing usable in it still has to produce a directory.
    @Test("A name with no usable characters falls back rather than producing an empty path",
          arguments: ["", "   ", "!!!", "///", "..."])
    func testFallbackForEmptySlug(serverName: String) {
        let slug = ServerStorageDirectory.slug(for: serverName)
        #expect(!slug.isEmpty, "an empty slug would write directly into the home directory")
        #expect(slug == ServerStorageDirectory.fallbackSlug)
    }

    // MARK: - The directory itself

    @Test("The directory is a dotted folder under the user's home")
    func testDirectoryShape() {
        let directory = ServerStorageDirectory.directory(forServerName: "GeoSEO MCP Server")
        let home = FileManager.default.homeDirectoryForCurrentUser

        #expect(directory.deletingLastPathComponent().standardized.path == home.standardized.path)
        #expect(directory.lastPathComponent == ".geoseo-mcp-server")
    }

    /// The old shared location, kept only so its presence can be reported.
    @Test("The legacy shared directory is nameable and is not inherited by the real consumers")
    func testLegacyDirectoryIsDistinct() {
        let legacy = ServerStorageDirectory.legacySharedDirectory
        #expect(legacy.lastPathComponent == ".businessmath-mcp")

        for name in [
            "Dev Guidelines MCP Server", "GeoSEO MCP Server", "VaultMCP",
            "Search Operator MCP Server",
        ] {
            #expect(
                ServerStorageDirectory.directory(forServerName: name).standardized
                    != legacy.standardized,
                "\(name) must not inherit the commingled store")
        }
    }

    /// One name does derive the legacy path, and that is left alone deliberately.
    ///
    /// A server named "BusinessMath MCP" slugs to `businessmath-mcp`, which is the directory
    /// everything used to share. Reserving the name to prevent that would give one legitimately
    /// named server a permanently odd directory in order to guard against a *transitional*
    /// condition — leftover data that stops existing the moment an operator clears it. A
    /// permanent quirk is the wrong price for a temporary state, so the coincidence stands and
    /// the startup check is what warns about stale contents.
    @Test("A server named for the legacy directory derives it, and that is intentional")
    func testLegacyNameCoincidenceIsAllowed() {
        #expect(
            ServerStorageDirectory.directory(forServerName: "BusinessMath MCP").standardized
                == ServerStorageDirectory.legacySharedDirectory.standardized,
            "no reserved-name special case; the warning covers the stale-data risk")
    }
}
