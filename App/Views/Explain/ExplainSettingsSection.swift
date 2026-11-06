import SwiftUI
import AppCore

/// Settings for "Explain this failure", shown in the Agents pane.
struct ExplainSettingsSection: View {
    @AppStorage(ExplainSettings.enabledKey) private var enabled = true
    @AppStorage(ExplainSettings.privateCloudKey) private var privateCloud = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(String(localized: "Explain Failures"), systemImage: "apple.intelligence")
                .font(.headline)
            Text("Gantry can explain why a container or a build failed with Apple Intelligence. It sends recent logs and container details to the model. Environment values and secret-like text are hidden first.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(String(localized: "Show Explain for failed containers and builds"), isOn: $enabled)
            if FoundationModelsAvailability.privateCloudSupported {
                privateCloudToggle
            }
            Text(ExplainTexts.status(ExplainFactory.availability()))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var privateCloudToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(String(localized: "Use Private Cloud Compute for long logs"), isOn: $privateCloud)
                .disabled(!enabled)
            Text("The larger model can read more log lines. With this setting on, the redacted context leaves this Mac and goes to Apple Private Cloud Compute. With it off, everything stays on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
