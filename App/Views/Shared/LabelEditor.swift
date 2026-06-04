import SwiftUI

/// One editable label row backing a `LabelEditor`.
struct LabelPair: Identifiable, Hashable {
    let id = UUID()
    var key: String = ""
    var value: String = ""
}

/// A small key/value editor with add/remove rows, used by the create sheets.
struct LabelEditor: View {
    @Binding var pairs: [LabelPair]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Labels")
                    .font(.callout)
                Spacer()
                Button {
                    pairs.append(LabelPair())
                } label: {
                    Label("Add", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
            }

            if pairs.isEmpty {
                Text("No labels")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach($pairs) { $pair in
                    HStack(spacing: 6) {
                        TextField("key", text: $pair.key)
                            .textFieldStyle(.roundedBorder)
                        TextField("value", text: $pair.value)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            pairs.removeAll { $0.id == pair.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}

extension Array where Element == LabelPair {
    /// Collapses the rows into a labels dictionary, dropping blank keys.
    var asDictionary: [String: String] {
        var result: [String: String] = [:]
        for pair in self {
            let key = pair.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            result[key] = pair.value
        }
        return result
    }
}
