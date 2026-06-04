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
    @State private var search = ""
    @State private var streamError: String?

    /// When true, only lines containing the query are shown; otherwise every
    /// line is shown with matches highlighted in place.
    @State private var filterOnly = false

    /// Indices (into `lines`) of every line that matches the current query.
    /// Recomputed once per (query, lines.count) change, never per row.
    @State private var matchIndices: [Int] = []

    /// Position within `matchIndices` of the currently focused match.
    @State private var currentMatch = 0

    @FocusState private var searchFocused: Bool

    /// Lines to render: all lines, or only matching lines in filter mode.
    private var visibleLines: [LogEntry] {
        guard filterOnly, !search.isEmpty else { return lines }
        let matchSet = Set(matchIndices)
        return lines.enumerated().filter { matchSet.contains($0.offset) }.map(\.element)
    }

    private var isSearching: Bool { !search.isEmpty }

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
        .onChange(of: search) { recomputeMatches() }
        .onChange(of: lines.count) { recomputeMatches() }
        .background {
            // Invisible button gives Cmd+F a target that focuses the field.
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
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

            searchBar
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { advance(by: 1) }

                if isSearching {
                    Text(matchCounterText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()

                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.quaternary, in: .rect(cornerRadius: 6))
            .frame(width: 230)

            Button { advance(by: -1) } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(matchIndices.isEmpty)
            .help("Previous match")

            Button { advance(by: 1) } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(matchIndices.isEmpty)
            .help("Next match")

            Toggle(isOn: $filterOnly) {
                Image(systemName: "line.3.horizontal.decrease")
            }
            .toggleStyle(.button)
            .help(filterOnly ? "Showing only matching lines" : "Showing all lines with highlights")
        }
    }

    private var matchCounterText: String {
        guard !matchIndices.isEmpty else { return "0 of 0" }
        return "\(currentMatch + 1) of \(matchIndices.count)"
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
                            row(for: entry)
                                .id(entry.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchor)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .onChange(of: lines.count) {
                    guard autoScroll, !isSearching else { return }
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
                .onChange(of: autoScroll) {
                    guard autoScroll else { return }
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
                .onChange(of: currentMatch) {
                    scrollToCurrentMatch(proxy)
                }
            }
        }
    }

    /// Renders one log line, highlighting search matches when searching. The
    /// line that holds the currently focused match gets a stronger highlight.
    @ViewBuilder
    private func row(for entry: LogEntry) -> some View {
        let isCurrentLine = currentMatchLineID == entry.id
        Text(highlighted(entry.text, strong: isCurrentLine))
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(entry.stream == .stderr ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The `LogEntry.id` of the line containing the currently focused match,
    /// or nil if there is no active match.
    private var currentMatchLineID: LogEntry.ID? {
        guard !matchIndices.isEmpty, matchIndices.indices.contains(currentMatch) else { return nil }
        let lineIndex = matchIndices[currentMatch]
        guard lines.indices.contains(lineIndex) else { return nil }
        return lines[lineIndex].id
    }

    /// Builds an `AttributedString` with case-insensitive query matches given a
    /// yellow background; the focused line uses a stronger opacity.
    private func highlighted(_ text: String, strong: Bool) -> AttributedString {
        var attributed = AttributedString(text)
        guard isSearching else { return attributed }

        let background = Color.yellow.opacity(strong ? 0.8 : 0.4)
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: search, options: .caseInsensitive, range: searchRange) {
            if let lower = AttributedString.Index(found.lowerBound, within: attributed),
               let upper = AttributedString.Index(found.upperBound, within: attributed) {
                attributed[lower..<upper].backgroundColor = background
            }
            searchRange = found.upperBound..<text.endIndex
        }
        return attributed
    }

    private let bottomAnchor = "logs.bottom"

    // MARK: - Search

    /// Recomputes the set of matching line indices for the current query and
    /// clamps the focused-match cursor. Runs once per query/length change.
    private func recomputeMatches() {
        guard isSearching else {
            matchIndices = []
            currentMatch = 0
            return
        }
        var indices: [Int] = []
        for (i, line) in lines.enumerated() where line.text.range(of: search, options: .caseInsensitive) != nil {
            indices.append(i)
        }
        matchIndices = indices
        if currentMatch >= indices.count {
            currentMatch = max(0, indices.count - 1)
        }
    }

    /// Advances the focused match by `delta`, wrapping around the match list.
    private func advance(by delta: Int) {
        guard !matchIndices.isEmpty else { return }
        let count = matchIndices.count
        currentMatch = ((currentMatch + delta) % count + count) % count
    }

    private func scrollToCurrentMatch(_ proxy: ScrollViewProxy) {
        guard let id = currentMatchLineID else { return }
        withAnimation(.snappy) {
            proxy.scrollTo(id, anchor: .center)
        }
    }

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
