import Foundation
import Testing
import DockerKit
@testable import AppCore

/// A value that must never show up outside the create request.
private let leak = "Sup3r-s3cret value!"

private func secretRecipe() -> ContainerRecipe {
    var recipe = ContainerRecipe(image: "postgres:17")
    recipe.name = "db"
    recipe.env = [
        .init(key: "MODE", value: "prod"),
        .init(key: "POSTGRES_PASSWORD", value: "", secret: "db-password")
    ]
    return recipe
}

private let store = InMemorySecretStore(["db-password": leak])

// MARK: - Names and references

@Test func secretNameRule() {
    for name in ["a", "db-password", "API_TOKEN.v2", "9x", String(repeating: "a", count: 64)] {
        #expect(EnvSecrets.isValidName(name))
    }
    for name in ["", "-a", "_a", "a b", "a:b", "a,b", "ключ", String(repeating: "a", count: 65)] {
        #expect(!EnvSecrets.isValidName(name))
    }
    #expect(EnvSecrets.nameIssue("db", taken: ["db"]) != nil)
    #expect(EnvSecrets.nameIssue("db", taken: ["db"], current: "db") == nil)
    #expect(EnvSecrets.nameIssue("", taken: []) == nil)
    #expect(EnvSecrets.nameIssue("a b", taken: []) != nil)
}

@Test func referenceTextRoundTrips() {
    #expect(EnvSecrets.referenceText("db") == "keychain:db")
    #expect(EnvSecrets.secretName(inValue: "keychain:db") == "db")
    #expect(EnvSecrets.secretName(inValue: "keychain:") == nil)
    #expect(EnvSecrets.secretName(inValue: "keychain:a b") == nil)
    #expect(EnvSecrets.secretName(inValue: "plain") == nil)
}

@Test func variableIssues() {
    #expect(EnvSecrets.variableIssue(key: "TOKEN", isAppleHost: true) == nil)
    #expect(EnvSecrets.variableIssue(key: "_X1", isAppleHost: false) == nil)
    #expect(EnvSecrets.variableIssue(key: "1X", isAppleHost: false) == .invalidVariable("1X"))
    #expect(EnvSecrets.variableIssue(key: "A-B", isAppleHost: false) == .invalidVariable("A-B"))
    #expect(EnvSecrets.variableIssue(key: "HOME", isAppleHost: true) == .reservedVariable("HOME"))
    #expect(EnvSecrets.variableIssue(key: "HOME", isAppleHost: false) == nil)
    var recipe = secretRecipe()
    recipe.env.append(.init(key: "PATH", value: "", secret: "x"))
    #expect(EnvSecrets.issues(recipe.env, isAppleHost: true) == [2: .reservedVariable("PATH")])
}

// MARK: - Create time

@Test func resolvedRequestCarriesValueLabelAndAppleKeys() async throws {
    let request = try await secretRecipe().resolvedCreateRequest(name: "db", isAppleHost: true, store: store)
    #expect(request.env == ["MODE=prod", "POSTGRES_PASSWORD=\(leak)"])
    #expect(request.labels[SecretEnvLabel.key] == "POSTGRES_PASSWORD:db-password")
    #expect(request.appleOptions?.secretEnvKeys == ["POSTGRES_PASSWORD"])
}

@Test func dockerRequestHasLabelButNoAppleOptions() async throws {
    let request = try await secretRecipe().resolvedCreateRequest(name: "db", isAppleHost: false, store: store)
    #expect(request.env.contains("POSTGRES_PASSWORD=\(leak)"))
    #expect(request.labels[SecretEnvLabel.key] == "POSTGRES_PASSWORD:db-password")
    #expect(request.appleOptions == nil)
}

@Test func plainRecipeGetsNoSecretLabel() async throws {
    var recipe = ContainerRecipe(image: "alpine")
    recipe.env = [.init(key: "A", value: "1"), .init(key: " ", value: "skip")]
    let request = try await recipe.resolvedCreateRequest(name: nil, isAppleHost: true, store: store)
    #expect(request.env == ["A=1"])
    #expect(request.labels[SecretEnvLabel.key] == nil)
    #expect(request.appleOptions?.secretEnvKeys.isEmpty ?? true)
}

@Test func missingSecretFailsWithNameOnly() async throws {
    var recipe = secretRecipe()
    recipe.env.append(.init(key: "API", value: "", secret: "gone"))
    do {
        _ = try await recipe.resolvedCreateRequest(name: nil, isAppleHost: false, store: store)
        Issue.record("expected an error")
    } catch let error as SecretError {
        #expect(error == .notFound("gone"))
        let text = error.localizedDescription
        #expect(text.contains("gone"))
        #expect(!text.contains(leak))
    }
}

@Test func authorizeRunsOnceAndCanRefuse() async throws {
    let counter = AuthorizeCounter()
    _ = try await EnvSecrets.resolve(secretRecipe().env, isAppleHost: false, store: store) {
        await counter.bump(); return true
    }
    #expect(await counter.value == 1)

    let local = InMemorySecretStore(["db-password": leak])
    await #expect(throws: SecretError.authenticationFailed) {
        _ = try await EnvSecrets.resolve(secretRecipe().env, isAppleHost: false, store: local) { false }
    }
    #expect(local.reads == 0)
}

