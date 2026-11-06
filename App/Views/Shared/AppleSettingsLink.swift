import SwiftUI

/// The Settings window tabs. Stored so a link can open Settings on a tab.
enum SettingsTab: String {
    case general, hosts, apple, agents, about

    static let storageKey = "settingsTab"
}

/// "Settings → Apple" as a link: opens Settings on the Apple tab.
struct AppleSettingsLink: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Open Settings → Apple") {
            UserDefaults.standard.set(SettingsTab.apple.rawValue, forKey: SettingsTab.storageKey)
            openSettings()
        }
        .buttonStyle(.link)
    }
}

/// The empty DNS-domain row of the create sheets: what is missing and a link
/// to where it is added.
struct NoLocalDomainsRow: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "globe").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("No local domains. Add one to reach containers by name.")
                    .foregroundStyle(.secondary)
                AppleSettingsLink()
            }
        }
        .font(.callout)
    }
}
