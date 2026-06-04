import SwiftUI
import AppCore

/// Prompts for an SSH password or private-key passphrase during connection.
struct CredentialSheet: View {
    let session: HostSession
    let request: HostSession.CredentialRequest

    @State private var secret = ""
    @State private var storeInKeychain = true

    private var isPassphrase: Bool {
        if case .keyPassphrase = request.kind { return true }
        return false
    }

    private var title: String {
        isPassphrase ? "Key Passphrase" : "SSH Password"
    }

    private var fieldLabel: String {
        isPassphrase ? "Passphrase" : "Password"
    }

    private var subtitle: String {
        switch request.kind {
        case .password:
            return "Enter the password for \(request.hostName)."
        case .keyPassphrase(let file):
            return "Unlock \((file as NSString).lastPathComponent) for \(request.hostName)."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.title2.weight(.semibold))
            }

            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)

            SecureField(fieldLabel, text: $secret)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)

            Toggle("Save in Keychain", isOn: $storeInKeychain)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    session.cancelCredential()
                }
                Button("Connect", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(secret.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .controlSize(.large)
    }

    private func submit() {
        guard !secret.isEmpty else { return }
        session.submitCredential(secret, store: storeInKeychain)
    }
}
