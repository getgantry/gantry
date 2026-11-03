import SwiftUI
import AppCore

/// The System block of the Apple settings tab: CLI and server versions and
/// the default kernel, with the kernel fix close at hand. The full tools are
/// in the System section of an apple host.
struct AppleSystemSettingsSection: View {
    let cliOverride: String?

    @State private var versions: [AppleComponentVersion] = []
    @State private var kernel: AppleKernelInfo?
    @State private var installing = false

    var body: some View {
        Section {
            LabeledContent(String(localized: "CLI")) {
                Text(verbatim: version(of: "container") ?? "—").monospacedDigit()
            }
            LabeledContent(String(localized: "API server")) {
                Text(verbatim: versions.first { $0.appName != "container" }?.version ?? String(localized: "Not running"))
                    .monospacedDigit()
            }
            LabeledContent(String(localized: "Default kernel")) {
                HStack(spacing: 8) {
                    if let kernel {
                        Text(verbatim: kernel.kernelFile ?? String(localized: "Not installed"))
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(kernel.isInstalled ? Color.secondary : Color.orange)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Button(kernel?.isInstalled == false
                           ? String(localized: "Install Recommended Kernel")
                           : String(localized: "Reinstall…")) {
                        installing = true
                    }
                    .controlSize(.small)
                }
            }
        } header: {
            Text("System")
        } footer: {
            Text("The builder, registry logins, service logs and system properties are in the System section of the apple/container host in the sidebar.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .task { await reload() }
        .sheet(isPresented: $installing, onDismiss: { Task { await reload() } }) {
            AppleKernelInstallSheet(cliOverride: cliOverride, request: .recommended)
        }
    }

    private func version(of app: String) -> String? {
        versions.first { $0.appName == app }?.version
    }

    private func reload() async {
        versions = (try? await AppleContainerControl.systemVersions(cliOverride: cliOverride)) ?? []
        let status = try? await AppleContainerControl.systemStatus(cliOverride: cliOverride)
        let root = status?.appRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
        kernel = AppleContainerControl.defaultKernel(appRoot: root, architecture: hostKernelArchitecture)
    }
}
