import Foundation
import Testing
@testable import AppCore
@testable import DockerKit

@Suite struct ShellWordsTests {
    @Test func splitsOnWhitespace() throws {
        #expect(try ShellWords.split("nginx  -g\tfoo\nbar") == ["nginx", "-g", "foo", "bar"])
        #expect(try ShellWords.split("") == [])
        #expect(try ShellWords.split("   ") == [])
    }

    @Test func singleQuotesKeepEverythingLiteral() throws {
        #expect(try ShellWords.split("nginx -g 'daemon off;'") == ["nginx", "-g", "daemon off;"])
        #expect(try ShellWords.split(#"echo 'a\b "c" $HOME'"#) == ["echo", #"a\b "c" $HOME"#])
    }

    @Test func doubleQuotesHonourOnlyShellEscapes() throws {
        #expect(try ShellWords.split(#"sh -c "echo \"hi\" && ls""#) == ["sh", "-c", #"echo "hi" && ls"#])
        #expect(try ShellWords.split(#""a\nb""#) == [#"a\nb"#])
        #expect(try ShellWords.split(#""\\ \$ \`""#) == [#"\ $ `"#])
    }

    @Test func backslashEscapesOutsideQuotes() throws {
        #expect(try ShellWords.split(#"a\ b c"#) == ["a b", "c"])
        #expect(try ShellWords.split("a\\\nb") == ["ab"])
        #expect(try ShellWords.split(#"\'x"#) == ["'x"])
    }

    @Test func quotesJoinAdjacentText() throws {
        #expect(try ShellWords.split(#"--name="my app"x"#) == ["--name=my appx"])
        #expect(try ShellWords.split("a'b'\"c\"") == ["abc"])
    }

    @Test func emptyQuotesGiveEmptyWords() throws {
        #expect(try ShellWords.split("printf '' \"\"") == ["printf", "", ""])
    }

    @Test func malformedInputThrows() {
        #expect(throws: ShellWords.ParseError.unterminatedSingleQuote) { try ShellWords.split("echo 'oops") }
        #expect(throws: ShellWords.ParseError.unterminatedDoubleQuote) { try ShellWords.split("echo \"oops") }
        #expect(throws: ShellWords.ParseError.trailingBackslash) { try ShellWords.split("echo \\") }
    }
}

@Suite struct PortValidationTests {
    private typealias Entry = ContainerForm.PortEntry

    @Test func duplicateContainerPortIsReportedNotTrapped() {
        let rows = [Entry(host: "8080", container: "80"), Entry(host: "8081", container: "80")]
        #expect(ContainerForm.portIssues(rows) == [1: .duplicateContainerPort])
        // Building the map must not crash; the first row wins.
        #expect(ContainerForm.portMap(rows) == ["80/tcp": "8080"])
    }

    @Test func sameContainerPortOnTwoProtocolsIsFine() {
        let rows = [Entry(host: "53", container: "53", proto: "tcp"), Entry(host: "53", container: "53", proto: "udp")]
        #expect(ContainerForm.portIssues(rows).isEmpty)
        #expect(ContainerForm.portMap(rows) == ["53/tcp": "53", "53/udp": "53"])
    }

    @Test func invalidPortsAreReported() {
        let rows = [
            Entry(host: "8080", container: "http"),
            Entry(host: "99999", container: "81"),
            Entry(host: "", container: "0"),
        ]
        #expect(ContainerForm.portIssues(rows) == [
            0: .invalidContainerPort, 1: .invalidHostPort, 2: .invalidContainerPort,
        ])
    }

    @Test func emptyRowsAreSkipped() {
        let rows = [Entry(host: "", container: ""), Entry(host: "8080", container: " ")]
        #expect(ContainerForm.portIssues(rows).isEmpty)
        #expect(ContainerForm.portMap(rows).isEmpty)
    }

    @Test func emptyHostPortPublishesOnARandomPort() {
        let rows = [Entry(host: "", container: "80")]
        #expect(ContainerForm.portMap(rows) == ["80/tcp": ""])
    }

    @Test func quickRunDropsRowsWithoutHostPort() {
        let rows = [Entry(host: "", container: "80"), Entry(host: "8080", container: "80")]
        #expect(ContainerForm.portIssues(rows, requireHost: true).isEmpty)
        #expect(ContainerForm.portMap(rows, requireHost: true) == ["80/tcp": "8080"])
    }
}

@Suite struct ContainerNameTests {
    @Test func baseNameComesFromTheRepository() {
        #expect(ContainerForm.baseName(forImage: "nginx") == "nginx")
        #expect(ContainerForm.baseName(forImage: "nginx:alpine") == "nginx")
        #expect(ContainerForm.baseName(forImage: "docker.io/library/redis:7") == "redis")
        #expect(ContainerForm.baseName(forImage: "localhost:5000/team/api:1.2") == "api")
        #expect(ContainerForm.baseName(forImage: "ghcr.io/x/app@sha256:abc") == "app")
        #expect(ContainerForm.baseName(forImage: "  ") == "")
        #expect(ContainerForm.baseName(forImage: "_odd+name") == "odd-name")
    }

