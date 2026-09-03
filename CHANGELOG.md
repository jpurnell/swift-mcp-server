# Changelog

## [Unreleased]

## [2.0.2] - 2026-09-03

### Changed
- **`swift-oauth` is bounded below `0.8.0`** rather than taken openly. That release turns on
  RFC 8707 resource-indicator validation in `SwiftOAuthProvider`, strict by default: a token
  request naming no `resource` is refused with `invalid_target`. This package sets no resource
  indicator anywhere, so an open range would have delivered that on the next routine resolve —
  a server rejecting requests it accepts today, with no local change to point at.

  The bound is not a judgement on the change, which is the right default for an authorization
  server. It makes adopting it a decision, so the migration lands in the same commit as the
  bump.

- **The manifest no longer describes `swift-oauth` as a squashed export of a private
  repository.** The two were consolidated: the export is archived and this URL is now the
  development repository itself, public with full history.

## [2.0.1] - 2026-09-02

### Fixed
- **`Package.resolved` pinned a commit that no longer exists.** The SwiftOAuth pair was
  consolidated into one repository and tag `0.7.1` moved from the squashed export commit to the
  merged full-history one, so 2.0.0 resolves `swift-oauth` to a revision the remote answers
  `not our ref` for. Re-pinned; nothing else changed.

  Two things made this hard to catch, both worth knowing. A clone **on a machine that had
  already resolved the old commit still builds**, because SwiftPM reuses its cached copy of the
  repository — verifying a published package from a same-machine clone therefore proves less
  than it appears to, and `swift package --cache-path <fresh> resolve` is the honest test.
  Second, once the cache is cold the error is not a missing commit but a *fingerprint mismatch*:
  SwiftPM records tag-to-SHA on first use and refuses a tag that later points somewhere else.
  That is a deliberate defence against tag rewriting, and clearing
  `~/.swiftpm/security/fingerprints` is the only way past it.

## [2.0.0] - 2026-09-02

**MCP `2026-07-28`.** Conformance verified against
`@modelcontextprotocol/conformance@0.2.0-alpha.11`: **195/195** on `--requirements 2026-07-28`
and **227/227** on `--suite all`, reproducible from the `conformance-server` target in this
package.

