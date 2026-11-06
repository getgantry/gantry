import SwiftUI
import AppKit
import AppCore

/// The non-modal error banner of the content area. It replaces the old
/// "Docker Error" alert: it names the host kind, keeps raw CLI output under
/// Details, and goes away on Dismiss or after a refresh that works.
struct ActionErrorBanner: View {
    let session: HostSession

    var body: some View {
        if let message = visibleMessage {
            ActionErrorBannerContent(
                title: Self.title(for: session.host),
                message: message,
                dismiss: { session.lastError = nil }
            )
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// The kernel error has its own alert with an Install button.
    private var visibleMessage: String? {
        guard let error = session.lastError else { return nil }
        if session.host.isAppleContainer && AppleMissingKernelAlert.isKernelError(error) { return nil }
        return error
    }

    static func title(for host: DockerHost) -> String {
        switch ErrorPresentation.source(for: host) {
        case .appleContainer: String(localized: "Apple container")
        case .docker: "Docker"
        case .host(let name): name
        }
    }
}

/// The look of the banner, shared with the menu bar error row.
struct ActionErrorBannerContent: View {
    let title: String
    let message: String
    let dismiss: () -> Void
    @State private var showDetails = false

    var body: some View {
        let parts = ErrorPresentation.split(message)
        VStack(alignment: .leading, spacing: 4) {
            header(summary: parts.summary)
            if let details = parts.details {
                DisclosureGroup(String(localized: "Details"), isExpanded: $showDetails) {
                    detailsText(details)
                }
                .font(.caption)
            }
        }
        .padding(10)
        .background(.red.opacity(0.12), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.red.opacity(0.35)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "\(title) error"))
    }

    private func header(summary: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(summary).font(.callout).textSelection(.enabled)
            }
            Spacer(minLength: 4)
            Button {
                copyToPasteboard(message)
            } label: {
                Label(String(localized: "Copy"), systemImage: "doc.on.doc")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(String(localized: "Copy the full error"))
            Button(action: dismiss) {
                Label(String(localized: "Dismiss"), systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(String(localized: "Dismiss"))
        }
    }

    private func detailsText(_ details: String) -> some View {
        ScrollView {
            Text(details)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 140)
    }
}

/// An inline error for sheets: selectable text that is not cut off.
struct InlineErrorText: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.callout)
        .foregroundStyle(.red)
    }
}
