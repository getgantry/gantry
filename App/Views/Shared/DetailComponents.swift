import SwiftUI

/// A single label/value fact rendered as one row inside a `FactGrid`.
struct Fact: Identifiable {
    let id = UUID()
    let label: Text
    let value: String
    /// Monospaced value, for ids, versions, addresses and paths.
    var monospaced = false
    /// Shows a copy button next to the value.
    var copyable = false

    /// A literal label is a catalog key.
    init(_ label: LocalizedStringKey, _ value: String, monospaced: Bool = false, copyable: Bool = false) {
        self.label = Text(label)
        self.value = value
        self.monospaced = monospaced
        self.copyable = copyable
    }

    /// A label that is already localized, for example from `String(localized:)`.
    @_disfavoredOverload
    init<S: StringProtocol>(_ label: S, _ value: String, monospaced: Bool = false, copyable: Bool = false) {
        self.label = Text(verbatim: String(label))
        self.value = value
        self.monospaced = monospaced
        self.copyable = copyable
    }
}

/// A two-column, label/value grid for facts in detail panes.
struct FactGrid: View {
    private let facts: [Fact]

    init(@FactBuilder _ content: () -> [Fact]) {
        self.facts = content()
    }

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
            ForEach(facts) { fact in
                GridRow {
                    fact.label
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    value(fact)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }
        }
    }
}

extension FactGrid {
    @ViewBuilder
    fileprivate func value(_ fact: Fact) -> some View {
        if fact.copyable {
            CopyableValue(value: fact.value, monospaced: fact.monospaced)
        } else {
            Text(verbatim: fact.value)
                .font(fact.monospaced ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
        }
    }
}

/// Result builder collecting optional `Fact` rows into a flat `[Fact]`.
@resultBuilder
enum FactBuilder {
    static func buildBlock(_ components: [Fact]...) -> [Fact] {
        components.flatMap { $0 }
    }

    static func buildExpression(_ expression: Fact) -> [Fact] {
        [expression]
    }

    static func buildExpression(_ expression: Fact?) -> [Fact] {
        expression.map { [$0] } ?? []
    }

    static func buildOptional(_ component: [Fact]?) -> [Fact] {
        component ?? []
    }

    static func buildEither(first component: [Fact]) -> [Fact] { component }
    static func buildEither(second component: [Fact]) -> [Fact] { component }

    static func buildArray(_ components: [[Fact]]) -> [Fact] {
        components.flatMap { $0 }
    }
}

/// A consistent section title used above fact grids and lists in detail panes.
struct SectionTitle: View {
    let text: Text
    init(_ text: LocalizedStringKey) { self.text = Text(text) }
    @_disfavoredOverload
    init<S: StringProtocol>(_ text: S) { self.text = Text(verbatim: String(text)) }
    init(text: Text) { self.text = text }

    var body: some View {
        text
            .font(.headline)
            .padding(.bottom, 2)
    }
}

/// A titled block for detail panes. Works in a plain `VStack`/`ScrollView`
/// (unlike SwiftUI's `Section`, which requires a `List` or `Form`).
struct DetailSection<Content: View>: View {
    let title: Text
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = Text(title)
        self.content = content()
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) {
        self.title = Text(verbatim: String(title))
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: title)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small pill badge used for boolean/enum attributes (e.g. network flags) and
/// status indicators. The font/padding/opacity are tunable so list rows can use
/// a compact form while detail headers use a larger one, all sharing the single
/// tinted-capsule rendering.
struct BadgePill: View {
    let text: Text
    var tint: Color = .accentColor
    var font: Font = .caption.weight(.medium)
    var opacity: Double = 0.16
    var horizontalPadding: CGFloat = 8
    var verticalPadding: CGFloat = 3

    init(
        text: LocalizedStringKey, tint: Color = .accentColor, font: Font = .caption.weight(.medium),
        opacity: Double = 0.16, horizontalPadding: CGFloat = 8, verticalPadding: CGFloat = 3
    ) {
        self.init(
            text: Text(text), tint: tint, font: font, opacity: opacity,
            horizontalPadding: horizontalPadding, verticalPadding: verticalPadding
        )
    }

    /// A text that is already localized, or data such as a status from a CLI.
    @_disfavoredOverload
    init<S: StringProtocol>(
        text: S, tint: Color = .accentColor, font: Font = .caption.weight(.medium),
        opacity: Double = 0.16, horizontalPadding: CGFloat = 8, verticalPadding: CGFloat = 3
    ) {
        self.init(
            text: Text(verbatim: String(text)), tint: tint, font: font, opacity: opacity,
            horizontalPadding: horizontalPadding, verticalPadding: verticalPadding
        )
    }

    init(
        text: Text, tint: Color, font: Font, opacity: Double,
        horizontalPadding: CGFloat, verticalPadding: CGFloat
    ) {
        self.text = text
        self.tint = tint
        self.font = font
        self.opacity = opacity
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
    }

    var body: some View {
        text
            .font(font)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(tint.opacity(opacity), in: .capsule)
            .foregroundStyle(tint)
    }
}
