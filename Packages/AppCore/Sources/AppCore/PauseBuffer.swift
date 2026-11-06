import Foundation

/// Holds the log lines that arrive while a log view is paused, so Resume
/// shows them instead of losing them. Bounded: past `capacity` the oldest
/// held lines go, and ``dropped`` counts them.
public struct PauseBuffer<Element> {
    public let capacity: Int
    public private(set) var held: [Element] = []
    /// Lines that did not fit and were discarded since the last drain.
    public private(set) var dropped = 0

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// The number of lines that Resume would add.
    public var count: Int { held.count }

    public mutating func hold(_ element: Element) {
        held.append(element)
        if held.count > capacity {
            dropped += held.count - capacity
            held.removeFirst(held.count - capacity)
        }
    }

    /// Returns the held lines in arrival order and empties the buffer.
    public mutating func drain() -> [Element] {
        defer { reset() }
        return held
    }

    public mutating func reset() {
        held = []
        dropped = 0
    }
}
