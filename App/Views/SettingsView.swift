import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                Form {
                    Text("Settings will appear here.")
                        .foregroundStyle(.secondary)
                }
                .formStyle(.grouped)
            }
        }
        .frame(width: 480, height: 320)
    }
}

#Preview {
    SettingsView()
}
