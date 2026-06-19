import Foundation
import Testing
@testable import AppCore

struct CloudflareTunnelTests {
    @Test func quickModeArguments() {
        #expect(
            CloudflareTunnel.arguments(mode: .quick, targetURL: "http://localhost:8080")
                == ["tunnel", "--no-autoupdate", "--url", "http://localhost:8080"]
        )
    }

    @Test func namedModeArguments() {
        #expect(
            CloudflareTunnel.arguments(mode: .named(hostname: "app.example.com"), targetURL: "http://localhost:3000")
                == ["tunnel", "--no-autoupdate", "--hostname", "app.example.com", "--url", "http://localhost:3000"]
        )
    }

    @Test func extractsQuickTunnelURL() {
        let banner = "2024-08-01T10:00:00Z INF |  https://random-words-here.trycloudflare.com  |"
        #expect(
            CloudflareTunnel.extractQuickTunnelURL(from: banner)
                == URL(string: "https://random-words-here.trycloudflare.com")
        )
    }

    @Test func ignoresNonURLLines() {
        #expect(CloudflareTunnel.extractQuickTunnelURL(from: "INF Starting tunnel") == nil)
        #expect(CloudflareTunnel.extractQuickTunnelURL(from: "https://example.com") == nil)
    }

    @Test func detectsNamedTunnelReadiness() {
        #expect(CloudflareTunnel.indicatesNamedTunnelReady("INF Registered tunnel connection connIndex=0"))
        #expect(CloudflareTunnel.indicatesNamedTunnelReady("connection registered"))
        #expect(!CloudflareTunnel.indicatesNamedTunnelReady("INF Starting tunnel"))
    }

    @Test func publicURLOnlyWhenActive() {
        let url = URL(string: "https://x.trycloudflare.com")!
        var tunnel = CloudflareTunnel(containerID: "c1", label: "web", port: 80, mode: .quick)
        #expect(tunnel.publicURL == nil)
        tunnel.status = .active(url: url)
        #expect(tunnel.publicURL == url)
        tunnel.status = .failed("boom")
        #expect(tunnel.publicURL == nil)
    }
}

struct CloudflaredToolingTests {
    @Test func parsesVersion() {
        #expect(CloudflaredTooling.parseVersion("cloudflared version 2024.8.3 (built 2024-08-01)") == "2024.8.3")
        #expect(CloudflaredTooling.parseVersion("no version") == nil)
    }

    @Test func statusInstalledFlag() {
        #expect(CloudflaredTooling.Status(state: .ok(version: "2024.8.3"), brewAvailable: true, loggedIn: false).isInstalled)
        #expect(!CloudflaredTooling.Status(state: .notInstalled, brewAvailable: true, loggedIn: false).isInstalled)
    }
}
