import Foundation
import Testing
import Yams
@testable import DockerKit
@testable import AppCore

/// "Export as Compose" writes `keychain:NAME` for a variable that Gantry
/// filled from a Keychain secret, never the value. The sheet shows
/// `result.yaml` in the preview, copies `result.yaml` to the clipboard and
/// saves it with `ComposeExportWriter`, so these tests check all three texts.
@Suite struct ComposeSecretExportTests {
    private let leak = "gks-leak-value-1f2e3d4c5b6a"
    private let leak2 = "gks-leak-other-9a8b7c"

    private func dockerSource() throws -> ComposeExportSource {
        var root = try #require(try JSONSerialization.jsonObject(with: Data(ComposeExportFixtures.dockerContainer.utf8)) as? [String: Any])
        var config = root["Config"] as? [String: Any] ?? [:]
        config["Env"] = (config["Env"] as? [String] ?? []) + ["GKS_TOKEN=\(leak)", "API_KEY=\(leak2)", "PLAIN_SETTING=visible"]
        var labels = config["Labels"] as? [String: String] ?? [:]
        labels[SecretEnvLabel.key] = "API_KEY:api-key,GKS_TOKEN:gks-token"
        config["Labels"] = labels
        root["Config"] = config
        return ComposeExportSource(
            containerInspect: try JSONSerialization.data(withJSONObject: root),
            imageInspect: Data(ComposeExportFixtures.dockerImage.utf8)
        )
    }

    private func appleSource() throws -> ComposeExportSource {
        var element = try #require((try JSONSerialization.jsonObject(with: Data(ComposeExportFixtures.appleContainer.utf8)) as? [[String: Any]])?.first)
        var config = element["configuration"] as? [String: Any] ?? [:]
        var process = config["initProcess"] as? [String: Any] ?? [:]
        process["environment"] = (process["environment"] as? [String] ?? []) + ["GKS_TOKEN=\(leak)"]
        config["initProcess"] = process
        var labels = config["labels"] as? [String: String] ?? [:]
        labels[SecretEnvLabel.key] = "GKS_TOKEN:gks-token"
        config["labels"] = labels
        element["configuration"] = config
        let body = try AppleContainerJSON.containerInspectBody(fromAppleInspect: element)
        return ComposeExportSource(containerInspect: body, isAppleContainer: true)
    }

    private func environment(_ result: ComposeExportResult) throws -> [String: Any] {
        let root = try #require(try Yams.load(yaml: result.yaml) as? [String: Any])
        let services = try #require(root["services"] as? [String: Any])
        let service = try #require(services.values.first as? [String: Any])
        return try #require(service["environment"] as? [String: Any])
    }

    private func expectNoLeak(_ result: ComposeExportResult) throws {
        // Preview and clipboard text.
        #expect(!result.yaml.contains(leak))
        #expect(!result.yaml.contains(leak2))
        #expect(!result.includesSecretValues)
        // Saved file.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gks-compose-\(UUID().uuidString).yml")
        defer { try? FileManager.default.removeItem(at: url) }
        try ComposeExportWriter.write(result, to: url)
        let saved = try String(contentsOf: url, encoding: .utf8)
        #expect(!saved.contains(leak))
        #expect(!saved.contains(leak2))
    }

    @Test func dockerExportWritesKeychainReferences() throws {
        let result = try ComposeExporter.export([dockerSource()])
        let env = try environment(result)
        #expect(env["GKS_TOKEN"] as? String == "keychain:gks-token")
        #expect(env["API_KEY"] as? String == "keychain:api-key")
        #expect(env["PLAIN_SETTING"] as? String == "visible")
        // A Keychain variable is not offered as a "secret to include".
        #expect(!result.secrets.contains { $0.variable == "GKS_TOKEN" || $0.variable == "API_KEY" })
        #expect(!result.yaml.contains(SecretEnvLabel.key))
        try expectNoLeak(result)
    }

    @Test func includingEverySecretStillKeepsKeychainValuesOut() throws {
        let source = try dockerSource()
        let all = Set(["GKS_TOKEN", "API_KEY", "PLAIN_SETTING"].map { ComposeExportSecret(service: "web", variable: $0) })
        let result = try ComposeExporter.export([source], options: ComposeExportOptions(includedSecrets: all))
        try expectNoLeak(result)
    }

    @Test func appleExportWritesKeychainReferences() throws {
        let result = try ComposeExporter.export([appleSource()])
        let env = try environment(result)
        #expect(env["GKS_TOKEN"] as? String == "keychain:gks-token")
        try expectNoLeak(result)
    }
}
