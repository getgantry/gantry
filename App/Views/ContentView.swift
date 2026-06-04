import SwiftUI
import AppCore

struct ContentView: View {
    @State private var selection: SidebarItem?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Local") {
                    Label("Containers", systemImage: "shippingbox")
                        .tag(SidebarItem.containers)
                    Label("Images", systemImage: "square.stack.3d.up")
                        .tag(SidebarItem.images)
                    Label("Volumes", systemImage: "externaldrive")
                        .tag(SidebarItem.volumes)
                    Label("Networks", systemImage: "network")
                        .tag(SidebarItem.networks)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            ContentUnavailableView(
                "No Selection",
                systemImage: "shippingbox",
                description: Text("Select a section in the sidebar.")
            )
        }
        .navigationTitle("Gantry")
    }
}

enum SidebarItem: Hashable {
    case containers
    case images
    case volumes
    case networks
}

#Preview {
    ContentView()
}
