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
            } else if let top, !top.processes.isEmpty {
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

    /// One `docker top` row paired with its stable position for Table identity.
    private struct ProcessRow: Identifiable {
        let id: Int
        let cells: [String]
    }

    private func processTable(_ top: ContainerTop) -> some View {
        let rows = top.processes.enumerated().map { ProcessRow(id: $0.offset, cells: $0.element) }
        return Table(rows) {
            TableColumnForEach(Array(top.titles.enumerated()), id: \.offset) { index, title in
                TableColumn(title) { (row: ProcessRow) in
                    Text(row.cells.indices.contains(index) ? row.cells[index] : "")
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(index == top.titles.count - 1 ? .tail : .middle)
                        .textSelection(.enabled)
                        .help(row.cells.indices.contains(index) ? row.cells[index] : "")
                }
                .width(min: 50, ideal: index == top.titles.count - 1 ? 420 : 80)
            }
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
