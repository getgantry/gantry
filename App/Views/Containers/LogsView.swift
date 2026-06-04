import SwiftUI
import AppKit
import AppCore
import DockerKit

struct LogsView: View {
    let session: HostSession
    let container: ContainerSummary

    private static let maxLines = 5000

    @State private var lines: [LogEntry] = []
    @State private var paused = false
    @State private var autoScroll = true
    @State private var filter = ""
    @State private var streamError: String?

    private var visibleLines: [LogEntry] {
        guard !filter.isEmpty else { return lines }
        let needle = filter.lowercased()
        return lines.filter { $0.text.lowercased().contains(needle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            if let streamError {
                errorBanner(streamError)
                Divider()
            }
            content
        }
        .task(id: container.id) {
            await consume()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $autoScroll) {
                Image(systemName: "arrow.down.to.line")
            }
            .toggleStyle(.button)
            .help("Follow output")

            Button {
                paused.toggle()
            } label: {
                Image(systemName: paused ? "play.fill" : "pause.fill")
            }
            .help(paused ? "Resume" : "Pause")

            Button {
                lines.removeAll()
            } label: {
                Image(systemName: "trash")
            }
            .help("Clear")

            Button {
                copyAll()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy all")

            Text("\(visibleLines.count) lines")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
            }
            .frame(width: 180)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if lines.isEmpty {
            ContentUnavailableView(
                "No log output yet",
                systemImage: "text.alignleft"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(visibleLines) { entry in
                            Text(entry.text)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(entry.stream == .stderr ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchor)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .onChange(of: lines.count) {
                    guard autoScroll else { return }
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
                .onChange(of: autoScroll) {
                    guard autoScroll else { return }
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    private let bottomAnchor = "logs.bottom"

    // MARK: - Streaming

    private func consume() async {
        lines.removeAll()
        streamError = nil
        do {
            let stream = try await session.logStream(for: container.id)
            for try await entry in stream {
                if paused { continue }
                lines.append(entry)
                if lines.count > Self.maxLines {
                    lines.removeFirst(lines.count - Self.maxLines)
                }
            }
        } catch is CancellationError {
            // View went away; nothing to report.
        } catch {
            streamError = error.localizedDescription
        }
    }

    // MARK: - Actions

    private func copyAll() {
        let text = visibleLines.map(\.text).joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
