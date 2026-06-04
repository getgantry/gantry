import SwiftUI
import AppCore
import DockerKit

/// Live process listing for a running container (`docker top`). Columns are
/// driven by the daemon-reported titles; rows refresh every few seconds while
/// the view is visible and the container is running.
struct ProcessesView: View {
    let session: HostSession
    let container: ContainerSummary

    @State private var top: ContainerTop?
    @State private var errorText: String?
    @State private var isLoading = true

    private var isRunning: Bool { container.state.isRunning }

    var body: some View {
        Group {
            if !isRunning {
                ContentUnavailableView(
                    "Container Not Running",
                    systemImage: "cpu",
                    description: Text("Process information is only available while the container is running.")
                )
            } else if isLoading && top == nil {
                ProgressView().controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorText, top == nil {
                ContentUnavailableView(
                    "Processes Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorText)
                )
            } else if let top {
                processTable(top)
            } else {
                ContentUnavailableView(
                    "No Processes",
                    systemImage: "cpu",
                    description: Text("The container reported no running processes.")
                )
            }
        }
        .task(id: container.id) {
            await refreshLoop()
        }
    }

    // MARK: - Table

    private func processTable(_ top: ContainerTop) -> some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                // Header row.
                HStack(spacing: 0) {
                    ForEach(Array(top.titles.enumerated()), id: \.offset) { _, title in
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .frame(minWidth: 80, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                }
                .background(.quaternary)

                Divider()

                ForEach(Array(top.processes.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell)
                                .font(.system(.caption, design: .monospaced))
                                .frame(minWidth: 80, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .textSelection(.enabled)
                        }
                    }
                    .background(index.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.06))
                }
            }
            .padding()
        }
    }

    // MARK: - Refresh

    /// Polls `docker top` every 3 seconds while the view is visible. The task
    /// is cancelled automatically by `.task(id:)` when the view disappears.
    private func refreshLoop() async {
        guard isRunning else { isLoading = false; return }
        while !Task.isCancelled {
            do {
                top = try await session.processes(containerID: container.id)
                errorText = nil
            } catch {
                errorText = error.localizedDescription
            }
            isLoading = false
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                break
            }
        }
    }
}
