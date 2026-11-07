import SwiftUI
import AppCore

/// A palette choice handed back to the main window when the sheet closes.
struct PaletteChoice {
    let item: PaletteItem
    let action: PaletteAction
}

/// The ⌘K palette: one search field over every host's resources, sections
/// and commands. Arrows move, Return runs the default action, ⌘Return lists
/// the other actions, Esc goes back or closes.
struct CommandPaletteView: View {
    let items: [PaletteItem]
    let recents: [String]
    @Binding var choice: PaletteChoice?

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection = 0
    /// The item whose action list is shown, or nil for the result list.
    @State private var actionItem: PaletteItem?
    @State private var actionSelection = 0
    @FocusState private var fieldFocused: Bool

    private var results: [PaletteItem] {
        PaletteRanker.rank(items, query: query, recents: recents)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            listArea
            Divider()
            PaletteFooter(showingActions: actionItem != nil)
        }
        .frame(width: 640, height: 440)
        .onAppear { fieldFocused = true }
        .onChange(of: query) {
            selection = 0
            actionItem = nil
        }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: actionItem == nil ? "magnifyingglass" : "list.bullet")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(fieldPrompt, text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($fieldFocused)
                .accessibilityLabel(Text("Search"))
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.leftArrow) { leaveActions() }
                .onKeyPress(.escape) { escape() }
                .onKeyPress(.return, phases: .down) { press in
                    press.modifiers.contains(.command) ? showActions() : runSelected()
                }
                .onSubmit { _ = runSelected() }
        }
        .padding(12)
    }

    private var fieldPrompt: String {
        if let actionItem {
            return String(localized: "Actions for “\(actionItem.title)”")
        }
        return String(localized: "Search containers, images, hosts and commands")
    }

    // MARK: - Lists

    @ViewBuilder
    private var listArea: some View {
        if let actionItem {
            actionList(actionItem)
        } else if results.isEmpty {
            ContentUnavailableView.search(text: query)
                .frame(maxHeight: .infinity)
        } else {
            resultList
        }
    }

    private var resultList: some View {
        let rows = results
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                        PaletteResultRow(item: item, isSelected: index == selection)
                            .id(item.id)
                            .onTapGesture { run(item, item.defaultAction) }
                    }
                }
                .padding(6)
            }
            .onChange(of: selection) {
                if rows.indices.contains(selection) { proxy.scrollTo(rows[selection].id) }
            }
        }
    }

    private func actionList(_ item: PaletteItem) -> some View {
        ScrollView {
            VStack(spacing: 2) {
                PaletteResultRow(item: item, isSelected: false)
                    .opacity(0.8)
                Divider().padding(.vertical, 4)
                ForEach(Array(item.actions.enumerated()), id: \.element) { index, action in
                    PaletteActionRow(action: action, kind: item.kind, isSelected: index == actionSelection)
                        .onTapGesture { run(item, action) }
                }
            }
            .padding(6)
        }
    }

    // MARK: - Keys

    private func move(_ delta: Int) -> KeyPress.Result {
        if let actionItem {
            actionSelection = clamp(actionSelection + delta, count: actionItem.actions.count)
        } else {
            selection = clamp(selection + delta, count: results.count)
        }
        return .handled
    }

    private func clamp(_ value: Int, count: Int) -> Int {
        min(max(value, 0), max(count - 1, 0))
    }

    private func showActions() -> KeyPress.Result {
        let rows = results
        guard actionItem == nil, rows.indices.contains(selection) else { return .handled }
        actionItem = rows[selection]
        actionSelection = 0
        return .handled
    }

    private func leaveActions() -> KeyPress.Result {
        guard actionItem != nil else { return .ignored }
        actionItem = nil
        return .handled
    }

    private func escape() -> KeyPress.Result {
        if actionItem != nil {
            actionItem = nil
        } else {
            dismiss()
        }
        return .handled
    }

    private func runSelected() -> KeyPress.Result {
        if let actionItem {
            if actionItem.actions.indices.contains(actionSelection) {
                run(actionItem, actionItem.actions[actionSelection])
            }
        } else {
            let rows = results
            if rows.indices.contains(selection) { run(rows[selection], rows[selection].defaultAction) }
        }
        return .handled
    }

    private func run(_ item: PaletteItem, _ action: PaletteAction) {
        choice = PaletteChoice(item: item, action: action)
        dismiss()
    }
}

/// One result: symbol, title, kind and host, and the status as text and symbol.
private struct PaletteResultRow: View {
    let item: PaletteItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.systemImage)
                .frame(width: 22)
                .foregroundStyle(isSelected ? .primary : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            status
            if isSelected, item.actions.count > 1 {
                Text("⌘↩ Actions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selectionBackground)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(item.title))
        .accessibilityValue(Text([detailLine, item.status].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var detailLine: String {
        [item.kind.title, item.hostName].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private var status: some View {
        if let text = item.status {
            HStack(spacing: 4) {
                if let active = item.isActive {
                    Image(systemName: active ? "circle.fill" : "circle")
                        .font(.system(size: 7))
                        .foregroundStyle(active ? Color.green : Color.secondary)
                }
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var selectionBackground: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
    }
}

/// One action in the secondary list.
private struct PaletteActionRow: View {
    let action: PaletteAction
    let kind: PaletteKind
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: action.systemImage)
                .frame(width: 22)
                .foregroundStyle(action.isDestructive ? Color.red : Color.secondary)
                .accessibilityHidden(true)
            Text(action.title(for: kind))
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(action.title(for: kind)))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The key hints under the list.
private struct PaletteFooter: View {
    let showingActions: Bool

    var body: some View {
        HStack(spacing: 16) {
            Text("↑↓ Move")
            Text(showingActions ? "↩ Run" : "↩ Open")
            if showingActions {
                Text("← Back")
            } else {
                Text("⌘↩ Actions")
            }
            Spacer()
            Text("Esc Close")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}
