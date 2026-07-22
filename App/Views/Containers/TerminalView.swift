import SwiftUI
import AppKit
import AppCore
import DockerKit
import SwiftTerm

// MARK: - Feed handle

/// Bridge that lets the SwiftUI layer push daemon bytes into the live
/// `SwiftTerm.TerminalView` without holding a strong reference to the NSView.
@MainActor
final class TerminalFeedHandle {
    weak var view: SwiftTerm.TerminalView?

    func feed(_ data: Data) {
        view?.feed(byteArray: [UInt8](data)[...])
    }
}

// MARK: - NSViewRepresentable

/// Wraps `SwiftTerm.TerminalView` (the AppKit terminal) for SwiftUI.
/// Keystrokes flow out via `onInput`; geometry changes via `onResize`.
struct GantryTerminalView: NSViewRepresentable {
    let feedHandle: TerminalFeedHandle
    let onInput: (Data) -> Void
    let onResize: (_ cols: Int, _ rows: Int) -> Void

    @AppStorage(TerminalTheme.preferenceKey) private var themeID = "system"

    func makeCoordinator() -> Coordinator {
        Coordinator(onInput: onInput, onResize: onResize)
    }

    func makeNSView(context: Context) -> SwiftTerm.TerminalView {
        let view = SwiftTerm.TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        // Treat the Option key as Meta so common shell shortcuts work.
        view.optionAsMetaKey = true
        TerminalTheme.theme(id: themeID).apply(to: view)
        feedHandle.view = view
        return view
    }

    func updateNSView(_ nsView: SwiftTerm.TerminalView, context: Context) {
        context.coordinator.onInput = onInput
        context.coordinator.onResize = onResize
        // Re-apply the selected theme (also keeps the System theme in sync with
        // light/dark appearance changes).
        TerminalTheme.theme(id: themeID).apply(to: nsView)
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        var onInput: (Data) -> Void
        var onResize: (_ cols: Int, _ rows: Int) -> Void

        init(onInput: @escaping (Data) -> Void, onResize: @escaping (Int, Int) -> Void) {
            self.onInput = onInput
            self.onResize = onResize
        }

        // SwiftTerm's `TerminalViewDelegate` is nonisolated, but every callback is
        // delivered on the main thread (the view is an NSView). We mark the methods
        // `nonisolated` to satisfy the protocol and hop onto the main actor via
        // `assumeIsolated` to touch our `@MainActor` closures.
        nonisolated func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            MainActor.assumeIsolated {
                onInput(Data(data))
            }
        }

        nonisolated func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated {
                onResize(newCols, newRows)
            }
        }

        nonisolated func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        nonisolated func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        nonisolated func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
        nonisolated func bell(source: SwiftTerm.TerminalView) {}
        nonisolated func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {}
        nonisolated func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
        nonisolated func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}

// MARK: - Container terminal tab

/// The Terminal tab content. Opens a shell exec session into the container
/// and drives it through the shared `TerminalPane`.
///
/// On a Docker host it also offers a **debug shell**: many images ship without
/// `/bin/sh` at all (distroless) or without `curl`, `ps` and `ip` to debug
/// with, and a read-only container can't be given them. The debug mode instead
/// attaches a toolbox sidecar to the container's namespaces, leaving the
/// container itself untouched. See `DebugShell`.
struct ContainerTerminalView: View {
    let session: HostSession
    let container: ContainerSummary

    private enum Mode: String, CaseIterable, Identifiable {
        case shell = "Shell"
        case debug = "Debug"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .shell
    /// Preparation status while the sidecar is being pulled/started.
    @State private var preparing: String?

    /// Single robust command: prefer bash, fall back to sh inside one shell.
    /// Note: a failed `exec` kills a non-interactive POSIX shell, so `exec bash
    /// || exec sh` dies on bash-less images (Alpine). Probe with `command -v`
    /// before exec'ing instead.
    private let shellCommand = [
        "/bin/sh", "-c",
        "if command -v bash >/dev/null 2>&1; then exec bash; else exec sh; fi",
    ]

    var body: some View {
        if !container.state.isRunning {
            ContentUnavailableView(
                "Container is not running",
                systemImage: "pause.circle"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                if session.supportsDebugShell {
                    modeBar
                    Divider()
                }
                pane
            }
            .onReceive(NotificationCenter.default.publisher(for: .gantryOpenDebugShell)) { note in
                if note.object as? String == container.id, session.supportsDebugShell {
                    mode = .debug
                }
            }
            .onDisappear {
                // Don't leave a toolbox running for a pane nobody is looking
                // at; it restarts in well under a second when reopened.
                let id = container.id
                Task { await session.stopDebugSidecar(for: id) }
            }
        }
    }

    private var modeBar: some View {
        HStack(spacing: 10) {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if let preparing {
                ProgressView().controlSize(.small)
                Text(preparing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(mode == .shell
                     ? "Runs the container's own shell."
                     : "Attaches a toolbox with curl, ps, ip and friends — works even without a shell in the image.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var pane: some View {
        switch mode {
        case .shell:
            TerminalPane(
                title: container.displayName,
                subtitle: "shell",
                connectionID: container.id,
                connect: {
                    try await session.openExecSession(
                        containerID: container.id,
                        command: shellCommand
                    )
                }
            )
        case .debug:
            TerminalPane(
                title: container.displayName,
                subtitle: "debug shell",
                // A distinct identity so switching modes reconnects rather
                // than reusing the plain shell's session.
                connectionID: "\(container.id)#debug",
                connect: {
                    defer { preparing = nil }
                    return try await session.openDebugSession(containerID: container.id) { step in
                        preparing = step
                    }
                }
            )
        }
    }
}
