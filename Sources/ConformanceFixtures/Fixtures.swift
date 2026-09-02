import Foundation
import MCP

/// The tools, prompts and resources the official conformance suite expects a target to expose.
///
/// The suite does not merely check protocol shapes: most of its scenarios call a **named**
/// fixture and assert on what comes back — `test_image_content` must return an image,
/// `test_simple_prompt` must return one particular sentence. A target that does not register
/// them reports "1 passed, 1 failed" for each such scenario, and the resulting number says
/// nothing about conformance because the failures are all "no such tool".
///
/// The names and payloads here are taken from the suite's own scenario documentation, which
/// states them exactly. Where a payload is arbitrary, it is the string the suite asserts on
/// rather than one chosen here.
public enum Fixtures {
    /// A 1×1 PNG. The suite requires image content; it does not require a picture of anything.
    public static let imageBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="

    /// A WAV header with an empty data chunk — the smallest thing that is audio.
    public static let audioBase64 = "UklGRiYAAABXQVZFZm10IBAAAAABAAEAQB8AAAB9AAACABAAZGF0YQIAAAA="

    // MARK: - Tools

    /// An object schema taking no arguments.
    private static let noArguments: Value = .object([
        "type": .string("object"),
        "properties": .object([:]),
    ])

    private static func stringArgument(_ name: String, description: String) -> Value {
        .object([
            "type": .string("object"),
            "properties": .object([name: .object([
                "type": .string("string"),
                "description": .string(description),
            ])]),
            "required": .array([.string(name)]),
        ])
    }

