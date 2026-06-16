import Foundation
import LocalAuthentication

/// Optional Touch ID / password confirmation in front of destructive actions
/// (removing a container, deleting a host). Off by default; the user opts in
/// from Settings ▸ General.
enum BiometricGate {
    /// Preference key for the General settings toggle.
    static let preferenceKey = "requireBiometricsForDestructive"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: preferenceKey)
    }

    /// Returns true when the action may proceed. When the gate is off this is an
    /// immediate yes; otherwise it asks LocalAuthentication to authenticate the
    /// device owner (Touch ID, falling back to the login password) and returns
    /// whether that succeeded. If no authentication is available at all, it
    /// fails closed (the destructive action is blocked).
    static func confirm(_ reason: String) async -> Bool {
        guard isEnabled else { return true }

        let context = LAContext()
        context.localizedFallbackTitle = "Enter Password"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}
