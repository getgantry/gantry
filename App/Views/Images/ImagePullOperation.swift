import SwiftUI
import AppCore
import DockerKit

/// The pull of one image as an operation in Activity and the menu bar.
/// `PullImageSheet` and `ImageSearchSheet` start pulls through it.
enum ImagePullOperation {
    @MainActor
    @discardableResult
    static func start(
        reference: String,
        auth: RegistryAuth? = nil,
        platform: String? = nil,
        session: HostSession,
        onProgress: @escaping @MainActor (PullProgressTracker) -> Void = { _ in },
        onFinish: @escaping @MainActor (Error?) -> Void = { _ in }
    ) -> LongOperation {
        LongOperationRunner.run(.pull, title: String(localized: "Pull \(reference)"), session: session) { op in
            do {
                let stream = try await session.pullImage(reference: reference, auth: auth, platform: platform)
                // A local copy keeps counting after a sheet closes.
                var progress = PullProgressTracker()
                for try await update in stream {
                    progress.apply(update)
                    op.report(progress.progress, status: update.status, fraction: progress.fraction)
                    onProgress(progress)
                }
                try Task.checkCancellation()
                onFinish(nil)
                await session.refreshImages()
                return nil
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                onFinish(error)
                throw error
            }
        }
    }
}
