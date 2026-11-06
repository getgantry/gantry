import SwiftUI

/// "N new lines" next to a paused log, so the user sees that Resume has more.
struct HeldLinesLabel: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("\(count) new lines")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.orange)
        }
    }
}
