import SwiftUI
import AppCore
import DockerKit

/// One problem somewhere in the fleet: a failed host connection or a
/// container in a bad state. Rows navigate straight to the culprit.
private struct FleetIssue: Identifiable {
    enum Severity {
        case error
        case warning

        var systemImage: String {
            switch self {
            case .error: "exclamationmark.octagon.fill"
            case .warning: "exclamationmark.triangle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .error: .red
            case .warning: .orange
            }
        }
    }

    let id: String
    let severity: Severity
    let title: String
    let detail: String
    /// Where the row navigates: the host's section and optional detail item.
    let section: HostSection
    let target: DetailSelection?
}

/// The dashboard's issue card: everything that needs attention across all
/// hosts, grouped by host. Empty when the fleet is healthy (the banner above
/// already says so).
struct FleetIssuesView: View {
    @Environment(AppModel.self) private var model
    let navigate: (UUID, HostSection, DetailSelection?) -> Void

    var body: some View {
        let groups = issueGroups
        if !groups.isEmpty {
            issuesList(groups)
        }
    }

    // MARK: Issue discovery

    /// Issues grouped per host, in sidebar order; hosts without issues are
    /// omitted entirely.
    private var issueGroups: [(session: HostSession, issues: [FleetIssue])] {
        model.sessions.compactMap { session in
            let issues = issues(for: session)
            return issues.isEmpty ? nil : (session, issues)
        }
    }

    private func issues(for session: HostSession) -> [FleetIssue] {
        var result: [FleetIssue] = []

        if case .failed(let message) = session.status {
            result.append(
                FleetIssue(
                    id: "host-\(session.id)",
                    severity: .error,
                    title: String(localized: "Connection failed"),
                    detail: message,
                    section: .overview,
                    target: nil
                )
            )
        }

        for container in session.visibleContainers {
            if container.state.isRunning, container.health == .unhealthy {
                result.append(containerIssue(container, severity: .error, title: String(localized: "Unhealthy")))
            } else if container.state == .restarting {
                result.append(containerIssue(container, severity: .warning, title: String(localized: "Restarting")))
            } else if container.state == .dead {
                result.append(containerIssue(container, severity: .error, title: String(localized: "Dead")))
            }
        }

        return result
    }

    private func containerIssue(
        _ container: ContainerSummary,
        severity: FleetIssue.Severity,
        title: String
    ) -> FleetIssue {
        FleetIssue(
            id: "container-\(container.id)",
            severity: severity,
            title: container.displayName,
            detail: "\(title) · \(container.status)",
            section: .containers,
            target: .container(container.id)
        )
    }

    // MARK: Views

    private func issuesList(_ groups: [(session: HostSession, issues: [FleetIssue])]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Needs Attention", systemImage: "exclamationmark.triangle")
                .font(.headline)
            ForEach(groups, id: \.session.id) { group in
                VStack(alignment: .leading, spacing: 4) {
                    groupHeader(group.session)
                    ForEach(group.issues) { issue in
                        issueRow(issue, session: group.session)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func groupHeader(_ session: HostSession) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(session.status.dotColor)
                .frame(width: 7, height: 7)
            Text(session.host.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func issueRow(_ issue: FleetIssue, session: HostSession) -> some View {
        Button {
            navigate(session.host.id, issue.section, issue.target)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: issue.severity.systemImage)
                    .foregroundStyle(issue.severity.tint)
                    .font(.callout)
                VStack(alignment: .leading, spacing: 1) {
                    Text(issue.title)
                        .font(.body)
                        .lineLimit(1)
                    Text(issue.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .help("Show in \(issue.section.title)")
        .contextMenu {
            // Hand the broken container to an AI agent: copies a paste-ready
            // debugging prompt with host + container context.
            if case .container(let containerID) = issue.target,
               let container = session.containers.first(where: { $0.id == containerID }) {
                Button {
                    ContainerPromptCopy.run(session: session, container: container)
                } label: {
                    Label("Copy as Prompt", systemImage: "text.badge.star")
                }
            }
        }
    }
}
