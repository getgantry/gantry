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

/// The Terminal tab content: opens a shell exec session into the container and
/// pumps its bytes into a `GantryTerminalView`.
struct ContainerTerminalView: View {
    let session: HostSession
    let container: ContainerSummary

    private enum Phase {
        case idle
        case connecting
        case running
        case ended(String)
        case failed(String)
    }

    @State private var phase: Phase = .idle
    @State private var exec: ExecSession?
    @State private var generation = 0
    @State private var feedHandle = TerminalFeedHandle()

    /// Single robust command: prefer bash, fall back to sh inside one shell.
    private let shellCommand = ["/bin/sh", "-c", "exec bash || exec sh"]
    private let shellLabel = "bash"

    var body: some View {
        Group {
            if !container.state.isRunning {
                ContentUnavailableView(
                    "Container is not running",
                    systemImage: "pause.circle"
                )
            } else {
                terminalContent
            }
        }
        .task(id: taskID) {
            guard container.state.isRunning else { return }
            await connect()
        }
        .onDisappear {
            exec?.terminate()
            exec = nil
        }
    }

    private var taskID: String { "\(container.id)#\(generation)" }

    @ViewBuilder
    private var terminalContent: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            ZStack {
                Color(nsColor: .textBackgroundColor)
                GantryTerminalView(
                    feedHandle: feedHandle,
                    onInput: { data in exec?.send(data) },
                    onResize: { cols, rows in exec?.resize(cols: cols, rows: rows) }
                )
                .padding(8)

                switch phase {
                case .connecting:
                    ProgressView("Connecting…")
                        .controlSize(.large)
                        .padding(16)
                        .background(.regularMaterial, in: .rect(cornerRadius: 10))
                case .ended(let message), .failed(let message):
                    overlayBanner(message)
                case .idle, .running:
                    EmptyView()
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text(container.displayName)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Text("•")
                .foregroundStyle(.tertiary)
            Text(shellLabel)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()

            statusIndicator

            Button {
                reconnect()
            } label: {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch phase {
        case .running:
            Label("Connected", systemImage: "circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
                .imageScale(.small)
        case .ended:
            Label("Disconnected", systemImage: "circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .imageScale(.small)
        case .failed:
            Label("Error", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
                .imageScale(.small)
        case .idle, .connecting:
            EmptyView()
        }
    }

    private func overlayBanner(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Reconnect") { reconnect() }
                .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
    }

    // MARK: - Session lifecycle

    private func connect() async {
        phase = .connecting
        do {
            let session = try await session.openExecSession(
                containerID: container.id,
                command: shellCommand
            )
            session.onError = { message in
                phase = .failed(message)
            }
            exec = session
            phase = .running
            await pump(session)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Drains daemon bytes into the terminal until the stream ends or errors.
    private func pump(_ session: ExecSession) async {
        do {
            for try await chunk in session.bytes {
                feedHandle.feed(chunk)
            }
            // Only mark ended if we are still the active session.
            if exec === session {
                phase = .ended("Session closed")
            }
        } catch {
            if exec === session {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func reconnect() {
        exec?.terminate()
        exec = nil
        phase = .idle
        generation += 1
    }
}
