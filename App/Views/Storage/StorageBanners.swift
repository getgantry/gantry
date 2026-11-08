import SwiftUI
import AppKit
import AppCore
import DockerKit

/// An orange strip that names a disk that is not connected.
struct StorageBannerContent: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "externaldrive.trianglebadge.exclamationmark")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.orange.opacity(0.35)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Disk warning: \(message)"))
    }
}

/// Shown on an apple host whose data folder is on a disk that is gone.
struct HostStorageBanner: View {
    let session: HostSession

    var body: some View {
        if let block = session.dataRootBlock() {
            StorageBannerContent(message: block.hostMessage)
                .padding(.horizontal, 10)
                .padding(.top, 6)
        }
    }
}

/// Shown on a container that mounts a folder from a disk that is gone.
struct ContainerStorageBanner: View {
    let session: HostSession
    let container: ContainerSummary

    var body: some View {
        if let block = session.storageBlock(for: container) {
            StorageBannerContent(message: block.startMessage)
        }
    }
}

/// Shown while a disk access waits for a macOS permission dialog: the
/// reason, a button to the privacy settings, and Cancel.
struct DiskAccessBanner: View {
    let session: HostSession

    var body: some View {
        if let wait = session.diskAccessWait {
            DiskAccessHint(message: wait.message) { wait.cancel() }
                .padding(.horizontal, 10)
                .padding(.top, 6)
        }
    }
}

/// The permission hint with its two actions.
struct DiskAccessHint: View {
    let message: String
    var cancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ProgressView().controlSize(.small)
                Text(message)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                OpenPrivacySettingsButton()
                if let cancel {
                    Button(String(localized: "Cancel"), role: .cancel, action: cancel)
                }
            }
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.orange.opacity(0.35)))
        .accessibilityElement(children: .contain)
    }
}

/// Opens Privacy & Security > Files and Folders.
struct OpenPrivacySettingsButton: View {
    var body: some View {
        Button(String(localized: "Open Privacy Settings")) {
            NSWorkspace.shared.open(DiskAccessSettings.filesAndFoldersURL)
        }
    }
}
