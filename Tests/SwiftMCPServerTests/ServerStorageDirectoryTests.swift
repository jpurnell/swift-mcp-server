import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#endif

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

/// What the directory and the database are readable by.
///
/// Separating servers stops one reading another's credentials. It does nothing about everything
/// else on the host, and the default answer there was wrong: a directory created without
/// attributes is `0755`, and SQLite creates a new database `0644`. On the machine this was found
/// on, `~/.businessmath-mcp/oauth.db` was `-rw-r--r--` while holding live access tokens.
///
/// So the fix is two halves. `ServerStorageDirectoryTests` above covers the first — whose
/// directory it is. This covers the second — who can read it.
@Suite("Server storage permissions")
struct ServerStoragePermissionTests {

    /// Reads the mode with one `stat`, the way `VaultMCP.CredentialDirectory` does.
    ///
    /// `FileManager.attributesOfItem(atPath:)` would mean handing a string path to the file
    /// system and boxing the answer through a dictionary, for a number the kernel already has.
    private func mode(of url: URL) throws -> Int {
        var info = stat()
        let result = url.standardized.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return stat(path, &info)
        }
        try #require(result == 0, "could not stat \(url.lastPathComponent)")
        return Int(info.st_mode) & 0o777
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ssd-\(UUID().uuidString)")
    }

    @Test("A prepared directory is reachable only by its owner")
    func testDirectoryIsOwnerOnly() throws {
        let directory = temporaryURL()
        defer { try? FileManager.default.removeItem(at: directory) } // silent: test cleanup

        let prepared = try ServerStorageDirectory.prepare(directory)
        #expect(try mode(of: prepared) == 0o700, "0755 would let anything on the host list it")
    }

    /// Preparing an existing directory tightens it, because the interesting case is the one
    /// already on disk at 0755 from before this existed.
    @Test("An existing loose directory is tightened rather than left alone")
    func testExistingDirectoryIsTightened() throws {
        let directory = temporaryURL()
        defer { try? FileManager.default.removeItem(at: directory) } // silent: test cleanup

        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        #expect(try mode(of: directory) == 0o755)

        let prepared = try ServerStorageDirectory.prepare(directory)
        #expect(try mode(of: prepared) == 0o700, "an upgrade must fix what it inherits")
    }

    /// The database is created by SQLite, not by this package, so it is tightened after the fact
    /// rather than created correctly — the same split the key store already makes.
    @Test("A database file is restricted to its owner")
    func testDatabaseFileIsRestricted() throws {
        let directory = temporaryURL()
        defer { try? FileManager.default.removeItem(at: directory) } // silent: test cleanup
        let prepared = try ServerStorageDirectory.prepare(directory)

        // Written through the URL and then loosened, standing in for what SQLite leaves behind.
        let database = prepared.appendingPathComponent("oauth.db")
        try Data("not really sqlite".utf8).write(to: database)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: database.standardized.path)
        #expect(try mode(of: database) == 0o644, "this is what SQLite would have left")

        ServerStorageDirectory.restrict(fileAt: database)
        #expect(try mode(of: database) == 0o600, "access tokens are not world-readable")
    }

    /// Restricting something absent is the ordinary case on a first run and must not throw.
    ///
    /// It must also not *create* the thing it was asked to restrict: a zero-byte `oauth.db`
    /// left behind by a permission call would be indistinguishable from an empty database and
    /// would stop SQLite initialising a real one.
    @Test("Restricting a file that does not exist neither throws nor creates it")
    func testRestrictingMissingFileIsSilent() throws {
        let directory = temporaryURL()
        defer { try? FileManager.default.removeItem(at: directory) } // silent: test cleanup
        let prepared = try ServerStorageDirectory.prepare(directory)
        let absent = prepared.appendingPathComponent("absent.db")

        ServerStorageDirectory.restrict(fileAt: absent)

        #expect(
            (try? absent.checkResourceIsReachable()) != true,
            "restricting a missing file must not bring it into existence")
        #expect(try mode(of: prepared) == 0o700, "and must leave the directory as it found it")
    }
}

/// The issuer becomes the audience tokens are bound to, and it comes from the environment.
@Suite("Resource identifier from issuer")
struct ResourceIdentifierTests {

    @Test("An absolute http(s) issuer is usable", arguments: [
        "http://localhost:8080",
        "https://mcp.example.com",
        "https://mcp.example.com/",
    ])
    func testUsableIssuers(issuer: String) throws {
        let identifier = try #require(ServerStorageDirectory.resourceIdentifier(forIssuer: issuer))
        #expect(identifier.absoluteString == issuer)
    }

    /// Anything that cannot be an audience is refused rather than half-accepted. A policy built
    /// around one of these would refuse every client, for a reason not visible in any response.
    @Test("Anything that cannot name a service is refused", arguments: [
        "",
        "   ",
        "not a url",
        "/relative/path",
        "file:///etc/passwd",
        "https://",
        "ftp://example.com",
        "mcp.example.com",
    ])
    func testUnusableIssuers(issuer: String) {
        #expect(
            ServerStorageDirectory.resourceIdentifier(forIssuer: issuer) == nil,
            "\(issuer) cannot be an audience and must not become one")
    }

    /// A trailing slash makes a different identifier, which is the drift that matters here —
    /// RFC 8707 matching is exact, so the value advertised and the value configured must agree
    /// character for character.
    @Test("A trailing slash is a different identifier")
    func testTrailingSlashDiffers() throws {
        let bare = try #require(
            ServerStorageDirectory.resourceIdentifier(forIssuer: "https://mcp.example.com"))
        let slashed = try #require(
            ServerStorageDirectory.resourceIdentifier(forIssuer: "https://mcp.example.com/"))
        #expect(bare != slashed, "exact matching means these are not interchangeable")
    }
}