    /// Every tool the suite calls by name.
    public static let tools: [Tool] = [
        Tool(
            name: "test_simple_text", description: "Returns simple text content",
            inputSchema: noArguments),
        Tool(
            name: "test_image_content", description: "Returns image content",
            inputSchema: noArguments),
        Tool(
            name: "test_audio_content", description: "Returns audio content",
            inputSchema: noArguments),
        Tool(
            name: "test_embedded_resource", description: "Returns embedded resource content",
            inputSchema: noArguments),
        Tool(
            name: "test_multiple_content_types",
            description: "Returns text, image and resource content together",
            inputSchema: noArguments),
        Tool(
            name: "test_error_handling", description: "Always reports a tool execution error",
            inputSchema: noArguments),
        Tool(
            name: "test_tool_with_logging",
            description: "Sends three log notifications while running",
            inputSchema: noArguments),
        Tool(
            name: "test_tool_with_progress",
            description: "Reports progress while running",
            inputSchema: noArguments),
        Tool(
            name: "test_missing_capability",
            description: "Requires the sampling client capability, and refuses without it",
            inputSchema: noArguments),
        Tool(
            name: "greet", description: "Returns a greeting",
            inputSchema: stringArgument("name", description: "Who to greet")),
        Tool(
            name: "test_sampling",
            description: "Asks the client's model to answer a prompt (pre-2026 revisions)",
            inputSchema: stringArgument("prompt", description: "Text to send to the model")),
        Tool(
            name: "test_elicitation",
            description: "Asks the client's user a question (pre-2026 revisions)",
            inputSchema: stringArgument("message", description: "Text displayed to the user")),
        Tool(
            name: "test_elicitation_sep1034_defaults",
            description: "Elicits with a default for every primitive type (SEP-1034)",
            inputSchema: noArguments),
        Tool(
            name: "test_elicitation_sep1330_enums",
            description: "Elicits with all five enum variants (SEP-1330)",
            inputSchema: noArguments),
        Tool(
            name: "test_trigger_tool_change",
            description: "Mutates the tool list, so a subscriber can observe the notification",
            inputSchema: noArguments),
        Tool(
            name: "test_trigger_prompt_change",
            description: "Mutates the prompt list, so a subscriber can observe the notification",
            inputSchema: noArguments),
        Tool(
            name: "test_logging_tool",
            description: "Logs only when the request asked for logs",
            inputSchema: noArguments),
        Tool(
            name: "test_streaming_elicitation",
            description: "Streams interim results while it gathers input",
            inputSchema: noArguments),
        Tool(
            name: "test_custom_headers",
            description: "Takes an argument that also travels in a header (SEP-2243)",
            // The `x-mcp-header` annotation is the whole point of this fixture: it declares that
            // `region` is mirrored into `Mcp-Param-Region`, which is what the transport then
            // holds the request to.
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "region": .object([
                        "type": .string("string"),
                        // The annotation names the parameter; the header is `Mcp-Param-Region`.
                        "x-mcp-header": .string("Region"),
                    ])
                ]),
                "required": .array([.string("region")]),
            ])),
        Tool(
            name: "json_schema_2020_12_tool",
            description: "Tool with JSON Schema 2020-12 features",
            // Copied from the suite's own scenario documentation rather than approximated. The
            // checks read individual keywords — `$anchor` inside `$defs`, `allOf`/`anyOf`,
            // `if`/`then`/`else`, `additionalProperties` — to prove SEP-1613 and SEP-2106
            // keywords survive a round trip through the server instead of being stripped by a
            // schema type that only models what it understands.
            inputSchema: .object([
                "$schema": .string("https://json-schema.org/draft/2020-12/schema"),
                "type": .string("object"),
                "$defs": .object([
                    "address": .object([
                        "$anchor": .string("addressDef"),
                        "type": .string("object"),
                        "properties": .object([
                            "street": .object(["type": .string("string")]),
                            "city": .object(["type": .string("string")]),
                        ]),
                    ])
                ]),
                "properties": .object([
                    "name": .object(["type": .string("string")]),
                    "address": .object(["$ref": .string("#/$defs/address")]),
                    "contactMethod": .object([
                        "type": .string("string"),
                        "enum": .array([.string("phone"), .string("email")]),
                    ]),
                    "phone": .object(["type": .string("string")]),
                    "email": .object(["type": .string("string")]),
                ]),
                "allOf": .array([
                    .object([
                        "anyOf": .array([
                            .object(["required": .array([.string("phone")])]),
                            .object(["required": .array([.string("email")])]),
                        ])
                    ])
                ]),
                "if": .object([
                    "properties": .object([
                        "contactMethod": .object(["const": .string("phone")])
                    ]),
                    "required": .array([.string("contactMethod")]),
                ]),
                "then": .object(["required": .array([.string("phone")])]),
                "else": .object(["required": .array([.string("email")])]),
                "additionalProperties": .bool(false),
            ])),
    ]

    // MARK: - Elicitation schemas

    /// A schema carrying a default for every primitive type (SEP-1034).
    ///
    /// The point of the defaults is that a client can render them and a user can accept without
    /// typing; a schema that omits them makes every field mandatory work.
    public static let defaultsSchema = Elicitation.RequestSchema(
        properties: [
            "name": .object(["type": .string("string"), "default": .string("John Doe")]),
            "age": .object(["type": .string("integer"), "default": .int(30)]),
            "score": .object(["type": .string("number"), "default": .double(95.5)]),
            "status": .object([
                "type": .string("string"),
                "enum": .array([.string("active"), .string("inactive"), .string("pending")]),
                "default": .string("active"),
            ]),
            "verified": .object(["type": .string("boolean"), "default": .bool(true)]),
        ])

    /// A schema exercising all five enum shapes SEP-1330 defines.
    ///
    /// The property names are the ones the suite reads back by name, so they are its spelling
    /// rather than this file's preference.
    ///
    /// The three single-select forms differ only in how a *label* is carried: not at all, in
    /// `oneOf` with a `title`, or in the deprecated parallel `enumNames` array. A client has to
    /// handle each, which is why the fixture offers all three rather than the one a server would
    /// naturally write.
    public static let enumVariantsSchema = Elicitation.RequestSchema(
        properties: [
            "untitledSingle": .object([
                "type": .string("string"),
                "enum": .array([.string("option1"), .string("option2"), .string("option3")]),
            ]),
            "titledSingle": .object([
                "type": .string("string"),
                "oneOf": .array([
                    .object(["const": .string("value1"), "title": .string("First Option")]),
                    .object(["const": .string("value2"), "title": .string("Second Option")]),
                    .object(["const": .string("value3"), "title": .string("Third Option")]),
                ]),
            ]),
            "legacyEnum": .object([
                "type": .string("string"),
                "enum": .array([.string("opt1"), .string("opt2"), .string("opt3")]),
                "enumNames": .array([
                    .string("Option One"), .string("Option Two"), .string("Option Three"),
                ]),
            ]),
            "untitledMulti": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("string"),
                    "enum": .array([.string("option1"), .string("option2"), .string("option3")]),
                ]),
            ]),
            "titledMulti": .object([
                "type": .string("array"),
                "items": .object([
                    "anyOf": .array([
                        .object(["const": .string("value1"), "title": .string("First Choice")]),
                        .object(["const": .string("value2"), "title": .string("Second Choice")]),
                        .object(["const": .string("value3"), "title": .string("Third Choice")]),
                    ])
                ]),
            ]),
        ])

    // MARK: - Prompts

    /// Every prompt the suite fetches by name.
    public static let prompts: [Prompt] = [
        Prompt(name: "test_simple_prompt", description: "A simple prompt without arguments"),
        Prompt(
            name: "test_prompt_with_arguments", description: "A prompt that accepts arguments",
            arguments: [
                Prompt.Argument(name: "arg1", description: "First test argument", required: true),
                Prompt.Argument(name: "arg2", description: "Second test argument", required: true),
            ]),
        Prompt(
            name: "test_prompt_with_embedded_resource",
            description: "A prompt that embeds a resource",
            arguments: [
                Prompt.Argument(
                    name: "resourceUri", description: "URI of the resource to embed",
                    required: true)
            ]),
        Prompt(name: "test_prompt_with_image", description: "A prompt with image content"),
    ]

    /// The messages a prompt answers with, or `nil` when no such prompt is registered.
    public static func promptMessages(
        named name: String, arguments: [String: String]?
    ) -> (description: String, messages: [Prompt.Message])? {
        switch name {
        case "test_simple_prompt":
            return ("A simple prompt", [
                .user(.text(text: "This is a simple prompt for testing."))
            ])

        case "test_prompt_with_arguments":
            let first = arguments?["arg1"] ?? ""
            let second = arguments?["arg2"] ?? ""
            return ("A prompt with arguments", [
                .user(.text(
                        text: "Prompt with arguments: arg1='\(first)', arg2='\(second)'"))
            ])

        case "test_prompt_with_embedded_resource":
            // The URI comes from the caller: the point of the scenario is that the resource the
            // client named is the one embedded.
            let uri = arguments?["resourceUri"] ?? "test://embedded-resource"
            return ("A prompt with an embedded resource", [
                .user(.resource(
                        resource: .text(
                            "Embedded resource content for testing.", uri: uri,
                            mimeType: "text/plain"))),
                .user(.text(text: "Please process the embedded resource above.")),
            ])

        case "test_prompt_with_image":
            return ("A prompt with an image", [
                .user(.image(data: imageBase64, mimeType: "image/png")),
                .user(.text(text: "Please analyze the image above.")),
            ])

        default:
            return nil
        }
    }

    // MARK: - Resources

    /// The resources the suite reads directly, as opposed to through a template.
    public static let resources: [Resource] = [
        Resource(
            name: "Static Text Resource", uri: "test://static-text",
            description: "A simple static text resource", mimeType: "text/plain"),
        Resource(
            name: "Static Binary Resource", uri: "test://static-binary",
            description: "A simple static binary resource", mimeType: "image/png"),
        Resource(
            name: "Watched Resource", uri: "test://watched-resource",
            description: "A resource that can be subscribed to for updates",
            mimeType: "text/plain"),
    ]

    /// The one URI template the suite exercises parameter substitution against.
    public static let resourceTemplates: [Resource.Template] = [
        Resource.Template(
            uriTemplate: "test://template/{id}/data", name: "Template Resource",
            description: "A resource template with a URI parameter",
            mimeType: "application/json")
    ]

    /// The contents of `uri`, or `nil` when this server has no such resource.
    ///
    /// Returning `nil` rather than empty contents is the distinction SEP-2164 draws: an empty
    /// `contents` array says "this resource is empty", which is a different claim from "there is
    /// no such resource", and a client cannot tell them apart.
    public static func resourceContents(for uri: String) -> [Resource.Content]? {
        switch uri {
        case "test://static-text":
            return [.text(
                "This is the content of the static text resource.", uri: uri,
                mimeType: "text/plain")]

        case "test://static-binary":
            guard let data = Data(base64Encoded: imageBase64) else { return nil }
            return [.binary(data, uri: uri, mimeType: "image/png")]

        case "test://watched-resource":
            return [.text("Watched resource content", uri: uri, mimeType: "text/plain")]

        default:
            // The one template this server declares: test://template/{id}/data.
            guard let id = templateIdentifier(in: uri) else { return nil }
            let json = #"{"id":"\#(id)","templateTest":true,"data":"Data for ID: \#(id)"}"#
            return [.text(json, uri: uri, mimeType: "application/json")]
        }
    }

    /// The `{id}` in `test://template/{id}/data`, or `nil` if `uri` does not match the template.
    ///
    /// Matched by structure rather than by a prefix test, so `test://template/1/data/extra` and
    /// `test://template//data` are both refused — a template that accepts more than it describes
    /// would answer for resources it does not have.
    private static func templateIdentifier(in uri: String) -> String? {
        let prefix = "test://template/"
        let suffix = "/data"
        guard uri.hasPrefix(prefix), uri.hasSuffix(suffix) else { return nil }
        let start = uri.index(uri.startIndex, offsetBy: prefix.count)
        let end = uri.index(uri.endIndex, offsetBy: -suffix.count)
        guard start < end else { return nil }
        let identifier = String(uri[start..<end])
        guard !identifier.contains("/") else { return nil }
        return identifier
    }
}
