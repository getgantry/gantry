import SwiftUI

/// Settings pane that explains Gantry's agent integrations: App Intents
/// (Shortcuts / Siri / Spotlight, including the `shortcuts run` CLI) and the
/// embedded MCP server (`gantry-mcp`) that exposes Docker to MCP clients such
/// as Claude.
///
/// Self-contained: depends only on SwiftUI and `Bundle.main` so it can be
/// dropped into the Settings scene without touching other view files.
struct AgentSettingsView: View {
    /// Install command for registering the MCP server with an MCP client.
    private var mcpInstallCommand: String {
        "claude mcp add gantry -- \(mcpBinaryPath)"
    }

    /// Path to the `gantry-mcp` binary. Prefers the copy bundled in the app's
    /// resources; falls back to the local SPM build product as a placeholder.
    private var mcpBinaryPath: String {
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("gantry-mcp", isDirectory: false),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled.path
        }
        return "$REPO/Packages/GantryMCP/.build/release/gantry-mcp"
    }

    /// Example invocation of an exposed App Intent from the command line.
    private let shortcutsExample = #"shortcuts run "List Containers""#

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                appIntentsSection
                Divider()
                mcpSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Agents")
    }

    // MARK: - App Intents

    private var appIntentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                icon: "app.connected.to.app.below.fill",
                title: "Shortcuts, Siri & Spotlight"
            )

            Text("""
            Gantry ships App Intents, so common Docker actions are available \
            system-wide. Run them from the Shortcuts app, ask Siri, or search \
            for them in Spotlight — for example "List Containers", \
            "Start Container", or "Get Container Logs".
            """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("You can also invoke any exposed intent from the command line:")
                .font(.callout)
                .foregroundStyle(.secondary)

            CodeBlock(code: shortcutsExample)
        }
    }

    // MARK: - MCP

    private var mcpSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                icon: "terminal.fill",
                title: "Model Context Protocol (MCP)"
            )

            Text("""
            Gantry includes a stdio MCP server, gantry-mcp, that exposes your \
            Docker hosts as tools an AI agent can call: list containers, view \
            logs and stats, run lifecycle actions, exec commands, and inspect \
            images, volumes, networks and disk usage. Register it with an MCP \
            client like Claude:
            """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            CodeBlock(code: mcpInstallCommand)

            Label {
                Text("""
                Headless agent access uses only hosts you have already trusted \
                in Gantry: the local daemon, and SSH remotes whose host key is \
                trusted with any required secret saved to the Keychain. Unknown \
                SSH hosts are rejected — there is no prompt in a headless context.
                """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.tint)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Building blocks

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
            Text(title)
                .font(.title3.weight(.semibold))
        }
    }
}

/// A monospaced code block with a copy-to-clipboard button.
private struct CodeBlock: View {
    let code: String

    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                copy()
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.borderless)
            .help(copied ? "Copied" : "Copy")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        )
    }

    private func copy() {
        copyToPasteboard(code)
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { copied = false }
        }
    }
}

#Preview {
    AgentSettingsView()
        .frame(width: 520, height: 600)
}
