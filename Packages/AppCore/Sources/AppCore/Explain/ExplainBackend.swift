import Foundation

/// Which model answers. Private Cloud Compute needs macOS 27 and the opt-in
/// setting; everything else stays on device.
public enum ExplainModelKind: String, Sendable, Equatable {
    case onDevice
    case privateCloud
}

/// Why Explain cannot run. The panel shows a reason for each and offers
/// Copy as Prompt instead.
public enum ExplainUnavailableReason: Sendable, Equatable {
    case turnedOff
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unsupportedLanguage
    case other(String)
}

public enum ExplainAvailability: Sendable, Equatable {
    case available(ExplainModelKind)
    case unavailable(ExplainUnavailableReason)
}

/// The user settings of the feature (UserDefaults keys).
public enum ExplainSettings {
    public static let enabledKey = "explainFailuresEnabled"
    public static let privateCloudKey = "explainUsePrivateCloud"

    public static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    public static var prefersPrivateCloud: Bool {
        UserDefaults.standard.bool(forKey: privateCloudKey)
    }
}

/// Parts of `docker inspect` that the model can ask for with a tool.
public enum ExplainInspectSection: String, Sendable, CaseIterable {
    case runtime, limits, mounts, network, healthcheck
}

/// Read-only data for the model tools. Each closure reads; none changes the
/// host. The tools redact what the closures return.
public struct ExplainDataSource: Sendable {
    public var logs: @Sendable (_ tail: Int) async throws -> [String]
    public var inspect: (@Sendable (ExplainInspectSection) async -> String?)?
    public var redactor: SecretRedactor

    public init(
        logs: @escaping @Sendable (Int) async throws -> [String],
        inspect: (@Sendable (ExplainInspectSection) async -> String?)? = nil,
        redactor: SecretRedactor = SecretRedactor()
    ) {
        self.logs = logs
        self.inspect = inspect
        self.redactor = redactor
    }

    /// Log lines for a tool answer: redacted, filtered, cut to `budget`.
    public func toolLogs(tail: Int, containing filter: String?, budget: Int = 1200) async throws -> [String] {
        let lines = redactor.redact(try await logs(min(max(tail, 20), 1000)))
        let needle = filter?.trimmingCharacters(in: .whitespaces) ?? ""
        let matched = needle.isEmpty ? lines : lines.filter { $0.localizedCaseInsensitiveContains(needle) }
        return SmartLogTail.select(matched, budget: budget)
    }
}

/// Explains a failure. The Foundation Models version is the real one; tests
/// use a fake.
public protocol FailureExplaining: Sendable {
    func explain(_ context: FailureContext, data: ExplainDataSource) async throws -> FailureExplanation
}
