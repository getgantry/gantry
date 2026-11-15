import SwiftUI
import AppCore

/// The findings of a scan in severity sections, with a filter.
struct ScanFindingsView: View {
    let report: ScanReport

    @State private var filter = ""

    var body: some View {
        if report.total == 0 {
            ContentUnavailableView(
                "No Vulnerabilities Found",
                systemImage: "checkmark.shield",
                description: Text("\(report.scanner.displayName) found no known vulnerabilities in this image.")
            )
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SeveritySummary(report: report)
                    Spacer()
                    TextField("Filter by package or ID", text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                }
                FindingsList(groups: filteredGroups)
            }
        }
    }

    private var filteredGroups: [ScanReport.Group] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return report.groups }
        return report.groups.compactMap { group in
            let kept = group.findings.filter {
                $0.packageName.lowercased().contains(needle) || $0.vulnerabilityID.lowercased().contains(needle)
            }
            return kept.isEmpty ? nil : ScanReport.Group(severity: group.severity, findings: kept)
        }
    }
}

/// One badge per severity that has findings.
private struct SeveritySummary: View {
    let report: ScanReport

    var body: some View {
        HStack(spacing: 6) {
            ForEach(report.groups) { group in
                SeverityBadge(severity: group.severity, count: group.findings.count)
            }
        }
    }
}

struct SeverityBadge: View {
    let severity: VulnerabilitySeverity
    let count: Int

    var body: some View {
        Label {
            Text(verbatim: "\(severity.localizedName) \(count)")
        } icon: {
            Image(systemName: severity.symbolName)
                .foregroundStyle(severity.tint)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(severity.tint.opacity(0.12), in: Capsule())
    }
}

private struct FindingsList: View {
    let groups: [ScanReport.Group]

    var body: some View {
        List {
            ForEach(groups) { group in
                Section {
                    ForEach(group.findings) { finding in
                        FindingRow(finding: finding)
                    }
                } header: {
                    Label {
                        Text(verbatim: "\(group.severity.localizedName) (\(group.findings.count))")
                    } icon: {
                        Image(systemName: group.severity.symbolName)
                            .foregroundStyle(group.severity.tint)
                    }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if groups.isEmpty {
                ContentUnavailableView.search
            }
        }
    }
}

private struct FindingRow: View {
    let finding: VulnerabilityFinding

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                if let url = finding.url {
                    Link(finding.vulnerabilityID, destination: url)
                        .font(.callout.monospaced().weight(.semibold))
                        .help(url.absoluteString)
                } else {
                    Text(finding.vulnerabilityID)
                        .font(.callout.monospaced().weight(.semibold))
                        .textSelection(.enabled)
                }
                Spacer()
                Text(finding.severity.localizedName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !finding.title.isEmpty {
                Text(finding.title)
                    .font(.callout)
                    .lineLimit(2)
            }
            FindingVersions(finding: finding)
        }
        .padding(.vertical, 2)
    }
}

private struct FindingVersions: View {
    let finding: VulnerabilityFinding

    var body: some View {
        HStack(spacing: 14) {
            Text("Package: \(finding.packageName)")
            Text("Installed: \(finding.installedVersion)")
            Text("Fixed: \(finding.fixedDisplay)")
        }
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
    }
}

extension VulnerabilitySeverity {
    /// A symbol per severity, so the level never shows by color only.
    var symbolName: String {
        switch self {
        case .critical: "exclamationmark.octagon.fill"
        case .high: "exclamationmark.triangle.fill"
        case .medium: "exclamationmark.circle.fill"
        case .low: "info.circle.fill"
        case .negligible: "minus.circle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .critical: .red
        case .high: .orange
        case .medium: .yellow
        case .low: .blue
        case .negligible, .unknown: .secondary
        }
    }
}
