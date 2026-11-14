import Foundation
import Testing
@testable import AppCore
@testable import DockerKit

/// The Inspect tab and Explain read `rawInspectContainer`. A secret value
/// must not reach them.
@MainActor
@Suite struct SecretInspectTests {
    private let leak = "gks-leak-7f3a9c"

    @Test func rawInspectContainerHidesSecretValues() async throws {
        let transport = MockTransport()
        transport.on(.get, "/version", json: Fixtures.version)
        transport.on(.get, "/containers/c1/json", json: """
        {"Id":"c1","Config":{"Env":["PLAIN=shown","GKS_TOKEN=\(leak)"],
         "Labels":{"\(SecretEnvLabel.key)":"GKS_TOKEN:gks-token"}}}
        """)
        let client = DockerClient(transport: transport)
        let version = try await client.negotiate()
        let session = HostSession(host: DockerHost(name: "Local", kind: .local))
        session._setConnectedClientForTesting(client, version: version)

        let text = await session.rawInspectContainer(id: "c1")
        #expect(!text.contains(leak))
        #expect(text.contains("GKS_TOKEN=\(SecretEnvRedaction.placeholder)"))
        #expect(text.contains("PLAIN=shown"))
    }
}
