import SwiftUI
import AppCore
import DockerKit

/// Sheet that commits a container's current state to a new image.
struct CommitImageSheet: View {
    let session: HostSession
    let container: ContainerSummary
    @Environment(\.dismiss) private var dismiss

    @State private var repo = ""
    @State private var tag = "latest"
    @State private var comment = ""
    @State private var isWorking = false
    @State private var errorText: String?

    private var canCommit: Bool {
        !repo.trimmingCharacters(in: .whitespaces).isEmpty && !isWorking
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Commit to Image")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding()

            Divider()

            Form {
                Section {
                    TextField("Repository", text: $repo, prompt: Text("myrepo/app"))
                        .textFieldStyle(.roundedBorder)
                    TextField("Tag", text: $tag, prompt: Text("latest"))
                        .textFieldStyle(.roundedBorder)
                    TextField("Comment (optional)", text: $comment)
                        .textFieldStyle(.roundedBorder)
                } header: {
                    Text("Commit \(container.displayName) to a new image.")
                }

                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await commit() }
                } label: {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Commit")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCommit)
            }
            .padding()
        }
        .frame(width: 460, height: 360)
    }

    private func commit() async {
        errorText = nil
        isWorking = true
        defer { isWorking = false }
        let ok = await session.commit(
            containerID: container.id,
            repo: repo.trimmingCharacters(in: .whitespaces),
            tag: tag.trimmingCharacters(in: .whitespaces).isEmpty ? "latest" : tag,
            comment: comment
        )
        if ok {
            dismiss()
        } else {
            errorText = session.lastError ?? "Commit failed"
        }
    }
}
