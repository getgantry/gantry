import SwiftUI
import AppCore

/// Spacing on the 8 pt grid, shared by cards, grids and detail panes.
enum Spacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 24

    static let cardRadius: CGFloat = 12
    static let cardPadding: CGFloat = 16
}

extension Formatters {
    /// A transfer rate, for example "1.2 MB/s".
    static func rate(_ bytesPerSecond: Double) -> String {
        let value = Int64(max(bytesPerSecond, 0).rounded())
        return String(localized: "\(bytes(value, style: .file))/s", comment: "A transfer rate; the argument is a size such as 1.2 MB")
    }

    /// A CPU figure where 100 is one core, for example "37%".
    static func cpu(_ percent: Double) -> String {
        (max(percent, 0) / 100).formatted(.percent.precision(.fractionLength(percent < 10 ? 1 : 0)))
    }
}

/// The content-layer surface of the dashboards: a standard fill (not glass,
/// which is for controls only) with a hairline under Increase Contrast.
struct CardBackground: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    var highlighted = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Spacing.cardRadius, style: .continuous)
        content
            .background(.quaternary.opacity(highlighted ? 0.75 : 0.5), in: shape)
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(Color.primary.opacity(0.35), lineWidth: 1)
                }
            }
    }
}

extension View {
    func cardBackground(highlighted: Bool = false) -> some View {
        modifier(CardBackground(highlighted: highlighted))
    }
}

/// A titled card: a hierarchical symbol, a headline, an optional trailing
/// accessory and the content.
struct DashboardCard<Accessory: View, Content: View>: View {
    let title: Text
    let systemImage: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(
        _ title: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = Text(title)
        self.systemImage = systemImage
        self.accessory = accessory()
        self.content = content()
    }

    @_disfavoredOverload
    init<S: StringProtocol>(
        _ title: S,
        systemImage: String,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = Text(verbatim: String(title))
        self.systemImage = systemImage
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.xs) {
                Label { title } icon: {
                    Image(systemName: systemImage)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tint)
                }
                .font(.headline)
                Spacer(minLength: Spacing.xs)
                accessory
            }
            content
        }
        .padding(Spacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .cardBackground()
    }
}

/// A status capsule with a symbol and a word, so state never depends on color.
struct StatusBadge: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label {
            Text(verbatim: text)
        } icon: {
            Image(systemName: systemImage)
                .imageScale(.small)
        }
        .labelStyle(.titleAndIcon)
        .font(.caption.weight(.medium))
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, 3)
        .background(tint.opacity(0.16), in: .capsule)
        .foregroundStyle(tint)
    }
}

/// A big number with a label and a symbol, for the count tiles.
struct StatTile: View {
    let value: String
    let label: String
    let systemImage: String
    var tint: Color = .secondary
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { tile }
                .buttonStyle(.plain)
                .help(Text(verbatim: label))
        } else {
            tile
        }
    }

    private var tile: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: systemImage)
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: value)
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText())
                Text(verbatim: label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
        .contentShape(RoundedRectangle(cornerRadius: Spacing.cardRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A value in a monospaced font with a copy button next to it.
struct CopyableValue: View {
    let value: String
    /// What the button copies; nil copies `value`.
    var copyText: String?
    var monospaced = true

    @State private var copied = false

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            Text(verbatim: value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Button {
                copyToPasteboard(copyText ?? value)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Copy")
            .accessibilityLabel("Copy")
        }
    }
}

/// A monospaced command in a box with a copy button, for hints that show a
/// command line.
struct CommandBox: View {
    let command: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.xs) {
            Text(verbatim: command)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                copyToPasteboard(command)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy Command")
            .accessibilityLabel("Copy Command")
        }
        .padding(Spacing.s)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
