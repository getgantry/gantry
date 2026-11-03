import Foundation
import Testing
@testable import AppCore

@Suite struct MachineRemoteEditorTests {
    @Test func hostDropsPrefixLength() {
        let machine = ContainerMachine(id: "ubuntu", status: "running", ipAddress: "192.168.71.15/24")
        #expect(MachineRemoteEditor.sshHost(for: machine) == "192.168.71.15")
        #expect(MachineRemoteEditor.sshHost(for: ContainerMachine(id: "x", status: "stopped", ipAddress: "")) == nil)
    }

    @Test func vscodeURLTargetsRemoteFolder() {
        let url = MachineRemoteEditor.vscodeURL(host: "192.168.71.15", user: "john", folder: "/Users/john/src")
        #expect(url?.absoluteString == "vscode://vscode-remote/ssh-remote+john@192.168.71.15/Users/john/src")
    }
}
