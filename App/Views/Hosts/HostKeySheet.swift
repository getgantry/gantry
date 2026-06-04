import SwiftUI
import AppCore

/// Trust-on-first-use prompt shown when a remote host presents an unknown key.
struct HostKeySheet: View {
    let session: HostSession
    let prompt: HostSession.HostKeyPromptState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "key.horizontal.fill")
                    .font(.title)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Verify Host Key")
                        .font(.title2.weight(.semibold))
                    Text(prompt.host)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Text("The authenticity of host \"\(prompt.host)\" can't be established. Verify the fingerprint below before trusting this server.")
                .font(.callout)

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Key type", value: prompt.keyType)
                    LabeledContent("SHA256") {
                        Text(prompt.fingerprint)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .padding(4)
            }

            Label("Only trust this key if it matches the fingerprint you expect.", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)

            HStack {
                Spacer()
                Button("Reject", role: .cancel) {
                    session.submitHostKeyDecision(trust: false)
                }
                Button("Trust") {
                    session.submitHostKeyDecision(trust: true)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
        .controlSize(.large)
    }
}
