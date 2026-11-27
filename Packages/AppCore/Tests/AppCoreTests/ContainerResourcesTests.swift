import Foundation
import Testing
import DockerKit
@testable import AppCore

@Suite struct MemorySizeTests {
    @Test(arguments: [
        ("512", Int64(512 << 20)), ("512m", 512 << 20), ("512M", 512 << 20), ("512MiB", 512 << 20),
        ("1.5g", 1536 << 20), ("2 GiB", 2 << 30), ("1t", 1 << 40), ("64k", 64 << 10),
        ("100b", 100), ("1,5g", 1536 << 20)
    ])
    func parsesSizes(text: String, bytes: Int64) {
        #expect(MemorySize.parse(text) == bytes)
    }

    @Test(arguments: ["", "12x", "-5m", "0", "m", "abc", "1..5g", "0.0001b"])
    func rejectsBadSizes(text: String) {
        #expect(MemorySize.parse(text) == nil)
    }

    @Test(arguments: [Int64(536_870_912), 1_610_612_736, 1 << 30, 67_108_864, 1000, 3 << 40])
    func formatRoundTrips(bytes: Int64) {
        #expect(MemorySize.parse(MemorySize.format(bytes)) == bytes)
    }

    @Test func formatPicksTheLargestExactUnit() {
        #expect(MemorySize.format(536_870_912) == "512m")
        #expect(MemorySize.format(1 << 30) == "1g")
        #expect(MemorySize.format(1000) == "1000b")
    }
}

@Suite struct ContainerResourceFormTests {
    private let limited = ContainerResources(
        nanoCPUs: 500_000_000, memory: 64 << 20, memoryReservation: 32 << 20,
        memorySwap: 128 << 20, restartPolicy: "on-failure", maxRetries: 3
    )

    private func docker(_ original: ContainerResources? = nil) -> ContainerResourceForm {
        ContainerResourceForm(original: original ?? limited, engine: .docker, hostCPUs: 8)
    }

