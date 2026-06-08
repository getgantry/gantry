import Testing
import Foundation
import Darwin
@testable import AppCore

@Suite struct PortForwardingTests {
    @Test func freePortIsActuallyBindable() {
        let port = LocalPort.free()
        #expect(port != nil)
        if let port {
            #expect(port > 0 && port <= 65535)
            // A kernel-assigned free port must itself be available.
            #expect(LocalPort.isAvailable(port))
        }
    }

    @Test func preferredFreePortIsHonored() {
        // Pick a port the kernel just told us is free, then ask for it by name.
        guard let preferred = LocalPort.free() else {
            Issue.record("no free port available")
            return
        }
        #expect(LocalPort.free(preferring: preferred) == preferred)
    }

    @Test func busyPortIsNotAvailableAndFallsBack() throws {
        // Occupy a loopback port, then confirm detection + fallback.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(bound == 0)
        var got = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &got) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        listen(fd, 1)
        let busy = Int(UInt16(bigEndian: got.sin_port))

        #expect(!LocalPort.isAvailable(busy))
        // Preferring a busy port returns some other, free port.
        let fallback = LocalPort.free(preferring: busy)
        #expect(fallback != nil)
        #expect(fallback != busy)
    }

    @Test func forwardLocalURL() {
        let forward = PortForward(
            containerID: "abc",
            label: "web",
            localPort: 8080,
            remoteHost: "127.0.0.1",
            remotePort: 80
        )
        #expect(forward.localURL?.absoluteString == "http://localhost:8080")
        #expect(forward.status == .starting)
    }
}
