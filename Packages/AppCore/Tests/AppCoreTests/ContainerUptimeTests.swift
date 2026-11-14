import Foundation
import Testing
@testable import AppCore

@Suite("ContainerUptime")
struct ContainerUptimeTests {
    // Status strings as Docker Engine 27 and the apple/container transport write them.
    @Test(arguments: [
        ("Up Less than a second", 0.0),
        ("Up 1 second", 1),
        ("Up 42 seconds", 42),
        ("Up About a minute", 60),
        ("Up 5 minutes", 300),
        ("Up About an hour", 3600),
        ("Up 3 hours", 10_800),
        ("Up 3 hours (healthy)", 10_800),
        ("Up 2 minutes (health: starting)", 120),
        ("Up 4 days (unhealthy)", 345_600),
        ("Up 2 weeks (Paused)", 1_209_600),
        ("Up 3 months", 7_776_000),
        ("Up 2 years", 63_072_000),
    ] as [(String, Double)])
    func parsesDockerStatus(status: String, expected: Double) {
        #expect(ContainerUptime.seconds(fromStatus: status) == expected)
    }

    @Test(arguments: ["Up", "", "Created", "Exited (0) 2 hours ago", "Restarting (1) 5 seconds ago", "Up soon"])
    func noUptime(status: String) {
        #expect(ContainerUptime.seconds(fromStatus: status) == nil)
    }
}
