import Foundation
import DockerKit

/// Container state totals for one host or the whole fleet. Every count in the
/// app (overview tiles, dashboard, menu bar) comes from here, so the numbers
/// agree on one screen.
public struct ContainerCounts: Equatable, Sendable {
    public var running = 0
    public var paused = 0
    /// Every container that is not running or paused (exited, created, dead,
    /// restarting, removing, unknown).
    public var stopped = 0
    /// Running containers whose health check fails.
    public var unhealthy = 0
    public var restarting = 0
    public var dead = 0

    public init() {}

    /// Counts the containers that the user sees. The apple BuildKit builder and
    /// Gantry's debug sidecars are plumbing and never count.
    public init<S: Sequence>(_ containers: S) where S.Element == ContainerSummary {
        for container in containers where Self.isUserVisible(container) {
            add(container)
        }
    }

    public var total: Int { running + paused + stopped }

    /// Containers that need attention: unhealthy, restarting or dead.
    public var attention: Int { unhealthy + restarting + dead }

    /// Running containers whose health is not failing.
    public var healthy: Int { running - unhealthy }

    public static func + (lhs: ContainerCounts, rhs: ContainerCounts) -> ContainerCounts {
        var sum = lhs
        sum.running += rhs.running
        sum.paused += rhs.paused
        sum.stopped += rhs.stopped
        sum.unhealthy += rhs.unhealthy
        sum.restarting += rhs.restarting
        sum.dead += rhs.dead
        return sum
    }

    /// False for containers that the lists hide: the apple BuildKit builder and
    /// Gantry's debug sidecars.
    public static func isUserVisible(_ container: ContainerSummary) -> Bool {
        !DebugShell.isSidecar(container) && !AppleBuilderStatus.isBuilderContainer(container)
    }

    private mutating func add(_ container: ContainerSummary) {
        switch container.state {
        case .running:
            running += 1
            if container.status.lowercased().contains("(unhealthy)") { unhealthy += 1 }
        case .paused:
            paused += 1
        case .restarting:
            restarting += 1
            stopped += 1
        case .dead:
            dead += 1
            stopped += 1
        case .exited, .created, .removing, .unknown:
            stopped += 1
        }
    }
}

extension HostSession {
    /// The containers that the lists show: no builder, no debug sidecars.
    public var visibleContainers: [ContainerSummary] {
        containers.filter(ContainerCounts.isUserVisible)
    }

    /// State totals of `visibleContainers`.
    public var containerCounts: ContainerCounts { ContainerCounts(containers) }
}

/// Count phrases with plural rules from the String Catalog ("1 container",
/// "2 containers"). The locale parameter exists for tests.
public enum CountPhrases {
    public static func containers(_ count: Int, locale: Locale = .current) -> String {
        String(localized: "\(count) containers", bundle: .module, locale: locale)
    }

    public static func hosts(_ count: Int, locale: Locale = .current) -> String {
        String(localized: "\(count) hosts", bundle: .module, locale: locale)
    }

    public static func services(_ count: Int, locale: Locale = .current) -> String {
        String(localized: "\(count) services", bundle: .module, locale: locale)
    }

    /// "3 containers running across 2 hosts."
    public static func runningAcrossHosts(running: Int, hosts: Int, locale: Locale = .current) -> String {
        String(localized: "\(running) containers running across \(hosts) hosts.", bundle: .module, locale: locale)
    }

    /// "3 running · 2 hosts", the menu bar footer.
    public static func runningOnHosts(running: Int, hosts: Int, locale: Locale = .current) -> String {
        String(localized: "\(running) running · \(hosts) hosts", bundle: .module, locale: locale)
    }
}
