import Testing
@testable import DockerKit

@Suite("DockerHumanDuration")
struct DockerHumanDurationTests {
    @Test(arguments: [
        (0.4, "Less than a second"),
        (1, "1 second"),
        (59, "59 seconds"),
        (60, "About a minute"),
        (119, "About a minute"),
        (120, "2 minutes"),
        (59 * 60, "59 minutes"),
        (3600, "About an hour"),
        (5399, "About an hour"),
        (5400, "2 hours"),
        (47 * 3600, "47 hours"),
        (48 * 3600, "2 days"),
        (13 * 86400, "13 days"),
        (14 * 86400, "2 weeks"),
        (59 * 86400, "8 weeks"),
        (60 * 86400, "2 months"),
        (729 * 86400, "24 months"),
        (730 * 86400, "2 years"),
    ] as [(Double, String)])
    func wording(seconds: Double, expected: String) {
        #expect(DockerHumanDuration.string(seconds) == expected)
    }
}
