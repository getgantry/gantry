import SwiftUI
import AppCore

/// The parts of an apple/container installation that the System section of
/// an apple host manages.
enum AppleSystemPane: String, CaseIterable, Identifiable {
    case overview
    case builder
    case registries
    case kernel
    case logs
    case properties

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: String(localized: "Status & Version")
        case .builder: String(localized: "Image Builder")
        case .registries: String(localized: "Registry Logins")
        case .kernel: String(localized: "Kernel")
        case .logs: String(localized: "Service Logs")
        case .properties: String(localized: "System Properties")
        }
    }

    var subtitle: String {
        switch self {
        case .overview: String(localized: "Services, versions, paths and resources")
        case .builder: String(localized: "The BuildKit container for image builds")
        case .registries: String(localized: "Credentials for pushing and pulling")
        case .kernel: String(localized: "The Linux kernel that containers boot")
        case .logs: String(localized: "Logs of the container services")
        case .properties: String(localized: "Defaults from config.toml")
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "info.circle"
        case .builder: "hammer"
        case .registries: "person.badge.key"
        case .kernel: "cpu"
        case .logs: "text.alignleft"
        case .properties: "slider.horizontal.3"
        }
    }
}

/// The System section: a pane switcher over the selected pane, full width
/// next to the sidebar.
struct AppleSystemView: View {
    let session: HostSession
    @Binding var selection: String?

    private var pane: AppleSystemPane {
        selection.flatMap(AppleSystemPane.init(rawValue:)) ?? .overview
    }

    var body: some View {
        VStack(spacing: 0) {
            paneSwitcher
            Divider()
            AppleSystemDetailView(paneID: pane.rawValue, session: session)
        }
        .navigationTitle(String(localized: "System"))
    }

    private var paneSwitcher: some View {
        Picker(String(localized: "Pane"), selection: Binding(
            get: { pane },
            set: { selection = $0.rawValue }
        )) {
            ForEach(AppleSystemPane.allCases) { pane in
                Label(pane.title, systemImage: pane.systemImage).tag(pane)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

/// The selected pane of the System section.
struct AppleSystemDetailView: View {
    let paneID: String
    let session: HostSession

    var body: some View {
        Group {
            switch AppleSystemPane(rawValue: paneID) {
            case .overview: AppleSystemOverviewPane(session: session)
            case .builder: AppleBuilderPane(session: session)
            case .registries: AppleRegistriesPane(session: session)
            case .kernel: AppleKernelPane(session: session)
            case .logs: AppleSystemLogsPane(session: session)
            case .properties: AppleSystemPropertiesPane(session: session)
            case nil:
                ContentUnavailableView(
                    String(localized: "Nothing Selected"),
                    systemImage: "rectangle.righthalf.inset.filled"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension HostSession {
    /// The `container` CLI path override of an apple host (stored in the
    /// socket-path field), or nil to discover the CLI.
    var appleCLIOverride: String? {
        guard host.isAppleContainer else { return nil }
        let path = host.socketPathOverride?.trimmingCharacters(in: .whitespaces) ?? ""
        return path.isEmpty ? nil : path
    }
}

/// The header row of a System pane: icon, title, an optional badge and the
/// pane's actions.
struct AppleSystemPaneHeader<Actions: View>: View {
    let pane: AppleSystemPane
    var badge: (text: String, tint: Color)?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: pane.systemImage)
                .font(.largeTitle)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(pane.title)
                        .font(.largeTitle.weight(.bold))
                        .lineLimit(1)
                    if let badge { BadgePill(text: badge.text, tint: badge.tint) }
                }
                Text(pane.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            actions
        }
        .padding([.horizontal, .top])
        .padding(.bottom, 8)
    }
}

/// A red message strip for a failed operation.
struct AppleSystemErrorBanner: View {
    let message: String
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Dismiss"))
            }
        }
        .padding(10)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// A rounded card like the ones on the host overview.
struct AppleSystemCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