    @Test func uniqueNameAddsTheFirstFreeSuffix() {
        #expect(ContainerForm.uniqueName(base: "nginx", taken: []) == "nginx")
        #expect(ContainerForm.uniqueName(base: "nginx", taken: ["nginx"]) == "nginx-2")
        #expect(ContainerForm.uniqueName(base: "nginx", taken: ["nginx", "nginx-2", "nginx-3"]) == "nginx-4")
    }

    @Test func takenNamesDropTheLeadingSlash() throws {
        let json = #"[{"Id":"1","Names":["/web"]},{"Id":"2","Names":["db"]}]"#
        let containers = try JSONDecoder().decode([ContainerSummary].self, from: Data(json.utf8))
        #expect(ContainerForm.takenNames(containers) == ["web", "db"])
    }

    @Test func nameIssues() {
        #expect(ContainerForm.nameIssue("", taken: ["web"]) == nil)
        #expect(ContainerForm.nameIssue("api", taken: ["web"]) == nil)
        #expect(ContainerForm.nameIssue(" web ", taken: ["web"]) == ContainerForm.nameInUseMessage("web"))
        #expect(ContainerForm.nameIssue("-web", taken: []) != nil)
        #expect(ContainerForm.nameIssue("my app", taken: []) != nil)
    }

    @Test func renameNeedsAValidChangedName() {
        #expect(ContainerForm.isValidRename("api", current: "web"))
        #expect(!ContainerForm.isValidRename("", current: "web"))
        #expect(!ContainerForm.isValidRename("   ", current: "web"))
        #expect(!ContainerForm.isValidRename(" web ", current: "web"))
        #expect(!ContainerForm.isValidRename("bad name", current: "web"))
    }

    @Test func nameConflictIsRecognised() {
        #expect(ContainerForm.isNameConflict(DockerError.apiError(
            status: 409,
            message: "Conflict. The container name \"/web\" is already in use by container \"abc\"."
        )))
        #expect(ContainerForm.isNameConflict(DockerError.apiError(status: 500, message: "container web already exists")))
        #expect(!ContainerForm.isNameConflict(DockerError.apiError(status: 404, message: "No such image: nginx")))
    }

    @MainActor
    @Test func sessionSuggestionIsUnique() throws {
        let session = HostSession(host: DockerHost(name: "Local", kind: .local))
        #expect(session.uniqueContainerName(forImage: "docker.io/library/nginx:alpine") == "nginx")
        #expect(session.uniqueContainerName(forImage: "") == "app")
    }
}

@Suite struct BuilderContainerTests {
    private func summary(_ json: String) throws -> ContainerSummary {
        try JSONDecoder().decode(ContainerSummary.self, from: Data(json.utf8))
    }

    @Test func recognisesTheAppleBuilder() throws {
        let builder = try summary(#"""
        {"Id":"buildkit","Names":["buildkit"],"Image":"ghcr.io/apple/container-builder-shim/builder:0.13.2",
         "Labels":{"com.apple.container.plugin":"builder","com.apple.container.resource.role":"builder"}}
        """#)
        #expect(AppleBuilderStatus.isBuilderContainer(builder))
        let unlabeled = try summary(#"{"Id":"buildkit","Names":["buildkit"],"Image":"ghcr.io/apple/container-builder-shim/builder:0.12"}"#)
        #expect(AppleBuilderStatus.isBuilderContainer(unlabeled))
    }

    @Test func userContainerNamedBuildkitIsKept() throws {
        let mine = try summary(#"{"Id":"x","Names":["/buildkit"],"Image":"moby/buildkit:latest"}"#)
        #expect(!AppleBuilderStatus.isBuilderContainer(mine))
    }
}

@Suite struct PauseBufferTests {
    @Test func holdsAndDrainsInOrder() {
        var buffer = PauseBuffer<Int>(capacity: 10)
        for value in 1...3 { buffer.hold(value) }
        #expect(buffer.count == 3)
        #expect(buffer.drain() == [1, 2, 3])
        #expect(buffer.count == 0)
    }

    @Test func dropsOldestPastCapacity() {
        var buffer = PauseBuffer<Int>(capacity: 2)
        for value in 1...5 { buffer.hold(value) }
        #expect(buffer.held == [4, 5])
        #expect(buffer.dropped == 3)
        buffer.reset()
        #expect(buffer.dropped == 0)
    }
}

@Suite struct MachineAvailabilityTests {
    @Test func homebrewPathsAreRecognised() {
        #expect(MachineAvailability.isHomebrewCLI(path: "/opt/homebrew/bin/container"))
        #expect(MachineAvailability.isHomebrewCLI(path: "/usr/local/Cellar/container/1.6.1/bin/container"))
        #expect(!MachineAvailability.isHomebrewCLI(path: "/usr/local/bin/container-gantry-fix-missing"))
    }
}