@Test func noSecretsMeansNoAuthorizeAndNoReads() async throws {
    let local = InMemorySecretStore(["db-password": leak])
    var recipe = ContainerRecipe(image: "alpine")
    recipe.env = [.init(key: "A", value: "1")]
    let values = try await EnvSecrets.resolve(recipe.env, isAppleHost: true, store: local) {
        Issue.record("authorize must not run"); return false
    }
    #expect(values.isEmpty)
    #expect(local.reads == 0)
}

@Test func reservedVariableFailsBeforeReading() async throws {
    let local = InMemorySecretStore(["db-password": leak])
    var recipe = ContainerRecipe(image: "alpine")
    recipe.env = [.init(key: "HOME", value: "", secret: "db-password")]
    await #expect(throws: SecretError.reservedVariable("HOME")) {
        _ = try await EnvSecrets.resolve(recipe.env, isAppleHost: true, store: local)
    }
    #expect(local.reads == 0)
}

// MARK: - Recipes and commands never hold the value

@Test func recipeJSONHoldsReferenceOnly() throws {
    var recipe = secretRecipe()
    // Even a stale value in the field must not be written.
    recipe.env[1].value = leak
    let text = String(decoding: try JSONEncoder().encode(recipe), as: UTF8.self)
    #expect(!text.contains(leak))
    #expect(text.contains("\"secret\":\"db-password\""))
    let back = try JSONDecoder().decode(ContainerRecipe.self, from: Data(text.utf8))
    #expect(back.env[1] == .init(key: "POSTGRES_PASSWORD", value: "", secret: "db-password"))
}

@Test func oldRecipeJSONStillDecodes() throws {
    let json = #"{"image":"alpine","env":[{"key":"A","value":"1"}]}"#
    let recipe = try JSONDecoder().decode(ContainerRecipe.self, from: Data(json.utf8))
    #expect(recipe.env == [.init(key: "A", value: "1")])
    #expect(recipe.env[0].secret == nil)
}

@Test func copiedCommandPrintsReferenceAndParsesBack() throws {
    for dialect in [RunCommandParser.Dialect.docker, .appleContainer] {
        let text = RunCommandFormatter.command(for: secretRecipe(), dialect: dialect)
        #expect(!text.contains(leak))
        #expect(text.contains("POSTGRES_PASSWORD=keychain:db-password"))
        let parsed = try RunCommandParser.parse(text)
        #expect(parsed.recipe.env == secretRecipe().env)
    }
}

@Test func pastedReferenceBecomesSecretRow() throws {
    let parsed = try RunCommandParser.parse("docker run -e TOKEN=keychain:api -e PLAIN=keychain: alpine")
    #expect(parsed.recipe.env == [
        .init(key: "TOKEN", value: "", secret: "api"),
        .init(key: "PLAIN", value: "keychain:")
    ])
}

// MARK: - After create

private func inspect(env: [String], labels: [String: String]) throws -> ContainerDetails {
    let labelJSON = String(decoding: try JSONSerialization.data(withJSONObject: labels), as: UTF8.self)
    let envJSON = String(decoding: try JSONSerialization.data(withJSONObject: env), as: UTF8.self)
    let json = """
    {"Id":"abc","Name":"/db","State":{"Status":"running","Running":true,"Paused":false,"Restarting":false,
     "OOMKilled":false,"Pid":1,"ExitCode":0,"Error":"","StartedAt":"","FinishedAt":""},
     "HostConfig":{"NetworkMode":"default"},
     "Config":{"Image":"postgres:17","Env":\(envJSON),"Labels":\(labelJSON),"Tty":false},
     "NetworkSettings":{"Ports":{}},"Mounts":[]}
    """
    return try JSONDecoder().decode(ContainerDetails.self, from: Data(json.utf8))
}

@Test func inspectToRecipeRestoresReferences() throws {
    let d = try inspect(
        env: ["MODE=prod", "POSTGRES_PASSWORD=\(leak)"],
        labels: [SecretEnvLabel.key: "POSTGRES_PASSWORD:db-password", "app": "db"]
    )
    let recipe = ContainerRecipe(details: d)
    #expect(recipe.env == secretRecipe().env)
    #expect(recipe.labels == [.init(key: "app", value: "db")])
    let text = String(decoding: try JSONEncoder().encode(recipe), as: UTF8.self)
    #expect(!text.contains(leak))
    #expect(!RunCommandFormatter.command(for: recipe, dialect: .docker).contains(leak))
}

@Test func displayLinesHideSecretValues() {
    let lines = EnvSecrets.displayLines(
        env: ["MODE=prod", "TOKEN=\(leak)", "BARE"],
        labels: [SecretEnvLabel.key: "TOKEN:api"]
    )
    #expect(lines == [
        .init(key: "MODE", value: "prod", secret: nil),
        .init(key: "TOKEN", value: nil, secret: "api"),
        .init(key: "BARE", value: "", secret: nil)
    ])
}

@MainActor
@Test func recreateRequestKeepsSecretKeysOutOfArgv() throws {
    let labels = [SecretEnvLabel.key: "POSTGRES_PASSWORD:db-password"]
    let options = ContainerCreateRequest.AppleOptions(labels: labels)
    #expect(options.secretEnvKeys == ["POSTGRES_PASSWORD"])
}

private actor AuthorizeCounter {
    var value = 0
    func bump() { value += 1 }
}
