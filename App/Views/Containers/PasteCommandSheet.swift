import SwiftUI
import AppKit
import AppCore
import DockerKit

/// Paste a `docker run` or `container run` command. Shows what Gantry cannot
/// use before the form is filled.
struct PasteCommandSheet: View {
    let isAppleHost: Bool
    let onFill: (RunCommandParser.Result) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var outcome: Result<RunCommandParser.Result, RunCommandParser.ParseError>? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            return .success(try RunCommandParser.parse(text))
        } catch {
            return .failure(error)
        }
    }

    private var parsed: RunCommandParser.Result? {
        if case .success(let result) = outcome { return result }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste Command")
                .font(.title2.weight(.semibold))
            Text("Paste a docker run or container run command. Gantry fills the form from it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            editor
            ScrollView { status }
                .frame(maxHeight: 200)
            Spacer(minLength: 0)
            footer
        }
        .padding()
        .frame(width: 560, height: 520)
        .onAppear(perform: prefillFromClipboard)
    }

    private var editor: some View {
        TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            .autocorrectionDisabled()
            .frame(height: 160)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            .accessibilityLabel("Command")
    }

    @ViewBuilder
    private var status: some View {
        switch outcome {
        case .none:
            EmptyView()
        case .failure(let error):
            FieldError(message: error.localizedDescription)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .success(let result):
            VStack(alignment: .leading, spacing: 8) {
                Label("Image: \(result.recipe.image)", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                RunCommandIssuesList(result: result, hostWarnings: result.recipe.hostWarnings(isAppleHost: isAppleHost))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Fill Form") {
                if let parsed {
                    onFill(parsed)
                    dismiss()
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(parsed == nil)
        }
    }

    /// Starts with the clipboard when it holds a run command.
    private func prefillFromClipboard() {
        guard text.isEmpty, let clip = NSPasteboard.general.string(forType: .string) else { return }
        if (try? RunCommandParser.parse(clip)) != nil, clip.contains("run") || clip.contains("create") {
            text = clip
        }
    }
}

/// The flags Gantry did not use, the notes, and the host warnings of a
/// parsed command. Each line has an icon and text, not color only.
struct RunCommandIssuesList: View {
    let result: RunCommandParser.Result
    let hostWarnings: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !result.unsupported.isEmpty {
                Text("Not supported")
                    .font(.callout.weight(.semibold))
                ForEach(result.unsupported) { item in
                    unsupportedRow(item)
                }
            }
            ForEach(result.notes + hostWarnings, id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func unsupportedRow(_ item: RunCommandParser.Unsupported) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.raw)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Text(item.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Not supported: \(item.raw). \(item.reason)"))
    }
}

/// "Copy as docker run" and "Copy as container run" for an existing
/// container: inspects it, then copies the command.
enum ContainerRunCopy {
    @MainActor
    static func run(session: HostSession, container: ContainerSummary, dialect: RunCommandParser.Dialect) {
        Task {
            guard let recipe = await session.recipe(for: container) else { return }
            copyToPasteboard(RunCommandFormatter.command(for: recipe, dialect: dialect))
        }
    }
}

/// The two copy items, for the container context menu and More menu.
struct ContainerRunCopyItems: View {
    let session: HostSession
    let container: ContainerSummary

    var body: some View {
        Menu {
            Button {
                ContainerRunCopy.run(session: session, container: container, dialect: .docker)
            } label: {
                Text(verbatim: "docker run")
            }
            Button {
                ContainerRunCopy.run(session: session, container: container, dialect: .appleContainer)
            } label: {
                Text(verbatim: "container run")
            }
        } label: {
            Label("Copy as Command", systemImage: "terminal")
        }
    }
}

extension View {
    /// The "Save Recipe" prompt: a name field, and a note when the name
    /// replaces a saved recipe.
    func saveRecipePrompt(
        isPresented: Binding<Bool>,
        name: Binding<String>,
        store: RecipeStore,
        recipe: @escaping () -> ContainerRecipe
    ) -> some View {
        alert("Save Recipe", isPresented: isPresented) {
            TextField("Recipe name", text: name)
            Button("Save") { store.save(name: name.wrappedValue, recipe: recipe()) }
                .disabled(RecipeStore.cleanName(name.wrappedValue) == nil)
            Button("Cancel", role: .cancel) {}
        } message: {
            if store.contains(name: name.wrappedValue) {
                Text("A recipe with this name exists. Saving replaces it.")
            } else {
                Text("Save the form so that you can create the same container again.")
            }
        }
    }
}
