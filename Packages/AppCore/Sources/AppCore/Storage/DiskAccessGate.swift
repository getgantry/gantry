import Foundation

/// Touches a path the way a real access does. On a removable or external
/// disk the first touch can block while macOS asks for access (TCC).
public protocol DiskAccessProbing: Sendable {
    /// Blocks until the path can be read, or throws.
    func probe(_ path: String) throws
}

/// Lists the nearest folder of `path` that exists: this is the access that
/// makes macOS ask for "files on a removable volume".
public struct FileSystemDiskAccessProbe: DiskAccessProbing {
    public init() {}

    public func probe(_ path: String) throws {
        let fm = FileManager.default
        var current = StoragePaths.normalized(path)
        let stop = StoragePaths.volumeMountPoint(of: path) ?? "/"
        while !fm.fileExists(atPath: current), current != stop, current != "/" {
            current = (current as NSString).deletingLastPathComponent
        }
        _ = try fm.contentsOfDirectory(atPath: current)
    }
}

/// The settings pane where the user allows disk access.
public enum DiskAccessSettings {
    /// Privacy & Security > Files and Folders.
    public static let filesAndFoldersURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
    )!
}

/// A disk access that takes longer than the timeout: most likely macOS
/// shows a permission dialog. The UI shows a hint and can cancel the wait.
public final class DiskAccessWait: Identifiable, @unchecked Sendable {
    public let id = UUID()
    public let path: String
    public let diskName: String

    private let lock = NSLock()
    private var cancelled = false
    private var continuations: [CheckedContinuation<Void, Error>] = []

    public init(path: String) {
        self.path = StoragePaths.normalized(path)
        self.diskName = StoragePaths.volumeName(of: path) ?? (path as NSString).lastPathComponent
    }

    public var message: String {
        String(localized: "macOS is asking for permission to use the disk “\(diskName)”. Answer the dialog, or allow access in System Settings > Privacy & Security > Files and Folders.", bundle: .module)
    }

    /// Stops the wait; the operation that waits throws `CancellationError`.
    public func cancel() {
        let pending: [CheckedContinuation<Void, Error>] = lock.withLock {
            cancelled = true
            defer { continuations = [] }
            return continuations
        }
        for next in pending { next.resume(throwing: CancellationError()) }
    }

    public var isCancelled: Bool { lock.withLock { cancelled } }

    /// Returns only by throwing when ``cancel()`` is called.
    func untilCancelled() async throws {
        try await withCheckedThrowingContinuation { (next: CheckedContinuation<Void, Error>) in
            let already: Bool = lock.withLock {
                if cancelled { return true }
                continuations.append(next)
                return false
            }
            if already { next.resume(throwing: CancellationError()) }
        }
    }
}

/// The result of a quick access check.
public enum DiskAccessState: Sendable, Equatable {
    case accessible
    /// The access did not finish in time; macOS probably asks for access.
    case waitingForPermission(diskName: String)
    case failed(String)
}

/// Runs the first access to an external path off the main thread with a
/// timeout. Paths outside `/Volumes` pass at once. A disk that answered
/// once is not probed again in this run.
public final class DiskAccessGate: @unchecked Sendable {
    public static let shared = DiskAccessGate()

    public let probe: any DiskAccessProbing
    public let timeout: Duration
    private let lock = NSLock()
    private var granted = Set<String>()

    public init(probe: any DiskAccessProbing = FileSystemDiskAccessProbe(), timeout: Duration = .seconds(5)) {
        self.probe = probe
        self.timeout = timeout
    }

    /// True when `path` needs a probe: on an external disk not yet granted.
    public func needsProbe(_ path: String) -> Bool {
        guard let mount = StoragePaths.volumeMountPoint(of: path) else { return false }
        return lock.withLock { !granted.contains(mount) }
    }

    private func markGranted(_ path: String) {
        guard let mount = StoragePaths.volumeMountPoint(of: path) else { return }
        _ = lock.withLock { granted.insert(mount) }
    }

    /// Starts the probe on a background thread. A blocked system call
    /// cannot be stopped, so the probe is left to finish on its own; the
    /// caller only waits for the first of probe, timeout or cancel.
    private func startProbe(_ path: String, into race: OneShot<Result<Void, Error>?>) {
        let probe = self.probe
        // GCD, not a Swift task: a blocked call must not hold a thread of
        // the small cooperative pool that runs the timeout.
        DispatchQueue.global(qos: .userInitiated).async {
            do { try probe.probe(path); race.fire(.success(())) } catch { race.fire(.failure(error)) }
        }
    }

    /// A quick check for the UI: waits at most the timeout.
    public func check(_ path: String) async -> DiskAccessState {
        guard needsProbe(path) else { return .accessible }
        let race = OneShot<Result<Void, Error>?>()
        startProbe(path, into: race)
        let timeout = self.timeout
        let timer = Task { try? await Task.sleep(for: timeout); race.fire(nil) }
        let result = await race.wait()
        timer.cancel()
        switch result {
        case .success?:
            markGranted(path)
            return .accessible
        case .failure(let error)?:
            return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        case nil:
            return .waitingForPermission(diskName: DiskAccessWait(path: path).diskName)
        }
    }

    /// Waits until every path can be used. After the timeout `onSlow` gets
    /// a ``DiskAccessWait`` that the UI shows and can cancel; `onDone` is
    /// called when that wait ends either way. Throws on cancel or failure.
    public func waitForAccess(
        _ paths: [String],
        onSlow: @escaping @Sendable (DiskAccessWait) async -> Void,
        onDone: @escaping @Sendable (DiskAccessWait) async -> Void = { _ in }
    ) async throws {
        var seen = Set<String>()
        for path in paths where needsProbe(path) {
            guard let mount = StoragePaths.volumeMountPoint(of: path), seen.insert(mount).inserted else { continue }
            try await waitForAccess(path, onSlow: onSlow, onDone: onDone)
        }
    }

    private func waitForAccess(
        _ path: String,
        onSlow: @escaping @Sendable (DiskAccessWait) async -> Void,
        onDone: @escaping @Sendable (DiskAccessWait) async -> Void
    ) async throws {
        let wait = DiskAccessWait(path: path)
        let race = OneShot<Result<Void, Error>?>()
        startProbe(path, into: race)
        let timeout = self.timeout
        let slow = SlowFlag()
        let timer = Task {
            try await Task.sleep(for: timeout)
            slow.set()
            await onSlow(wait)
            do { try await wait.untilCancelled() } catch { race.fire(.failure(CancellationError())) }
        }
        let result = await withTaskCancellationHandler {
            await race.wait()
        } onCancel: {
            race.fire(.failure(CancellationError()))
        }
        timer.cancel()
        wait.cancel()
        if slow.isSet { await onDone(wait) }
        try result?.get()
        markGranted(path)
    }
}

/// A value that the first of several racers sets; later sets do nothing.
final class OneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var fired = false
    private var waiters: [CheckedContinuation<Value, Never>] = []

    func fire(_ newValue: Value) {
        let pending: [CheckedContinuation<Value, Never>] = lock.withLock {
            guard !fired else { return [] }
            fired = true
            value = newValue
            defer { waiters = [] }
            return waiters
        }
        for waiter in pending { waiter.resume(returning: newValue) }
    }

    func wait() async -> Value {
        await withCheckedContinuation { (next: CheckedContinuation<Value, Never>) in
            let ready: Value?? = lock.withLock {
                if fired { return .some(value) }
                waiters.append(next)
                return .none
            }
            if case .some(let done) = ready { next.resume(returning: done!) }
        }
    }
}

/// A flag set once from a child task.
private final class SlowFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
