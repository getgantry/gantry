import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AppCore

/// Screenshots for the model: thumbnails, "Add Image…", the limit message
/// and the privacy note. The panel shows it only when the model takes images.
struct ExplainAttachmentsBar: View {
    let controller: ExplainController
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ForEach(controller.images) { image in
                    ExplainImageThumbnail(image: image) { controller.removeImage(id: image.id) }
                }
                if controller.images.count < ExplainImageLimits.maxCount {
                    Button {
                        importing = true
                    } label: {
                        Label(String(localized: "Add Image…"), systemImage: "photo.badge.plus")
                    }
                    .help(String(localized: "Attach a screenshot, for example of a browser error. You can also drop or paste images here."))
                }
                Spacer(minLength: 0)
            }
            ExplainAttachmentsStatus(controller: controller)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await ExplainImageDrop.add(urls: urls, to: controller) }
        }
    }
}

/// The rejection of the last add, and the note when images are attached.
private struct ExplainAttachmentsStatus: View {
    let controller: ExplainController

    var body: some View {
        if let rejection = controller.lastRejection {
            Label(rejection.message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if !controller.images.isEmpty {
            Label(String(localized: "Images stay on this Mac. Gantry does not hide secrets in images."), systemImage: "photo.badge.checkmark")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ExplainImageThumbnail: View {
    let image: ExplainImage
    let remove: () -> Void

    var body: some View {
        Image(decorative: image.cgImage, scale: 1)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 64, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            .overlay(alignment: .topTrailing) {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(2)
                .accessibilityLabel(String(localized: "Remove \(image.name)"))
            }
            .help(image.name)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(image.name)
    }
}

/// Turns drops, pastes and chosen files into image sources for AppCore.
@MainActor
enum ExplainImageDrop {
    static let types: [UTType] = [.fileURL, .image]

    static func add(urls: [URL], to controller: ExplainController) async {
        let scoped = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
        await controller.addImages(urls.map { .file($0) })
        for (url, started) in scoped where started { url.stopAccessingSecurityScopedResource() }
    }

    static func add(providers: [NSItemProvider], to controller: ExplainController) {
        Task {
            var sources: [ExplainImageSource] = []
            for provider in providers {
                if let source = await source(from: provider) { sources.append(source) }
            }
            await controller.addImages(sources)
        }
    }

    /// A file URL when there is one, so a large file is checked before it
    /// is read; otherwise the image data (a pasted screenshot).
    private static func source(from provider: NSItemProvider) async -> ExplainImageSource? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await loadURL(provider) {
            return .file(url)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
           let data = await loadData(provider) {
            return .data(data, name: provider.suggestedName ?? ExplainImagePreparer.pastedName)
        }
        // Text or another type: let AppCore refuse it with a reason.
        return .data(Data(), name: provider.suggestedName ?? "")
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    private static func loadData(_ provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(for: .image) { data, _ in continuation.resume(returning: data) }
        }
    }
}

/// Drop target, paste command and a highlight while a drop hovers. It does
/// nothing when the model does not take images.
///
/// The panel holds only text and buttons, so nothing in the window gets the
/// focus. Without a focused view, Edit > Paste stays off and Command-V does
/// nothing. The panel thus takes the focus for edit commands when it opens.
struct ExplainImageDropTarget: ViewModifier {
    let controller: ExplainController
    @State private var targeted = false
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        if controller.supportsImages {
            content
                .focusable(interactions: .edit)
                .focusEffectDisabled()
                .focused($focused)
                .onAppear { focused = true }
                .onDrop(of: ExplainImageDrop.types, isTargeted: $targeted) { providers in
                    ExplainImageDrop.add(providers: providers, to: controller)
                    return true
                }
                .onPasteCommand(of: ExplainImageDrop.types) { providers in
                    ExplainImageDrop.add(providers: providers, to: controller)
                }
                .overlay {
                    if targeted {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                            .padding(4)
                            .allowsHitTesting(false)
                    }
                }
        } else {
            content
        }
    }
}
