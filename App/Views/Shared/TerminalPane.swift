import SwiftUI
import AppKit
import AppCore

/// A full terminal experience around any `TerminalSession`: header with
/// status + reconnect, the SwiftTerm view, connection overlays. Used by the
/// container exec terminal and the SSH host shell.
struct TerminalPane: View {
    let title: String
    let subtitle: String
    /// Changing this identity tears down and reconnects the session.
    let connectionID: String
    let connect: @MainActor () async throws -> any TerminalSession

    private enum Phase {
        case idle
        case connecting
        case running
        case ended(String)
        case failed(String)
    }

    @State private var phase: Phase = .idle
    @State private var session: (any TerminalSession)?
    @State private var generation = 0
    @State private var feedHandle = TerminalFeedHandle()

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            ZStack {
                Color(nsColor: .textBackgroundColor)
                GantryTerminalView(
                    feedHandle: feedHandle,
                    onInput: { data in session?.send(data) },
                    onResize: { cols, rows in session?.resize(cols: cols, rows: rows) }
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
        .task(id: "\(connectionID)#\(generation)") {
            await open()
        }
        .onDisappear {
            session?.terminate()
            session = nil
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Text("•")
                .foregroundStyle(.tertiary)
            Text(subtitle)
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

    private func open() async {
        phase = .connecting
        do {
            let opened = try await connect()
            opened.onError = { message in
                phase = .failed(message)
            }
            session = opened
            phase = .running
            await pump(opened)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Drains peer bytes into the terminal until the stream ends or errors.
    private func pump(_ opened: any TerminalSession) async {
        do {
            for try await chunk in opened.bytes {
                feedHandle.feed(chunk)
            }
            // Only mark ended if we are still the active session.
            if session === opened {
                phase = .ended("Session closed")
            }
        } catch {
            if session === opened {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func reconnect() {
        session?.terminate()
        session = nil
        phase = .idle
        generation += 1
    }
}
