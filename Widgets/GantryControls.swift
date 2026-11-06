import WidgetKit
import SwiftUI
import AppIntents
import GantryShared

/// Starts and stops the apple/container services from Control Center.
struct AppleServicesControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: SharedIdentifiers.appleServicesControlKind, provider: Provider()) { running in
            ControlWidgetToggle("apple/container", isOn: running, action: SetAppleServicesIntent()) { isOn in
                Label(isOn ? "Running" : "Stopped", systemImage: isOn ? "shippingbox.fill" : "shippingbox")
            }
        }
        .displayName("apple/container Services")
        .description("Start or stop the apple/container services.")
    }

    struct Provider: ControlValueProvider {
        var previewValue: Bool { false }

        func currentValue() async throws -> Bool {
            SnapshotStore.standard().read()?.appleServices?.running ?? false
        }
    }
}

/// Starts and stops one chosen container from Control Center.
struct FavoriteContainerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: SharedIdentifiers.containerControlKind, provider: Provider()) { value in
            ControlWidgetToggle(
                value.title,
                isOn: value.isRunning,
                action: SetContainerRunningIntent(container: value.container)
            ) { isOn in
                Label(isOn ? "Running" : "Stopped", systemImage: isOn ? "play.circle.fill" : "stop.circle")
            }
        }
        .displayName("Favorite Container")
        .description("Start or stop a container that you choose.")
        .promptsForUserConfiguration()
    }

    struct Value {
        var title: String
        var isRunning: Bool
        var container: ControlContainerEntity?
    }

    struct Provider: AppIntentControlValueProvider {
        func previewValue(configuration: FavoriteContainerConfiguration) -> Value {
            Value(title: configuration.container?.name ?? String(localized: "Container"), isRunning: false, container: configuration.container)
        }

        func currentValue(configuration: FavoriteContainerConfiguration) async throws -> Value {
            guard let container = configuration.container,
                  let parts = FleetSnapshot.ContainerRef.split(container.id) else {
                return Value(title: String(localized: "Container"), isRunning: false, container: nil)
            }
            let ref = SnapshotStore.standard().read()?.container(hostID: parts.hostID, name: parts.name)
            return Value(title: container.name, isRunning: ref?.isRunning ?? false, container: container)
        }
    }
}