**Major, and the reason is the dependency, not the API.** The server itself is additive — a
pre-2026 client is served exactly as before, and `DualRevisionServingTests` is the proof. What
breaks is underneath: this package now resolves the MCP SDK as
[`jpurnell/swift-mcp-sdk`](https://github.com/jpurnell/swift-mcp-sdk) at `2026.7.28`, a **fork**
carrying revision support upstream does not have, and SwiftOAuth as
[`jpurnell/swift-oauth`](https://github.com/jpurnell/swift-oauth) at `0.7.1`.

**Consumers must migrate both, not just bump this version.** SwiftPM derives package identity
from the URL's last path component, so `swift-sdk` and `swift-mcp-sdk` are two identities for
one repository. A consumer that keeps a direct dependency on `jpurnell/swift-sdk` or
`modelcontextprotocol/swift-sdk` while depending on this package will fail to build with
*"multiple similar targets 'MCP' … appear in package 'swift-sdk' and 'swift-mcp-sdk'"* — the
same trap applies to `SwiftOAuth` versus `swift-oauth`. The fix is to replace the direct
dependency and update its `package:` product references; it is not a version-range problem and
no range will resolve it.

Upstream does not carry `2026-07-28` and this is not the official SDK; the fork's NOTICE and
README say so, and point anyone who does not need this revision back to upstream.

**Published.** This release is also exported, with clean history, to
[`jpurnell/swift-mcp-server`](https://github.com/jpurnell/swift-mcp-server) so the conformance
figures can be checked by someone who does not have this repository.

### Added
- **Serves MCP `2026-07-28` alongside earlier revisions.** `server/discover` and
  `subscriptions/listen` registered by the builder; list results carry `resultType`, `ttlMs` and
  `cacheScope`; `tools/list` returns a deterministic order so client and prompt caches can hit.

  Additive by design: `initialize` and `Mcp-Session-Id` remain for pre-2026 clients, and both
  paths are served from one implementation.

- **Request metadata validation.** `Mcp-Method`, `Mcp-Name` and `MCP-Protocol-Version` are each
  checked against the request body, rejecting a disagreement with `-32020` and `400`. `Mcp-Name`
  values wrapped in the `=?base64?…?=` sentinel are decoded before comparison — without that
  every non-ASCII tool name would look like a mismatch.

  Validated **only when present**, so a client on an earlier revision that sends none is not
  refused. That conditionality is what lets one server answer both.

- **Required `_meta` enforcement.** A request declaring `2026-07-28` must carry
  `protocolVersion` and `clientCapabilities`; one that does not is answered `-32602` with `400`
  rather than having its capabilities guessed.

- **`DualRevisionServingTests`** — the acceptance proof, over real HTTP against a real server.

- **`AllowedHosts` — `Host` and `Origin` validation.** A page the user is merely visiting can
  point its own domain at `127.0.0.1` and POST to a server that only expected local callers; the
  socket sees a local connection because it is one, and the headers are the only place the
  difference shows. `.loopback` answers only `localhost`, `127.0.0.1` and `[::1]`; `.named`
  extends that; `.any` performs no validation.

  **The default is `.any`, which is not the safe shape and is the deliberate choice.** This
  package serves deployed, publicly-named servers — VaultMCP among them — and defaulting to
  `.loopback` would take them off the air on upgrade with a `403` naming nothing the operator
  changed. **A loopback server without TLS or an API key should pass `.loopback`**; that is the
  configuration [GHSA-w48q-cv73-mx4w][ghsa-rebind] is about.

- **`StatelessConformanceTests`** — the official suite's `server-stateless` and
  `http-header-validation` rules, pinned as tests that fail in seconds rather than only under a
  Node harness.

- **`ConformanceFixtures` — the fixture surface the official suite drives**, as a library rather
  than part of the executable so the package's own tests stand up the *same* server the harness
  does. Two definitions of "the conformance target" would drift, and a green `swift test` and a
  green harness run would then be answering different questions.

  The suite does not only check protocol shapes: most scenarios call a **named** fixture and
  assert on what comes back. A target missing one reports "1 passed, 1 failed" for that whole
  scenario, which reads as a protocol failure and is not one.

- **`ConformanceFixtureTests`** — the suite's own assertions, made over plain HTTP in this
  package's test suite. The harness is a Node tool pinned to an alpha version and pointed at a
  running process, which makes it something you remember to run; these run every time.

- **`MCPTaskStore` — work that outlives the request that asked for it** (SEP-2663). The
  extension exists because a stateless protocol has no channel for a server to call back on: a
  client gets a `taskId` and polls. Everything hard about that is in the store — a task must be
  readable the instant its id is returned, cancellation must settle to `cancelled` rather than
  to whatever the work would have produced, and a tool that ran and said no must stay
  distinguishable from one that could not run at all.

  **In-memory, and that is a scope rather than an oversight.** A task created on one instance is
  invisible to another, so a load-balanced deployment needs a shared store; the type is an actor
  with a small surface, which is what makes that replaceable.

- **The tasks surface on the conformance target**, including the two gates: a client that never
  negotiated the extension gets `-32021` on `tasks/*` and a synchronous run of a task-supporting
  tool, except where the tool cannot run any other way — SEP-2663's "required" declaration —
  which is refused rather than quietly answered differently.

- **`CustomHeaderParameters` — SEP-2243's `x-mcp-header` arguments.** A tool may declare that one
  of its arguments also travels in a named header, so an intermediary can route on it without
  parsing the body — which only works if the two always say the same thing. `Mcp-Name`'s rule,
  generalised to arguments a tool nominates for itself. Pass the tools to `HTTPServerTransport`
  and it enforces them.

  Base64 well-formedness is checked here rather than left to Foundation, which decodes
  `ZXUtd2VzdC0x=` as though the padding were right. The specification's test table requires that
  to be refused, and accepting it means acting on a value the sender did not send.

- **`HTTPServerTransport` conforms to `HTTPContextProviding`**, so a handler can reach the HTTP
  request that triggered it through `Server.currentHandlerContext`. Held only while the request
  is in flight. `withMethodHandler` takes decoded parameters and nothing else, which is right
  for almost everything — but some rules are *about* the transport, and there was no way to
  implement those from a handler that could not see it.

- **The SEP-2322 fixtures**, including a signed `requestState`. The specification calls the token
  opaque; signing is what turns "the client should not modify this" into something the server can
  check, since a server that trusts whatever comes back is letting the client rewrite the
  server's own memory of the exchange.

- **`subscriptions/listen` streams are filtered by what they subscribed to.** A subscription
  names what it wants, and the acknowledgement tells the client what it will get. Delivering
  more than that is not generosity — the client filtered because it is not prepared to handle
  the rest, and an unfiltered stream makes the acknowledgement a lie.

  Which kinds a server can produce is now something it declares
  (`subscribableNotifications:`), rather than a guess the transport makes. It was hardcoded to
  `toolsListChanged`, which was right for a server with only tools and wrong for any other.

- **Server-initiated requests over the response stream — the pre-`2026-07-28` channel.** A tool
  can call `Server.requestSampling` or `requestElicitation` and wait: the POST's response becomes
  an SSE stream, the question goes out as an event on it, the client answers with a separate
  POST (acknowledged `202`), and the original stream then carries the result and closes.

  **Legacy by construction.** `2026-07-28` removed this entirely — a stateless server has
  nowhere to call back to, which is exactly why SEP-2322's `InputRequiredResult` exists, and
  that is implemented too. Kept because this package serves earlier revisions, where a tool
  asking the client something is the only mechanism there is. New work should use SEP-2322.

  A request only starts streaming when it has to: which request an outgoing message belongs to
  comes from the SDK's per-dispatch task-local, since the outgoing bytes carry a fresh id of
  their own and say nothing about what provoked them.

- **Progress and log notifications go to the stream of the request that produced them.** They
  were routed like any other outgoing message: no pending request matched, so they fell through
  to a broadcast that reached whatever standalone stream happened to be open, and nothing at all
  when none was. A progress notification means nothing except beside the call producing it.

  Scoped deliberately: the list-changed notifications are *not* request-scoped — they are facts
  about the server, they reach subscribers through `subscriptions/listen`, and attributing one
  to whichever request happened to be open when it fired would be wrong.

### Fixed
- **A mismatched version header reports `-32020`, not `-32022`.** The unsupported-version check
  ran first, so a header disagreeing with the body was reported as a version to renegotiate when
  the actual fault was that the client's router and its body were built from different values —
  which renegotiating does not fix. The mismatch check now runs first.

- **`-32022` echoes the version that was requested** alongside the supported set, so a client
  with several attempts in flight can tell which one was refused.

- **`Mcp-Method` and `Mcp-Name` are required on `2026-07-28`, not merely checked when present.**
  SEP-2243 makes them mandatory: an intermediary that cannot see `Mcp-Method` cannot route, and
  a request it could not route must not then be executed as though it had been. Still absent and
  still fine for a client on an earlier revision.

- **A custom parameter header is `Mcp-Param-{Name}`, where `{Name}` is the annotation's value.**
  Read as the whole field name, the server looked for a header no client sends — so it never
  found one, and every check expecting a rejection passed for the wrong reason while the two
  expecting acceptance failed.

- **`Mcp-Name` mirrors `params.taskId` on the tasks methods**, which is SEP-2663 extending
  SEP-2243's routing headers. Same rule as for a tool name: an intermediary routes on the
  header, so the header and the body must name the same thing.

- **The `Mcp-Name` requirement is scoped to the methods SEP-2243 names**, rather than to any
  request with a name-shaped field. Requiring it more widely meant a method the server does not
  implement was refused for a missing header instead of answered `-32601` — telling the client
  its routing was wrong when the truth was that the method does not exist.

- **Whitespace around a header value is no longer part of the value.** RFC 9110 §5.5 puts
  optional whitespace outside the field value and requires a recipient to exclude it; comparing
  the raw bytes refused requests any intermediary is entitled to send.

- **A method only `2026-07-28` defines requires `_meta` even when the request declares no
  version.** No earlier client knows `server/discover` or `subscriptions/listen` to call them, so
  there is no earlier client to protect — and a request without `_meta` has told the server
  nothing it can act on.

- **`-32020`, `-32021` and `-32022` from a handler are delivered with `400`.** The codes SEP-2575
  reserved each say the request was malformed at the transport boundary, and must not carry a
  different status depending on which layer noticed.

- **Responses identify the server** in `_meta["io.modelcontextprotocol/serverInfo"]` (spec PR
  #3002). A stateless client never sees an `initialize` result, so a response is the only place
  it can learn which instance answered.

[ghsa-rebind]: https://github.com/modelcontextprotocol/typescript-sdk/security/advisories/GHSA-w48q-cv73-mx4w

### Changed
- **An unknown method answers `404`** alongside its `-32601`. The code was already right; the
  status was `200`. The pairing is what a client's fallback probe reads: a bare `404` means "not
  an MCP endpoint", a `404` carrying a JSON-RPC error means "MCP endpoint, no such method".
- **`GET` and `DELETE` on `/mcp` are refused with `405` for a client declaring `2026-07-28`**,
  which removed both mechanisms — but still served for earlier clients, which legitimately use
  them.
- **SSE responses send `X-Accel-Buffering: no`**, so a reverse proxy does not batch events into
  what looks like a slow server.

### Removed
- **The synthetic "already initialized" response**, on evidence rather than reasoning: the test
  asserting a repeated `initialize` succeeds and answers with the same negotiated version both
  times was written first, and passes with the block deleted. It had hardcoded `2025-03-26` and
  a frozen capability block — the version inconsistency ADR-008 was originally filed about.

### Documentation
- **ADR-008 `accepted`**, recording that its own costing of this work as "a transport-layer
  rewrite, breaking for every consumer at once" was **wrong**. The change is additive.
- **ADR-011 `accepted`** — the tasks extension is deliberately not adopted. It is an extension,
  negotiated through the `extensions` capability field which is implemented, so not advertising
  it is conformant. Recording it stops the remaining-work list overstating what is outstanding.
- The migration plan separates what was built from what remains, and names the one genuinely
  open item: whether the SSE heartbeat emits a keep-alive comment, which is **unverified**
  rather than done.

## [1.4.0] - 2026-09-01

### Added
- **`MCPHTTPRoute` — read-only HTTP endpoints registered by the consumer.** Routing here is a
  `switch` over literal paths, so a consumer needing one more endpoint had to change this
  package and rebuild its server. Two hit that. VaultMCP declined a `POST /reindex`, and then
  needed a calendar subscription feed — which a calendar client can only fetch over plain HTTP,
  and which cannot send an `Authorization` header at all.

  **This does not reopen the `/reindex` objection.** That rejection was recorded as: a rebuild
  "takes ~18s and would be remotely triggerable on a WAN-forwarded port" — a denial-of-service
  concern about an expensive *mutation*. `MCPHTTPRoute` is **`GET`-only by construction**; there
  is no method to choose, so nothing here lets a consumer reintroduce one.

  Two invariants keep the protocol surface intact, both tested rather than asserted:

  - **Reserved paths always win.** `/mcp`, `/health`, `/mcp/sse` and every OAuth endpoint are
    unclaimable, along with anything beneath them. Registering `/` is legal and still cannot
    capture them — while `/healthy` and `/mcpx` remain routable, because the guarantee is about
    path segments and not string prefixes.
  - **Authentication is the default.** `requiresAuthentication` must be set to `false`
    deliberately. A route that opts out carries its own credential in the path, and the consumer
    is responsible for comparing it in constant time.

  Prefix matching stops at a segment boundary, so `/calendar` claims `/calendar/x.ics` but never
  `/calendarium` — which is how a route otherwise swallows a sibling endpoint added later.

  Register with `MCPServerBuilder.httpRoute(_:)` or `.httpRoutes(_:)`.

## [1.3.0] - 2026-09-01

### Changed
- **Depends on the upstream MCP Swift SDK; the fork is retired.** `Package.swift` pointed at
  `jpurnell/swift-sdk` capped `"0.11.0"..<"0.12.0"`, commented "fork with Swift 6.3+/6.4
  concurrency fixes". The fork's `main` carries no custom commits; its `0.11.1` tag is upstream
  `0.11.0` plus **one commit, 15 lines** — a `SendOnce` guard in `NetworkTransport` and an
  async-algorithms floor.

  Upstream had already shipped 0.12.0 and 0.12.1 *before* that commit, so the patch sat on a base
  two releases stale while the cap withheld four upstream commits including auth improvements.
  Upstream 0.12.1 builds clean under Swift 6.4 at tools-version 6.1 with `StrictConcurrency`
  enabled — measured, not assumed — so the problem the patch solved is fixed upstream.

  Now `modelcontextprotocol/swift-sdk` `from: "0.12.1"`. See ADR-009. The `SendOnce` patch is
  preserved in the fork's `0.11.1` tag if a Swift 6.3/6.4 concurrency failure ever reappears in
  `NetworkTransport`.

- **Seven call sites migrated off `.text(_:metadata:)`** to the canonical
  `.text(text:annotations:_meta:)`, in `ValueExtensions`, `ToolDefinition` and `MCPCompat`, plus
  the pattern match in `MCPTestHelpers` which now binds the three-payload case. The replacement
  takes `_meta` — the same carriage mechanism MCP 2026-07-28 uses — so this moves toward the
  surface the protocol work will build on.


## [1.2.3] - 2026-09-01

### Documentation
- **The architecture decision log is populated — and it already existed.** `master_plan.md` had
  recorded since 2026-08-25 that "no ADR log exists here, unlike VaultMCP". Half of that was
  wrong: the log has lived at `00_CORE_RULES/06_ARCHITECTURE_DECISIONS.md` since 2026-03-19, and
  it is the file VaultMCP's own log names as the format it copies. It held one entry. The empty
  `project/decisions/` directory is what made it look absent; that directory now holds a README
  pointing at the real log so the mistake is not repeated.

  Six entries backfill decisions that were living only in `HANDOFF.md` and the fix summaries:
  auth shipping inside the package, the DocC `resources: [.copy(...)]` rule and the two
  `exclude:` reverts, hardcoded route dispatch and the two consumer refusals behind it, the SSE
  `Character`-scan frame boundary, `port(_:)` as a fallback, and the dependency-floor policy.

- **ADR-008 records the MCP revision gap, and it is `proposed` rather than accepted.** The
  package targets a revision two releases behind the specification, and inconsistently — see
  1.2.2 for the internal disagreement. What 1.2.2 did not know: **MCP `2026-07-28` shipped on
  2026-07-28**, the largest revision since the protocol launched, and it retires the mechanisms
  this package is built on — the `initialize` handshake, protocol-level sessions and
  `Mcp-Session-Id`, SSE resumability, and the GET endpoint are all removed; `server/discover`,
  `Mcp-Method`/`Mcp-Name` headers, `ttlMs`/`cacheScope` and `resultType` are all newly required;
  OAuth Dynamic Client Registration, which `registerClient` implements, is deprecated.

  It is not reachable by bumping a dependency: the vendored SDK is a fork
  (`jpurnell/swift-sdk` 0.11.1) capped at 2025-11-25, and the official Swift SDK has not shipped
  2026-07-28 support either. ADR-008 records three options — pin to 2025-03-26, reconcile at
  2025-11-25, or target 2026-07-28 — and picks none. **No behaviour changed in this release.**


## [1.2.2] - 2026-09-01

### Changed
- **SwiftOAuth resolved to 0.5.0** (from 0.4.0). Additive upstream: one new `GrantType` case
  (`clientCredentials`) plus DocC catalogues and doc-comment fixes — no signature changed and
  nothing was removed. Adding an enum case is source-breaking for an exhaustive `switch`, but
  this package never references `GrantType`, so the one breaking vector does not apply.

  **`Package.swift` was not edited.** SwiftPM's `from:` is up-to-next-major, so `from: "0.4.0"`
  already admitted 0.5.0; only the resolved pin moved. The floor stays at 0.4.0 because that is
  the true minimum — raising it would assert a dependency on `clientCredentials`, which this
  package does not use.

### Documentation
- **The MCP specification revision is recorded in `master_plan.md`, and it is two revisions.**
  The `[NEEDS INPUT]` marker asked which revision this targets; the code answers, twice and
  inconsistently:

  - A normal `initialize` is yielded to the MCP SDK, which negotiates across `2024-11-05`,
    `2025-03-26`, `2025-06-18` and `2025-11-25`, defaulting to **2025-11-25**.
  - The synthetic "already initialized" response in `HTTPServerTransport.send()` returns a
    hardcoded **2025-03-26** with a hardcoded capability block.

  A client that negotiates 2025-11-25 and then initializes again is told 2025-03-26, and the
  frozen capability block can drift from what the server actually registered.
  `Version.negotiate(clientRequestedVersion:)` exists in the SDK and is called nowhere here.
  **No behaviour was changed** — this release records the finding and reframes the open
  question as a decision (pin deliberately, or adopt negotiation) rather than an investigation.


## [1.2.1] - 2026-09-01

### Fixed
- **Four `HTTPTransportTests` asserted nothing about the type they were named for.** *"Register
  and route simple request"*, *"Handle string request IDs"* and *"Handle null request IDs"*
  built a JSON string, decoded it with `JSONSerialization`, and asserted on the result — they
  never constructed an `HTTPResponseManager` and **would have passed with the type deleted.**
  *"Cleanup expired requests"* did construct one, then asserted `#expect(true)`.

  All four now drive the actor through the `HTTPConnection` seam: register a request, route a
  response, and assert the pending count and the bytes reaching the connection. Two mutation
  checks confirmed the replacements can fail — making `routeResponse` return `true` for an
  unmatched id is caught by two tests, and suppressing the send entirely is caught by a third.
  The originals detected neither.

  Recorded 2026-08-25 as "two tests"; it was four.

### Added
- `HTTPResponseManager - Unmatched and unparsable responses do not route` — a response matching
  nothing pending, and a non-JSON body, must both be refused rather than silently dropped.
- `HTTPResponseManager - A numeric id does not match a string id` — `.number(1)` and
  `.string("1")` are distinct keys, so one must not consume the other's pending request.
- `Pending request count` now also covers that re-registering an id replaces rather than adds.

### Documentation
- `HTTPResponseManager.init(requestTimeout:)` documented its default as `30s`; the value is
  `300.0`. Corrected to match the code.
- The routing tests now record that **`routeResponse` returns before the response is written.**
  The send is dispatched into a detached `Task`, so `true` means "matched and handed off", not
  "delivered", and a send failure is logged without reaching the caller.


## [1.2.0] - 2026-09-01

### Fixed
- **The SSE test client could not parse a CRLF stream at all.** `MCPSSEDelegate` located
  frame boundaries with `range(of: "\n\n")`. Swift represents `"\r\n"` as a single
  `Character`, so that search matches none of the CRLF forms — frames were never detected,
  nothing was ever emitted, and the buffer grew without bound. The 129-test suite passed
  with this present because every test drove the LF path.

  Boundaries are now found by scanning for two consecutive newline `Character`s, which
  recognises every terminator the SSE grammar allows: CRLF, bare LF, and bare CR. The
  obvious alternative — normalising `\r\n` to `\n` as each chunk arrives — was rejected
  because it is wrong for a stream: a CR ending one chunk and an LF opening the next would
  normalise into two LFs and fabricate a frame boundary that was never sent. Swift rejoins
  such a pair into one `Character` across the `+=`, so the `Character` scan is immune, and
  `SSEFrameParsingTests` pins that case.

- **Three redundant `await`s on a synchronous call.** `MCPSSEDelegate.getNextEvent()` is not
  `async`, so `await` on it introduced no suspension point and the compiler warned three
  times. The surrounding poll loops already sleep 50ms per iteration, so behaviour is
  unchanged; only the warnings go.

### Changed
- **`--http` no longer requires a port, and `MCPServerBuilder.port(_:)` now reaches the
  listener.** The builder's port was dead: `run()` read `args.port` whenever `--http` was
  present and the flag always populated it, so the builder value could never win. `--http`
  now selects the transport on its own and the port after it is optional, with an explicit
  flag value overriding the builder — the precedence `--tls-cert`/`--tls-key` already
  followed.

  **Behaviour change:** `my-server --http` with no port previously fell through to *stdio*,
  because the transport was only switched when a parsable port followed. It now serves HTTP
  on the builder's port, or 8080. A trailing argument that is not a valid `UInt16` is left
  for the other flags rather than swallowed, so `--http --verbose` parses both.

### Added
- `ParsedArguments.explicitPort` — the port carried by `--http`, or `nil` when the flag named
  none. `ParsedArguments.port` is unchanged and still defaults to 8080, but it cannot
  distinguish a requested port from the default, so `explicitPort` is what port resolution
  should read.
- `SSEFrameParsingTests` — frame parsing under CRLF, LF and bare-CR terminators; a CRLF split
  across two chunks; and an unterminated frame retained for the next chunk.
- Four `CLIArgumentParsingTests` covering `--http` with no port, with a non-numeric next
  argument, with an explicit port, and with a value too large for `UInt16`.

### Changed (dependencies)
- **SwiftOAuth floor raised `0.2.0` → `0.4.0`.** `0.2.0` is the tag that was re-cut upstream
  and poisoned the local fingerprint database; a clean resolve could still land on it, so the
  2026-08-18 bump was not durable until the manifest agreed with `Package.resolved`.

  The re-cut is no longer a mystery: `v0.2.0` was moved forward one commit to `9396c13`
  (*"test(core): adopt SwiftMCPServer's TokenGenerator suite; close a PKCE gap"*, 2026-08-06),
  whose diff is `CHANGELOG.md`, `PKCETests.swift` and `TokenGeneratorTests.swift` — nothing
  under `Sources/`. The earlier commit `3b361149` is still reachable on `main` and contained
  in `v0.2.0` through `v0.5.0`; the tag moved to a descendant rather than orphaning anything.
  That is why bumping to 0.4.0 worked and why no consumer's behaviour changed.

### Documentation
- `README.md`'s usage example compiles. It showed `MCPServer(name:version:)` and
  `server.tool("greet") { }`, neither of which exists; it now shows an `MCPToolHandler`
  conformance and `MCPServer.builder()`. README fences are not covered by `doc-code`, which
  is why this rotted undetected.
- `GettingStarted.md` documented the port asymmetry as intentional. That paragraph is
  replaced with the new precedence and a worked example.


## [1.1.6] - 2026-09-01

### Fixed
- **The DocC catalogue is declared, not merely tolerated.** `swift build` emitted
  `found 1 file(s) which are unhandled` for `SwiftMCPServer.docc`. The manifest
  carried a long note saying both fixes were worse than the warning: `exclude:`
  silently empties the documentation (still true), and `resources: [.copy(...)]`
  fails the build (no longer true). Re-measured 2026-08-28 — the build is clean,
  the warning is gone, and DocC still reads the catalogue: an intentionally
  broken symbol link injected into `SwiftMCPServer.md` was caught by `doc-lint`
  under the new declaration. The note is kept in the manifest with that
  correction rather than deleted.

- **Every `## Usage` example compiles.** Eleven `doc-comment-code` errors,
  surfaced when that checker briefly entered the default set upstream. They had
  been wrong for as long as they existed.

  The builder examples called a `getMyTools()` and a `MyToolHandler` that nothing
  defined; both fences now take their handlers as parameters, which is closer to
  how a host actually wires them anyway. `HTTPRequest` and `HTTPResponse` needed
  their `jsonData` bound, and it is now a real JSON-RPC frame rather than an
  opaque name.

  The two provider protocols used `{ ... }` as a stand-in body. Swift parses that
  as a unary operator, so the fence could not compile; the conformances now show
  an empty list and a `fatalError` naming what the implementer supplies. They also
  needed `import MCP`, and `NIOHTTPConnection` needed `import NIOCore` — the fence
  preamble is Foundation plus this module, so a type from a dependency has to be
  imported the same way a reader copying the example would have to.

### Added
- **DocC documentation catalog** at `Sources/SwiftMCPServer/SwiftMCPServer.docc/`. The landing page curates all 37 public types into 11 topic groups (Essentials, Command-Line Interface, Defining Tools, Tool Registration, Resources and Prompts, Authentication, HTTP Transport, HTTP Model Types, Sessions and Streaming, Logging, Utilities).
- `GettingStarted` article covering package integration, writing an `MCPToolHandler`, builder assembly, transport selection, resource and prompt providers, API key management, and environment variables.

### Fixed
- **`doc-lint` quality gate now passes.** It previously errored with "found no target owning a `.docc` catalogue, so it examined nothing" — refusing to report a green it could not justify.

### Known Issues
- ~~`swift build` emits two `found 1 file(s) which are unhandled` warnings for the `.docc` catalog... `resources: [.copy(...)]` fails the build outright, as SwiftPM special-cases `.docc`.~~ **Resolved in this release**, and the second half was no longer true when written: `resources: [.copy(...)]` builds clean as of 2026-08-28. See the first entry under *Fixed*. The reasoning was sound when first measured; what changed is SwiftPM, not the argument.

## [1.1.5] - 2026-08-07

### Fixed
- **APIKeyStore no longer loses keys written by another process.** `ensureLoaded()` read the key file only once per process, so a long-running server cached its key set at startup and never re-read it. Any subsequent `save()` — including the `lastUsed` timestamp written on every successful authentication — persisted that stale snapshot over the file, silently destroying keys added meanwhile by the CLI. In practice this meant `--generate-key` printed a credential, reported success, and produced a key that never authenticated.
- Reads now detect staleness by comparing the key file's modification date against the one captured at the last read, reloading only when another process has written (one `stat` in the common case).
- `generateKey`, `revokeKey`, and `isValid` now perform their read-modify-write under an exclusive `flock` on a dedicated `.api-keys.lock` file, re-reading from disk inside the lock. A separate lock file is required because `save()` writes atomically via inode replacement, so a lock held on the key file itself would not be observed by the next writer.
- `isValid` degrades safely when the lock cannot be acquired: it answers from the freshest readable copy and skips the `lastUsed` write rather than risk clobbering a concurrent writer.
- Removed a CWE-22 path-traversal surface — `fileModificationDate()` now reads through the URL resource API instead of a string path, and `keysFile` standardizes its directory.

### Added
- `APIKeyStoreError` with a `lockUnavailable` case, thrown when a mutation is refused because the store's advisory lock could not be taken.
- `APIKeyStore Cross-Process Consistency` test suite covering validation-clobbers-external-key, server-accepts-external-key, revocation-not-resurrected, and generation-merges-external-additions.

## [1.1.4] - 2026-06-08

### Fixed
- Eliminated all compiler warnings (14 warnings → 0)
- Replaced async `addHandler()` with `syncOperations.addHandler()` in channel pipeline setup, resolving NIO Sendable conformance warnings
- Removed unnecessary `nonisolated(unsafe)` annotations and concurrency justification comments from HTTPServerTransport
- Simplified APIKeyStore.isValid() by removing redundant Task wrapper around synchronous actor-isolated save()

## [1.1.3] - 2026-06-08

### Fixed
- Refactored 6 high-complexity functions to reduce cognitive complexity (MCPServer.run 60→15, handleConsentSubmission 35→10, processStreamablePost 23→8)
- Eliminated O(n²) string concatenation in HTTPModels, HTTPConnection, and SSESession
- Fixed concurrency bug in SSESessionManager.cleanupExpiredSessions (fire-and-forget Tasks never populated expired list)
- Resolved call-graph amplification in session cleanup methods
- Institutional consistency score improved from 0.75 to 1.00

## [1.1.2] - 2026-06-07

### Fixed
- Quality gate compliance: zero errors, zero warnings across all checks
- Unique site-specific justifications for all nonisolated(unsafe) usages

## [1.1.1] - 2026-05-17

### Fixed
- Quality gate compliance: strict concurrency justifications, doc coverage, test assertions
- Hex formatting for SHA-256 hashes and channel IDs
- Path traversal prevention using URL-based directory creation
- Task closure isolation in actor contexts

### Added
- MCP Streamable HTTP transport (spec 2025-03-26)
- OAuth 2.0 authorization server with PKCE support
- RFC 9728 protected resource metadata
- API key authentication
- SQLite-based OAuth token storage
- SSE session management with heartbeat
- TLS/HTTPS support via SwiftNIO SSL
- Privacy-annotated logging via LogPrivacy extension
- Injectable RandomNumberGenerator for deterministic testing

## [1.1.0]

### Added
- Initial MCP server implementation
- HTTP and stdio transports
- Tool registration and execution
