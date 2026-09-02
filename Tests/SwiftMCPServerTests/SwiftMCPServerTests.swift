import Testing
@testable import SwiftMCPServer

@Suite("SwiftMCPServer Smoke Tests")
struct SwiftMCPServerSmokeTests {

    @Test("Package imports successfully")
    func packageImports() async {
        // Verify the module can be imported and key types exist
        let registry = ToolDefinitionRegistry()
        let tools = await registry.listTools()
        #expect(tools.isEmpty)
    }
}
