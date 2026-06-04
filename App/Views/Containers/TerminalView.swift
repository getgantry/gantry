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

    func makeCoordinator() -> Coordinator {
        Coordinator(onInput: onInput, onResize: onResize)
    }

    func makeNSView(context: Context) -> SwiftTerm.TerminalView {
        let view = SwiftTerm.TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = .textBackgroundColor
        view.nativeForegroundColor = .textColor
        // Treat the Option key as Meta so common shell shortcuts work.
        view.optionAsMetaKey = true
        feedHandle.view = view
        return view
    }

    func updateNSView(_ nsView: SwiftTerm.TerminalView, context: Context) {
        context.coordinator.onInput = onInput
        context.coordinator.onResize = onResize
        // Keep colors in sync with light/dark appearance changes.
        nsView.nativeBackgroundColor = .textBackgroundColor
        nsView.nativeForegroundColor = .textColor
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

/// The Terminal tab content: opens a shell exec session into the container
/// and drives it through the shared `TerminalPane`.
struct ContainerTerminalView: View {
    let session: HostSession
    let container: ContainerSummary

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
        } else {
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
        }
    }
}
