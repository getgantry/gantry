import Foundation
import Testing
@testable import DockerKit

@Test func appleLabelEscapingLeavesPlainLabelsAlone() {
    let labels = ["app": "web", "com.docker.compose.project": "shop", "pct": "100%"]
    #expect(AppleLabelEscaping.encodeForCreate(labels) == labels)
}

@Test func appleLabelEscapingEscapesAllValuesAndStampsMarker() {
    let labels = ["origin": "a=b", "pct": "100%", "plain": "x"]
    let encoded = AppleLabelEscaping.encodeForCreate(labels)
    #expect(encoded == [
        "origin": "a%3Db",
        "pct": "100%25",
        "plain": "x",
        AppleLabelEscaping.markerKey: AppleLabelEscaping.markerValue
    ])
    #expect(encoded.values.allSatisfy { !$0.contains("=") })
}

@Test func appleLabelEscapingRoundTrips() {
    let labels = [
        "origin": "a=b=c",
        "query": "x=1&y=%3D",
        "padding": "dGVzdA==",
        "literal": "%25",
        "com.docker.compose.project.config_files": "/tmp/a=b/compose.yaml"
    ]
    let encoded = AppleLabelEscaping.encodeForCreate(labels)
    #expect(AppleLabelEscaping.decodeContainerLabels(encoded) == labels)
}

@Test func appleLabelEscapingKeepsForeignPercentSequences() {
    // No marker: a label set outside Gantry is shown exactly as stored.
    let foreign = ["url": "https://x/?q=a%3Db", "pct": "100%25"]
    #expect(AppleLabelEscaping.decodeContainerLabels(foreign) == foreign)
}

@Test func appleLabelEscapingRecomputesStaleMarker() {
    let stale = ["app": "web", AppleLabelEscaping.markerKey: AppleLabelEscaping.markerValue]
    #expect(AppleLabelEscaping.encodeForCreate(stale) == ["app": "web"])
}

@Test func appleLabelEscapingComposesWithKernelMarkers() {
    // Kernel markers are escaped by AppleOptions already; a second layer of
    // escaping from another label must still decode back to the options.
    let options = ContainerCreateRequest.AppleOptions(kernelArgs: ["a=1", "pct=100%"])
    var labels = options.labels
    labels["origin"] = "a=b"
    let decoded = AppleLabelEscaping.decodeContainerLabels(AppleLabelEscaping.encodeForCreate(labels))
    #expect(decoded["origin"] == "a=b")
    #expect(ContainerCreateRequest.AppleOptions(labels: decoded) == options)
}

private func appleContainerJSON(labels: [String: String]) throws -> Data {
    let element: [String: Any] = [
        "status": "running",
        "configuration": [
            "id": "c1",
            "image": ["reference": "docker.io/library/alpine:latest", "descriptor": ["digest": "sha256:1"]],
            "labels": labels,
            "initProcess": ["executable": "sleep", "arguments": ["1"], "environment": [], "workingDirectory": "/"]
        ] as [String: Any]
    ]
    return try JSONSerialization.data(withJSONObject: [element])
}

@Test func appleContainerListAndInspectUnescapeMarkedLabels() throws {
    let stored = ["origin": "a%3Db", AppleLabelEscaping.markerKey: AppleLabelEscaping.markerValue]
    let data = try appleContainerJSON(labels: stored)

    let list = try AppleContainerJSON.containersListBody(fromAppleList: data, all: true)
    let summary = try #require(try JSONDecoder().decode([ContainerSummary].self, from: list).first)
    #expect(summary.labels == ["origin": "a=b"])

    let element = try #require(AppleContainerJSON.array(try AppleContainerJSON.decode(data)).first)
    let inspect = try AppleContainerJSON.containerInspectBody(fromAppleInspect: element)
    let details = try JSONDecoder().decode(ContainerDetails.self, from: inspect)
    #expect(details.config.labels == ["origin": "a=b"])
}

@Test func appleContainerListKeepsUnmarkedLabels() throws {
    let data = try appleContainerJSON(labels: ["url": "q=a%3Db"])
    let list = try AppleContainerJSON.containersListBody(fromAppleList: data, all: true)
    let summary = try #require(try JSONDecoder().decode([ContainerSummary].self, from: list).first)
    #expect(summary.labels == ["url": "q=a%3Db"])
}
