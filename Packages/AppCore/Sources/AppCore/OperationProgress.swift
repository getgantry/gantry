import Foundation

/// How far a long operation is: items done of a total (layers, build steps,
/// services) and bytes done of a total. Either part can be missing.
public struct OperationProgress: Equatable, Sendable {
    /// Countable parts of the work.
    public struct Items: Equatable, Sendable {
        public enum Unit: String, Sendable {
            case layers
            case steps
            case services
            case items
        }

        public var done: Int
        public var total: Int
        public var unit: Unit

        public init(done: Int, total: Int, unit: Unit) {
            self.total = max(total, 0)
            self.done = min(max(done, 0), self.total)
            self.unit = unit
        }

        public var fraction: Double? {
            total > 0 ? Double(done) / Double(total) : nil
        }

        /// "Layers: 3 of 7", "Step 2 of 5", "Services: 1 of 2", "4 of 9".
        public var text: String {
            switch unit {
            case .layers: String(localized: "Layers: \(done) of \(total)", bundle: .module)
            case .steps: String(localized: "Step \(done) of \(total)", bundle: .module)
            case .services: String(localized: "Services: \(done) of \(total)", bundle: .module)
            case .items: String(localized: "\(done) of \(total)", bundle: .module)
            }
        }
    }

    /// Transferred bytes.
    public struct Bytes: Equatable, Sendable {
        public var done: Int64
        public var total: Int64

        public init(done: Int64, total: Int64) {
            self.total = max(total, 0)
            self.done = min(max(done, 0), self.total)
        }

        public var fraction: Double? {
            total > 0 ? Double(done) / Double(total) : nil
        }

        /// "12.3 MB of 45 MB".
        public var text: String {
            let style = ByteCountFormatStyle(style: .file)
            return String(
                localized: "\(done.formatted(style)) of \(total.formatted(style))", bundle: .module,
                comment: "Bytes done of all bytes, for example 12 MB of 45 MB"
            )
        }
    }

    public var items: Items?
    public var bytes: Bytes?

    public init(items: Items? = nil, bytes: Bytes? = nil) {
        self.items = items
        self.bytes = bytes
    }

    public static let none = OperationProgress()

    public var isEmpty: Bool { items == nil && bytes == nil }

    /// The bytes fraction when known (it moves smoothly), else the items one.
    public var fraction: Double? {
        bytes?.fraction ?? items?.fraction
    }

    /// One line for a row: "Layers: 3 of 7 · 12 MB of 45 MB". Nil when empty.
    public var detailText: String? {
        let parts = [items?.text, bytes?.text].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
