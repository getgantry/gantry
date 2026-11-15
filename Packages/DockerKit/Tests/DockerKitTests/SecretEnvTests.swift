import Foundation
import Testing
@testable import DockerKit

@Test func secretEnvLabelRoundTrips() {
    let refs = ["B_KEY": "b-name", "A_KEY": "a.name"]
    let value = try! #require(SecretEnvLabel.encode(refs))
    #expect(value == "A_KEY:a.name,B_KEY:b-name")
    #expect(!value.contains("="))
    #expect(SecretEnvLabel.decode(value) == refs)
    #expect(SecretEnvLabel.encode([:]) == nil)
    #expect(SecretEnvLabel.decode("bad,:x,K:,OK:n") == ["OK": "n"])
}

@Test func appleOptionsReadSecretKeysFromLabels() {
    let options = ContainerCreateRequest.AppleOptions(labels: [SecretEnvLabel.key: "TOKEN:t,DB:d"])
    #expect(options.secretEnvKeys == ["DB", "TOKEN"])
    #expect(!options.isEmpty)
    #expect(ContainerCreateRequest.AppleOptions(labels: [:]).isEmpty)
}

@Test func appleOptionsEncodeSecretKeys() throws {
    let data = try JSONEncoder().encode(ContainerCreateRequest.AppleOptions(secretEnvKeys: ["TOKEN"]))
    let text = String(decoding: data, as: UTF8.self)
    #expect(text == #"{"SecretEnvKeys":["TOKEN"]}"#)
}

@Test func reservedNamesForCLI() {
    for name in ["PATH", "HOME", "CONTAINER_DEBUG", "DYLD_INSERT_LIBRARIES", "LC_ALL", "TMPDIR"] {
        #expect(SecretEnvRedaction.isReservedForCLI(name))
    }
    for name in ["POSTGRES_PASSWORD", "API_TOKEN", "HOMEPAGE"] {
        #expect(!SecretEnvRedaction.isReservedForCLI(name))
    }
}

@Test func redactsDockerInspect() throws {
    let json = #"{"Config":{"Env":["MODE=prod","TOKEN=abc=123"],"Labels":{"com.gantry.secret-env":"TOKEN:api"}}}"#
    let out = String(decoding: SecretEnvRedaction.redactInspectJSON(Data(json.utf8)), as: UTF8.self)
    #expect(!out.contains("abc=123"))
    #expect(out.contains("TOKEN=[REDACTED]"))
    #expect(out.contains("MODE=prod"))
}

@Test func redactsAppleInspect() throws {
    let json = #"[{"configuration":{"labels":{"com.gantry.secret-env":"PW:db"},"initProcess":{"environment":["PW=hunter2","PATH=/bin"]}}}]"#
    let out = String(decoding: SecretEnvRedaction.redactInspectJSON(Data(json.utf8)), as: UTF8.self)
    #expect(!out.contains("hunter2"))
    #expect(out.contains("PW=[REDACTED]"))
    #expect(out.contains("PATH=/bin"))
}

@Test func redactionLeavesOtherDataAlone() {
    let plain = Data(#"{"Config":{"Env":["TOKEN=abc"]}}"#.utf8)
    #expect(SecretEnvRedaction.redactInspectJSON(plain) == plain)
    let notJSON = Data("not json".utf8)
    #expect(SecretEnvRedaction.redactInspectJSON(notJSON) == notJSON)
}
