import SwiftUI
import DockerKit
import AppCore

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings()
            }
            Tab("About", systemImage: "info.circle") {
                AboutSettings()
            }
        }
        .frame(width: 520, height: 420)
    }
}

private struct GeneralSettings: View {
    @AppStorage("socketPathOverride") private var socketPathOverride = ""
    @AppStorage("refreshInterval") private var refreshInterval = 5.0

    private let candidates = DockerSocketDiscovery.allCandidates()

    var body: some View {
        Form {
            Section {
                TextField("Socket Path", text: $socketPathOverride, prompt: Text("Auto-detect"))
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("Local Docker Socket")
            } footer: {
                Text("Override the unix socket path for the local host. Leave empty to auto-detect. The effective override is stored on the host configuration.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Discovered Sockets") {
                ForEach(candidates, id: \.self) { path in
                    HStack {
                        Image(systemName: exists(path) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(exists(path) ? .green : .secondary)
                        Text(path)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                    }
                }
            }

            Section {
                Slider(value: $refreshInterval, in: 2...30, step: 1) {
                    Text("Refresh Interval")
                } minimumValueLabel: {
                    Text("2s")
                } maximumValueLabel: {
                    Text("30s")
                }
                Text("Auto-refresh every \(Int(refreshInterval)) seconds (applies once live polling lands in M2).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Refresh")
            }
        }
        .formStyle(.grouped)
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

private struct AboutSettings: View {
    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Gantry")
                .font(.largeTitle.weight(.bold))
            Text("Version \(version)")
                .foregroundStyle(.secondary)
            Text("A native macOS Docker management app.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Link("github.com/andrewkomkov/gantry",
                 destination: URL(string: "https://github.com/andrewkomkov/gantry")!)
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
    }
}
