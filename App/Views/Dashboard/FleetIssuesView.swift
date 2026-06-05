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

/// The dashboard's middle column: everything that needs attention across all
/// hosts, grouped by host — or a green all-clear when the fleet is healthy.
struct FleetIssuesView: View {
    @Environment(AppModel.self) private var model
    let navigate: (UUID, HostSection, DetailSelection?) -> Void

    var body: some View {
        Group {
            let groups = issueGroups
            if groups.isEmpty {
                allClear
            } else {
                issuesList(groups)
            }
        }
        .navigationTitle("Health")
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
                    title: "Connection failed",
                    detail: message,
                    section: .overview,
                    target: nil
                )
            )
        }

        for container in session.containers {
            if container.state.isRunning, container.health == .unhealthy {
                result.append(containerIssue(container, severity: .error, title: "Unhealthy"))
            } else if container.state == .restarting {
                result.append(containerIssue(container, severity: .warning, title: "Restarting"))
            } else if container.state == .dead {
                result.append(containerIssue(container, severity: .error, title: "Dead"))
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
        List {
            ForEach(groups, id: \.session.id) { group in
                Section {
                    ForEach(group.issues) { issue in
                        issueRow(issue, session: group.session)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(group.session.status.dotColor)
                            .frame(width: 7, height: 7)
                        Text(group.session.host.name)
                    }
                }
            }
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

    private var allClear: some View {
        let connected = model.sessions.filter(\.status.isConnected).count
        let running = model.sessions.reduce(0) { sum, session in
            sum + session.containers.filter(\.state.isRunning).count
        }
        return ContentUnavailableView {
            Label {
                Text("All Systems Running")
            } icon: {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
        } description: {
            Text("\(running) containers running across \(connected) connected hosts.")
        }
    }
}
