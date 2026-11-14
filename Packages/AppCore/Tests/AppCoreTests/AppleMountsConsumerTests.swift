import Foundation
import Testing
import DockerKit
@testable import AppCore

// The Docker-shaped mounts that DockerKit makes from the container 1.7.1
// fixture in `AppleContainerMountsTests` (read-only bind, read-write bind,
// named volume, tmpfs).
private let translatedMounts = """
[{"Type":"tmpfs","Source":"tmpfs","Destination":"/scratch","RW":true},
 {"Type":"bind","Source":"/Users/me/project/bindro","Destination":"/ro","RW":false},
 {"Type":"bind","Source":"/Users/me/project/bindrw","Destination":"/rw","RW":true},
 {"Type":"volume","Name":"gaom-data","Source":"/Users/me/Library/Application Support/com.apple.container/volumes/gaom-data/volume.img","Destination":"/data","RW":true}]
"""

private func appleDetails() throws -> ContainerDetails {
    try JSONDecoder().decode(ContainerDetails.self, from: Data("""
    {"Id":"gaom-mounts","Name":"/gaom-mounts","State":{"Status":"running","Running":true,"Paused":false,"Restarting":false,
     "OOMKilled":false,"Pid":0,"ExitCode":0,"Error":"","StartedAt":"","FinishedAt":""},
     "HostConfig":{"NetworkMode":"default"},
     "Config":{"Image":"docker.io/library/alpine:3.22","Cmd":["sleep","3600"],"Tty":false},
     "NetworkSettings":{"Ports":{}},
     "Mounts":\(translatedMounts)}
    """.utf8))
}

private func appleSummary() throws -> ContainerSummary {
    try JSONDecoder().decode(ContainerSummary.self, from: Data("""
    {"Id":"gaom-mounts","Names":["/gaom-mounts"],"State":"running","Mounts":\(translatedMounts)}
    """.utf8))
}

@Test func appleRecipeKeepsReadOnlyAndVolumeName() throws {
    let volumes = ContainerRecipe.volumes(details: try appleDetails())
    #expect(volumes == [
        .init(source: "/Users/me/project/bindro", target: "/ro", readOnly: true),
        .init(source: "/Users/me/project/bindrw", target: "/rw"),
        .init(source: "gaom-data", target: "/data")
    ])
}

@Test func appleExplainMountsNameTheVolume() throws {
    let text = ExplainInspectText.render(.mounts, details: try appleDetails())
    #expect(text.contains("bind /Users/me/project/bindro -> /ro (ro)"))
    #expect(text.contains("volume gaom-data -> /data (rw)"))
}

@Test func appleVolumeUsersAreCounted() throws {
    let containers = [try appleSummary()]
    #expect(VolumeTransferPlan.users(of: .named("gaom-data"), in: containers).count == 1)
    let action = DestructiveAction.removeVolume(name: "gaom-data", containers: containers, engine: .appleContainer)
    #expect(action.impact == .containersUseVolume(1))
}