    @Test func readsTheInspectValues() throws {
        let json = #"""
        {"Id":"c","Name":"/x","Image":"i","State":{"Status":"running","Running":true},
         "HostConfig":{"Memory":67108864,"MemoryReservation":33554432,"MemorySwap":-1,"NanoCpus":500000000,
           "RestartPolicy":{"Name":"on-failure","MaximumRetryCount":3}},
         "Config":{"Image":"alpine"}}
        """#
        let details = try JSONDecoder().decode(ContainerDetails.self, from: Data(json.utf8))
        let form = ContainerResourceForm(original: ContainerResources(details: details), engine: .docker, hostCPUs: 8)
        #expect(form.cpus == "0.5")
        #expect(form.memory == "64m")
        #expect(form.memoryReservation == "32m")
        #expect(form.memorySwap == "-1")
        #expect(form.restartPolicy == "on-failure")
        #expect(form.maxRetries == "3")
        #expect(form.isValid)
        #expect(!form.hasChanges)
    }

    @Test func emptyPolicyIsNo() {
        let form = docker(ContainerResources())
        #expect(form.restartPolicy == "no")
        #expect(form.cpus.isEmpty)
        #expect(form.isValid)
        #expect(form.dockerUpdate()?.isEmpty == true)
    }

    @Test func sendsOnlyTheChangedFields() throws {
        var form = docker()
        form.memory = "256m"
        let update = try #require(form.dockerUpdate())
        #expect(update == ContainerResourceUpdate(memory: 256 << 20))
        #expect(form.hasChanges)
    }

    @Test func sendsTheRestartPolicyWithRetries() throws {
        var form = docker()
        form.restartPolicy = "always"
        #expect(try #require(form.dockerUpdate()).restartPolicy == .init(name: "always", maximumRetryCount: 0))
        form.restartPolicy = "on-failure"
        form.maxRetries = "5"
        #expect(try #require(form.dockerUpdate()).restartPolicy == .init(name: "on-failure", maximumRetryCount: 5))
        form.maxRetries = "-1"
        #expect(form.error(for: .restartPolicy) != nil)
        #expect(form.dockerUpdate() == nil)
    }

    @Test(arguments: ["0", "-1", "abc", "8.5", "9"])
    func rejectsBadCPUs(text: String) {
        var form = docker()
        form.cpus = text
        #expect(form.error(for: .cpus) != nil)
        #expect(!form.isValid)
        #expect(form.dockerUpdate() == nil)
    }

    @Test func acceptsCPUsUpToTheHostCount() throws {
        var form = docker()
        form.cpus = "8"
        #expect(form.error(for: .cpus) == nil)
        form.cpus = "1,25"
        #expect(try #require(form.dockerUpdate()).nanoCPUs == 1_250_000_000)
    }

    @Test func unknownHostCountSkipsTheMaximum() {
        var form = ContainerResourceForm(original: limited, engine: .docker, hostCPUs: 0)
        form.cpus = "64"
        #expect(form.error(for: .cpus) == nil)
    }

    @Test func dockerCannotRemoveALimit() {
        var form = docker()
        form.memory = ""
        #expect(form.error(for: .memory) != nil)
        form = docker()
        form.cpus = ""
        #expect(form.error(for: .cpus) != nil)
        form = docker()
        form.memorySwap = ""
        #expect(form.error(for: .memorySwap) != nil)
    }

    @Test func swapTakesUnlimited() throws {
        var form = docker()
        form.memorySwap = "unlimited"
        #expect(try #require(form.dockerUpdate()).memorySwap == -1)
        form.memorySwap = "12x"
        #expect(form.error(for: .memorySwap) != nil)
    }

    @Test func leavesCrossFieldChecksToTheDaemon() throws {
        var form = docker()
        form.memorySwap = "32m"
        let update = try #require(form.dockerUpdate())
        #expect(update.memorySwap == 32 << 20)
    }

    @Test func appleShowsOnlyCPUsAndMemory() {
        let form = ContainerResourceForm(
            original: ContainerResources(nanoCPUs: 4_000_000_000, memory: 1 << 30), engine: .apple, hostCPUs: 8
        )
        #expect(form.fields == [.cpus, .memory])
        #expect(form.cpus == "4")
        #expect(form.memory == "1g")
        #expect(!form.hasChanges)
        #expect(form.dockerUpdate() == nil)
    }

    @Test func appleChecksWholeCPUsAndTheMemoryMinimum() {
        var form = ContainerResourceForm(
            original: ContainerResources(nanoCPUs: 4_000_000_000, memory: 1 << 30), engine: .apple, hostCPUs: 8
        )
        form.cpus = "1.5"
        #expect(form.error(for: .cpus) != nil)
        form.cpus = "2"
        form.memory = "100m"
        #expect(form.error(for: .memory) != nil)
        form.memory = ""
        #expect(form.error(for: .memory) != nil)
        form.memory = "512m"
        #expect(form.isValid)
        #expect(form.hasChanges)
    }

    @Test func applePutsTheLimitsIntoTheRecreate() throws {
        var form = ContainerResourceForm(
            original: ContainerResources(nanoCPUs: 4_000_000_000, memory: 1 << 30), engine: .apple, hostCPUs: 8
        )
        form.cpus = "2"
        form.memory = "512m"
        var request = ContainerCreateRequest(image: "nginx", binds: ["/a:/b"])
        form.applyAppleLimits(to: &request)
        #expect(request.hostConfig?.nanoCPUs == 2_000_000_000)
        #expect(request.hostConfig?.memory == 512 << 20)
        #expect(request.hostConfig?.binds == ["/a:/b"])
    }
}

@MainActor
@Suite struct RecreateLimitsTests {
    private func summary() throws -> ContainerSummary {
        let json = #"{"Id":"c1","Names":["/web"],"Image":"nginx","State":"running","Status":"Up","Command":"nginx"}"#
        return try JSONDecoder().decode(ContainerSummary.self, from: Data(json.utf8))
    }

    @Test func recreationKeepsTheLimits() throws {
        let json = #"""
        {"Id":"c1","Name":"/web","Image":"i","State":{"Status":"running","Running":true},
         "HostConfig":{"Memory":268435456,"NanoCpus":2000000000,"RestartPolicy":{"Name":"always"}},
         "Config":{"Image":"nginx"}}
        """#
        let details = try JSONDecoder().decode(ContainerDetails.self, from: Data(json.utf8))
        let session = HostSession(host: DockerHost(name: "Local", kind: .local))
        let request = session.recreationRequest(container: try summary(), details: details)
        #expect(request.hostConfig?.memory == 268_435_456)
        #expect(request.hostConfig?.nanoCPUs == 2_000_000_000)
        #expect(request.hostConfig?.restartPolicy?.name == "always")
    }

    @Test func daemonErrorTextIsTheMessage() {
        let error = DockerError.apiError(status: 400, message: "Minimum memory limit allowed is 6MB")
        #expect(HostSession.resourceErrorText(error) == "Minimum memory limit allowed is 6MB")
        #expect(DestructiveAction.recreateContainer(try! summary()).kind == .recreateContainer)
    }
}
