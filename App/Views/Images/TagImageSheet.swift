import SwiftUI
import AppCore
import DockerKit

/// Sheet to add a `repo:tag` to an existing image.
struct TagImageSheet: View {
    let image: ImageSummary
    let session: HostSession

    @Environment(\.dismiss) private var dismiss

    @State private var repo = ""
    @State private var tag = "latest"
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tag Image")
                .font(.title2.weight(.bold))

            Text(image.displayName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            VStack(alignment: .leading, spacing: 8) {
                TextField("Repository (e.g. myregistry/app)", text: $repo)
                    .textFieldStyle(.roundedBorder)
                TextField("Tag", text: $tag)
                    .textFieldStyle(.roundedBorder)
            }
            .disabled(working)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add Tag") { addTag() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(repo.trimmingCharacters(in: .whitespaces).isEmpty
                        || tag.trimmingCharacters(in: .whitespaces).isEmpty
                        || working)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func addTag() {
        working = true
        let repoValue = repo.trimmingCharacters(in: .whitespaces)
        let tagValue = tag.trimmingCharacters(in: .whitespaces)
        Task {
            let ok = await session.tagImage(id: image.id, repo: repoValue, tag: tagValue)
            working = false
            if ok { dismiss() }
        }
    }
}
