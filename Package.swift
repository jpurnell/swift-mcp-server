// swift-tools-version: 6.2
// legibility:description: A Swift implementation of the Model Context Protocol (MCP) server with HTTP transport.
import PackageDescription

let package = Package(
    name: "SwiftMCPServer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SwiftMCPServer",
            targets: ["SwiftMCPServer"]
        ),
        // A minimal server for the official MCP conformance suite to drive. Not shipped as part
        // of the library; it exists so behavioural conformance can be measured rather than
        // asserted.
        .executable(
            name: "conformance-server",
            targets: ["ConformanceServer"]
        )
    ],
    dependencies: [
        // The OAuth implementation that used to live in Sources/SwiftMCPServer/OAuth.
        // Public, and the development repository itself — the squashed export this once pointed
        // at has been archived and the two consolidated into one. Depending on a public package
        // is what lets anyone else build this one, and therefore check its conformance numbers
        // rather than take them on trust.
        //
        // The bound that used to sit below 0.8.0 is gone, and the reason it existed is handled
        // rather than deferred: 0.8.0 turns on RFC 8707 resource-indicator validation, strict by
        // default, so a token request naming no `resource` is refused. Every client written
        // before that names none. `setupOAuth` therefore constructs its policy with
        // `allowsUnspecified: true` — the documented staging path — which takes the audience
        // binding, introspection, the device grant, PAR and JAR without changing who can
        // connect. Tightening to strict is a separate step, once clients send a resource.
        //
        // Bounded below 0.12.0, and the open `from:` that used to sit here was a mistake worth
        // naming: 0.12.0 reshapes `TokenValidationResult.valid` into a struct, so an open range
        // would have taken a breaking change on the next resolve — at whatever moment someone
        // ran `swift package update`, with a compile error in a file nobody had touched. The
        // upper bound is not caution about 0.x; it is the version this package has actually
        // been verified against.
        .package(url: "https://github.com/jpurnell/swift-oauth.git", "0.12.0"..<"0.13.0"),
        // MCP SDK, upstream. The jpurnell fork this used to point at existed for one
        // 15-line SendOnce concurrency patch on 0.11.0; upstream 0.12.1 builds clean under
        // Swift 6.4 with StrictConcurrency, so the patch — and the "..<0.12.0" cap that
        // protected it — are no longer needed. See ADR-009.
        // The 2026-07-28 SDK work, published as a fork: upstream does not carry this revision.
        // See that repository's NOTICE — it is not the official SDK, and the official one is
        // the right choice for anything that does not need `2026-07-28`.
        //
        // `exact`, not `from`: a fork should move when someone decides it moves, not because a
        // range happened to admit a new tag. The version is date-shaped so it cannot be mistaken
        // for a continuation of upstream's 0.x / 2.x line, and the same commit also carries the
        // annotated tag `fork/2026.07.28-1`, which is the human-readable release marker.
        .package(
            url: "https://github.com/jpurnell/swift-mcp-sdk.git",
            exact: "2026.7.28"
        ),
        // SwiftNIO for cross-platform HTTP server
        .package(
            url: "https://github.com/apple/swift-nio.git",
            from: "2.65.0"
        ),
        .package(
            url: "https://github.com/apple/swift-nio-ssl.git",
            from: "2.26.0"
        ),
        // Cryptography (cross-platform: macOS + Linux)
        .package(
            url: "https://github.com/apple/swift-crypto.git",
            from: "3.0.0"
        ),
        // DocC plugin for documentation generation
        .package(
            url: "https://github.com/apple/swift-docc-plugin",
            from: "1.3.0"
        )
    ],
    targets: [
        // System library for SQLite (available on macOS and Linux)
        .target(
            name: "SwiftMCPServer",
            dependencies: [
                .product(name: "MCP", package: "swift-mcp-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SwiftOAuthProvider", package: "swift-oauth"),
                .product(name: "SwiftOAuthCore", package: "swift-oauth")
            ],
            resources: [.copy("SwiftMCPServer.docc")]
            // DO NOT add `exclude: ["SwiftMCPServer.docc"]` here. That silences the
            // `found 1 file(s) which are unhandled` warning by SILENTLY EMPTYING THE
            // DOCUMENTATION: swift-docc-plugin finds the catalog through
            // `target.sourceFiles` (SourceModuleTarget+doccCatalogPath.swift), so
            // excluding it makes that lookup return nil and docc runs with no catalog.
            // An archive is still produced — symbol pages only — so "an archive exists"
            // and even `quality-gate --check doc-lint` both still pass. Verified
            // 2026-08-18, and still true.
            //
            // The note that used to sit here also said `resources: [.copy(...)]` fails
            // the build because SwiftPM special-cases `.docc`. That was measured once
            // and is no longer true. Re-measured 2026-08-28: the build is clean, the
            // unhandled-file warning is gone, and DocC still reads the catalog — an
            // intentionally broken symbol link injected into SwiftMCPServer.md was
            // caught by doc-lint under this declaration. The claim is kept here rather
            // than deleted because the reasoning it rested on was sound at the time;
            // what changed is SwiftPM, not the argument.
        ),
        // The fixture surface is a library rather than part of the executable so the test
        // suite can stand up the *same* server the official harness drives. Held apart, the two
        // would drift, and a green run under one would say nothing about the other.
        .target(
            name: "ConformanceFixtures",
            dependencies: ["SwiftMCPServer"]
        ),
        .executableTarget(
            name: "ConformanceServer",
            dependencies: ["ConformanceFixtures"]
        ),
        .testTarget(
            name: "SwiftMCPServerTests",
            dependencies: ["SwiftMCPServer", "ConformanceFixtures"]
        )
    ]
)
