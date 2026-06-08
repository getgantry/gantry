import AppIntents

/// Surfaces Gantry's intents to Siri and the Shortcuts app with natural-language
/// trigger phrases.
struct GantryShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ListContainersIntent(),
            phrases: [
                "List \(.applicationName) containers",
                "Show Docker containers in \(.applicationName)",
                "List Docker containers with \(.applicationName)"
            ],
            shortTitle: "List Containers",
            systemImageName: "shippingbox"
        )
        AppShortcut(
            intent: StartContainerIntent(),
            phrases: [
                "Start \(.applicationName) container",
                "Start a Docker container with \(.applicationName)"
            ],
            shortTitle: "Start Container",
            systemImageName: "shippingbox"
        )
        AppShortcut(
            intent: StopContainerIntent(),
            phrases: [
                "Stop \(.applicationName) container",
                "Stop a Docker container with \(.applicationName)"
            ],
            shortTitle: "Stop Container",
            systemImageName: "shippingbox"
        )
        AppShortcut(
            intent: RestartContainerIntent(),
            phrases: [
                "Restart \(.applicationName) container",
                "Restart a Docker container with \(.applicationName)"
            ],
            shortTitle: "Restart Container",
            systemImageName: "shippingbox"
        )
        AppShortcut(
            intent: GetContainerLogsIntent(),
            phrases: [
                "Get \(.applicationName) container logs",
                "Show Docker container logs with \(.applicationName)"
            ],
            shortTitle: "Container Logs",
            systemImageName: "shippingbox"
        )
        AppShortcut(
            intent: ComposeUpIntent(),
            phrases: [
                "Compose up with \(.applicationName)",
                "Run a compose file in \(.applicationName)",
                "\(.applicationName) compose up"
            ],
            shortTitle: "Compose Up",
            systemImageName: "square.stack.3d.up"
        )
    }
}
