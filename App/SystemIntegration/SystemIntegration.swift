import Foundation
import Observation
import WidgetKit
import AppCore
import GantryShared
import os

/// Keeps the widget snapshot, the controls and the Spotlight index in step
/// with the model. Changes in host state or container lists start a publish
/// after `delay`; more changes during the wait join the same publish.
@MainActor
final class SystemIntegration {
    static let shared = SystemIntegration()
    private static let log = Logger(subsystem: "com.andrewkomkov.Gantry", category: "SystemIntegration")
    private static let tokenKey = "widgetControlToken"
    private static let appleCheckInterval: Duration = .seconds(60)

    /// A random secret that the controls send back (see `ControlRequest`).
    static var controlToken: String {
        if let token = UserDefaults.standard.string(forKey: tokenKey), !token.isEmpty { return token }
        let token = UUID().uuidString + UUID().uuidString
        UserDefaults.standard.set(token, forKey: tokenKey)
        return token
    }

    private weak var model: AppModel?
    private let store = SnapshotStore.standard()
    private let spotlight = SpotlightIndexer()
    private var lastSnapshot: FleetSnapshot?
    private var pending: Task<Void, Never>?
    private var pendingDeadline: ContinuousClock.Instant?
    private var appleServicesRunning: Bool?
    private var lastAppleCheck: ContinuousClock.Instant?
    private var checkAppleNext = true

    func attach(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        LiveFleet.model = model
        observe()
        publishSoon(checkAppleServices: true, delay: .seconds(1))
    }

    private func observe() {
        guard let model else { return }
        withObservationTracking {
            for session in model.sessions {
                _ = session.status
                _ = session.containers
            }
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.publishSoon()
                self?.observe()
            }
        }
    }

    /// Starts a publish after `delay`, unless one is already due sooner.
    func publishSoon(checkAppleServices: Bool = false, delay: Duration = .seconds(3)) {
        if checkAppleServices { checkAppleNext = true }
        let deadline = ContinuousClock.now + delay
        if pending != nil, let pendingDeadline, pendingDeadline <= deadline { return }
        pending?.cancel()
        pendingDeadline = deadline
        pending = Task { [weak self] in
            try? await Task.sleep(until: deadline)
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            self.pendingDeadline = nil
            await self.publish()
        }
    }

    private func publish() async {
        guard let model else { return }
        await refreshAppleServices(model)
        let inputs = model.sessions.map {
            FleetSnapshotBuilder.HostInput(
                id: $0.id, name: $0.host.name, status: $0.status,
                isAppleContainer: $0.host.isAppleContainer, containers: $0.containers
            )
        }
        let snapshot = FleetSnapshotBuilder.build(
            hosts: inputs, appleServicesRunning: appleServicesRunning,
            controlToken: Self.controlToken, now: .now
        )
        if lastSnapshot.map({ !$0.hasSameContent(as: snapshot) }) ?? true {
            write(snapshot)
        }
        spotlight.update(from: model)
    }

    private func write(_ snapshot: FleetSnapshot) {
        do {
            try store.write(snapshot)
            lastSnapshot = snapshot
            WidgetCenter.shared.reloadTimelines(ofKind: SharedIdentifiers.fleetWidgetKind)
            ControlCenter.shared.reloadAllControls()
        } catch {
            Self.log.error("snapshot write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Asks the `container` CLI at most once a minute, or at once after a
    /// control changed the services.
    private func refreshAppleServices(_ model: AppModel) async {
        guard let apple = model.sessions.first(where: { $0.host.isAppleContainer }) else {
            appleServicesRunning = nil
            return
        }
        let due = lastAppleCheck.map { ContinuousClock.now - $0 >= Self.appleCheckInterval } ?? true
        guard checkAppleNext || due else { return }
        checkAppleNext = false
        lastAppleCheck = .now
        let status = await AppleContainerControl.serviceStatus(cliOverride: apple.host.socketPathOverride)
        switch status {
        case .running: appleServicesRunning = true
        case .stopped: appleServicesRunning = false
        case .unavailable, .unknown: appleServicesRunning = nil
        }
    }
}
