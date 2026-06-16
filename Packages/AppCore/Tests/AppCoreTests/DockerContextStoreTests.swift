import Foundation
import Testing
@testable import AppCore

@Suite("Docker context import")
struct DockerContextStoreTests {
    @Test func parsesSSHEndpoint() {
        let e = DockerContextStore.endpoint(for: "ssh://deploy@server.example.com:2222")
        #expect(e == .ssh(host: "server.example.com", port: 2222, user: "deploy"))
    }

    @Test func sshEndpointDefaultsPortAndUser() {
        let e = DockerContextStore.endpoint(for: "ssh://box.local")
        #expect(e == .ssh(host: "box.local", port: 22, user: ""))
    }

    @Test func parsesUnixAndUnsupported() {
        #expect(DockerContextStore.endpoint(for: "unix:///var/run/docker.sock") == .unixSocket("/var/run/docker.sock"))
        if case .unsupported = DockerContextStore.endpoint(for: "tcp://1.2.3.4:2376") {} else {
            Issue.record("tcp:// should be unsupported")
        }
    }

    @Test func listsContextsSkippingDefaultAndHostless() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("meta")
        func writeMeta(_ folder: String, _ json: String) throws {
            let dir = base.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try json.write(to: dir.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
        }
        try writeMeta("a", #"{"Name":"prod","Endpoints":{"docker":{"Host":"ssh://u@h:22"}}}"#)
        try writeMeta("b", #"{"Name":"default","Endpoints":{"docker":{"Host":"unix:///x"}}}"#)
        try writeMeta("c", #"{"Name":"empty","Endpoints":{"docker":{"Host":""}}}"#)

        let entries = DockerContextStore.list(contextsDirectory: base)
        #expect(entries == [DockerContextStore.Entry(name: "prod", host: "ssh://u@h:22")])
    }

    @Test func missingDirectoryYieldsEmpty() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(DockerContextStore.list(contextsDirectory: base).isEmpty)
    }
}
