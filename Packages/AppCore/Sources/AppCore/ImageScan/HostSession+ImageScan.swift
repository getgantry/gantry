import Foundation
import DockerKit

extension HostSession {
    /// The plan kind of this host.
    var imageScanHostKind: ImageScanPlan.HostKind {
        if host.isAppleContainer { return .apple }
        return host.isSSH ? .remoteDocker : .localDocker
    }

    /// How an image of this host is scanned, or nil when it cannot be.
    public func imageScanPlan(for image: ImageSummary) -> ImageScanPlan? {
        ImageScanPlan.make(
            host: imageScanHostKind,
            id: image.id,
            repoTags: image.repoTags,
            os: image.os,
            architecture: image.architecture,
            fallbackArchitecture: info?.architecture ?? ""
        )
    }

    /// The scan model for an image, or nil when the image cannot be scanned.
    public func makeImageScanModel(for image: ImageSummary) -> ImageScanModel? {
        guard let plan = imageScanPlan(for: image) else { return nil }
        return ImageScanModel(plan: plan, export: imageScanExport(for: plan))
    }

    /// Writes the archive of an export plan.
    func imageScanExport(for plan: ImageScanPlan, runner: ScanProcessRunning = ChildProcessScanRunner()) -> ImageScanExport? {
        switch plan {
        case .appleArchive(let reference, let platform):
            return ImageScanModel.appleExport(
                reference: reference, platform: platform, cliOverride: storageCLIOverride, runner: runner
            )
        case .dockerArchive(let reference):
            return { [weak self] path in
                guard let self else { throw CancellationError() }
                try await self.saveImages([reference], to: path)
            }
        case .registry:
            return nil
        }
    }
}

extension ImageScanModel {
    /// `container image save --platform` into the archive path.
    public static func appleExport(
        reference: String,
        platform: String?,
        cliOverride: String? = nil,
        runner: ScanProcessRunning = ChildProcessScanRunner()
    ) -> ImageScanExport {
        { path in
            guard let cli = AppleContainerControl.cliPath(override: cliOverride) else {
                throw AppleControlError.cliNotFound
            }
            let arguments = ScanCommand.appleSaveArguments(reference: reference, platform: platform, to: path)
            let result = try await runner.run(cli, arguments)
            guard result.succeeded else {
                throw AppleContainerControl.commandError(
                    arguments: arguments,
                    stdout: String(decoding: result.stdout, as: UTF8.self),
                    stderr: String(decoding: result.stderr, as: UTF8.self)
                )
            }
        }
    }
}
