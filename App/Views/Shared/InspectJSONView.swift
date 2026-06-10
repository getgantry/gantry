import SwiftUI
import AppKit

/// Renders raw inspect JSON with a copy button. The provider is invoked lazily
/// inside a `.task` so the JSON is only fetched when this tab becomes visible.
struct InspectJSONView: View {
    let provider: () async -> String

    @State private var json: String?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let json, !json.isEmpty {
                // A bidirectional ScrollView centers content that is smaller than
                // the viewport; pin the text to the top-leading corner and let it
                // fill the viewport so short inspect output starts at the top-left
                // rather than floating in the middle.
                GeometryReader { geo in
                    ScrollView([.vertical, .horizontal]) {
                        Text(json)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(
                                minWidth: geo.size.width,
                                minHeight: geo.size.height,
                                alignment: .topLeading
                            )
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            copyToPasteboard(json)
                        } label: {
                            Label("Copy JSON", systemImage: "doc.on.doc")
                        }
                        .help("Copy the full JSON to the clipboard")
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Data",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Inspect data could not be loaded.")
                )
            }
        }
        .task {
            isLoading = true
            json = await provider()
            isLoading = false
        }
    }
}
