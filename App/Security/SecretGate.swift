import Foundation
import LocalAuthentication

/// Optional Touch ID / password check before Gantry reads Keychain secrets
/// for a create. Off by default; the user turns it on in Settings ▸ Secrets.
enum SecretGate {
    static let preferenceKey = "requireBiometricsForSecrets"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: preferenceKey)
    }

    /// The closure for ``EnvSecrets/resolve(_:isAppleHost:store:authorize:)``,
    /// or nil when the setting is off. Fails closed when no authentication is
    /// available.
    static var authorize: (@Sendable () async -> Bool)? {
        guard isEnabled else { return nil }
        return {
            let context = LAContext()
            context.localizedFallbackTitle = String(localized: "Enter Password")
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
            let reason = String(localized: "use Keychain secrets for the new container")
            return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
        }
    }
}
