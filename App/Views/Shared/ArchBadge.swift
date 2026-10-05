import SwiftUI
import DockerKit

/// Small orange capsule flagging containers/images whose platform differs
/// from the host daemon's architecture (the foreign-arch indicator Docker
/// Desktop renders next to amd64 images on Apple Silicon).
struct ArchBadge: View {
    let architecture: String
    let hostArchitecture: String

    var body: some View {
        // Unknown on either side shows nothing; `architecturesEquivalent`
        // never matches an empty string, so both guards are needed.
        if !architecture.isEmpty
            && !hostArchitecture.isEmpty
            && !SystemInfo.architecturesEquivalent(architecture, hostArchitecture)
        {
            BadgePill(
                text: architecture,
                tint: .orange,
                font: .caption2.weight(.semibold),
                opacity: 0.22,
                horizontalPadding: 5,
                verticalPadding: 1
            )
            .help("Runs under emulation: image architecture differs from the host (\(hostArchitecture)).")
        }
    }
}
