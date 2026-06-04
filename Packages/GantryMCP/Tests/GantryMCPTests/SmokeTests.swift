import Testing
@testable import gantry_mcp

@Test
func canImportExecutableTarget() {
    let truncated = cap("hello", bytes: 100)
    #expect(truncated == "hello")
}
