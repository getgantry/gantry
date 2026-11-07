import Foundation
import AppCore
import DockerKit
import GantryShared
import os

/// Runs the work of a Control Center control in the app. The control's intent
/// calls ``ControlExecutor`` directly when it runs in the app, or opens a
/// `gantry://control` URL from the sandboxed extension.
@MainActor
enum ControlRequestHandler {
    private static let log = Logger(subsystem: "com.andrewkomkov.Gantry", category: "Controls")

    static func handles(_ url: URL) -> Bool {
        url.scheme == SharedIdentifiers.urlScheme
    }

    static func handle(_ url: URL) {
        guard let request = ControlRequest.parse(url) else {
            log.error("ignored an unknown gantry URL")
            return
        }
        guard request.isAuthorized(expectedToken: SystemIntegration.controlToken) else {
            log.error("ignored a control request with a wrong token")
            return
        }
        Task {
            do {
                try await ControlExecutor.run(request.action)
            } catch {
                ContainerNotifier.shared.presentFailure(
                    title: String(localized: "The control did not work"),
                    body: error.localizedDescription
                )
            }
        }
    }
}

/// Does what a control asks, then refreshes the snapshot and the controls.
@MainActor
enum ControlExecutor {
    static func run(_ action: ControlAction) async throws {
        defer { SystemIntegration.shared.publishSoon(checkAppleServices: true, delay: .milliseconds(300)) }
        switch action {
        case .setAppleServices(let running):
            let override = LiveFleet.hosts().first(where: \.isAppleContainer)?.socketPathOverride
            if running {
                try await AppleContainerControl.startServices(cliOverride: override)
                await reconnectAppleHosts()
            } else {
                try await AppleContainerControl.stopServices(cliOverride: override)
            }
        case .setContainer(let hostID, let name, let running):
            let host = try LiveFleet.host(hostID)
            let containers = try await LiveFleet.containers(on: host)
            guard let container = containers.first(where: { $0.displayName == name }) else {
                throw HeadlessDockerError.containerNotFound(name)
            }
            try await LiveFleet.perform(running ? .start : .stop, hostID: hostID, containerID: container.id)
            await LiveFleet.refresh(hostID)
        }
    }

    /// After a start, the apple hosts can connect again.
    private static func reconnectAppleHosts() async {
        for session in LiveFleet.model?.sessions ?? [] where session.host.isAppleContainer && !session.status.isConnected {
            await session.connect()
        }
    }
}
