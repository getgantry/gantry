import SwiftUI

/// A single label/value fact rendered as one row inside a `FactGrid`.
struct Fact: Identifiable {
    let id = UUID()
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
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
                    Text(fact.label)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    Text(fact.value)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }
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
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.headline)
            .padding(.bottom, 2)
    }
}

/// A titled block for detail panes. Works in a plain `VStack`/`ScrollView`
/// (unlike SwiftUI's `Section`, which requires a `List` or `Form`).
struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small pill badge used for boolean/enum attributes (e.g. network flags).
struct BadgePill: View {
    let text: String
    var tint: Color = .accentColor

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.16), in: .capsule)
            .foregroundStyle(tint)
    }
}
