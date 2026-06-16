import AppKit
import SwiftTerm

/// A color theme for the embedded terminal: default fg/bg plus the 16 ANSI
/// palette entries. "System" follows the macOS text colors for light/dark; the
/// rest are fixed palettes.
struct TerminalTheme: Identifiable, Hashable {
    let id: String
    let name: String
    /// When true, fg/bg track the system appearance instead of `background`/`foreground`.
    let followsSystem: Bool
    let background: RGB
    let foreground: RGB
    /// Exactly 16 entries: normal 0–7 then bright 8–15.
    let ansi: [RGB]

    struct RGB: Hashable {
        let r: UInt8, g: UInt8, b: UInt8
        init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
        var nsColor: NSColor {
            NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
        var swiftTerm: SwiftTerm.Color {
            SwiftTerm.Color(red: UInt16(r) * 257, green: UInt16(g) * 257, blue: UInt16(b) * 257)
        }
    }

    static let preferenceKey = "terminalTheme"

    static let all: [TerminalTheme] = [system, solarizedDark, dracula, nord]

    static func theme(id: String) -> TerminalTheme {
        all.first { $0.id == id } ?? system
    }

    /// Applies the theme to a live SwiftTerm view.
    func apply(to view: SwiftTerm.TerminalView) {
        view.installColors(ansi.map(\.swiftTerm))
        if followsSystem {
            view.nativeBackgroundColor = .textBackgroundColor
            view.nativeForegroundColor = .textColor
        } else {
            view.nativeBackgroundColor = background.nsColor
            view.nativeForegroundColor = foreground.nsColor
        }
    }

    // MARK: - Palettes

    /// Standard xterm 16-color palette, used by the System theme.
    private static let xterm: [RGB] = [
        RGB(0, 0, 0), RGB(205, 0, 0), RGB(0, 205, 0), RGB(205, 205, 0),
        RGB(0, 0, 238), RGB(205, 0, 205), RGB(0, 205, 205), RGB(229, 229, 229),
        RGB(127, 127, 127), RGB(255, 0, 0), RGB(0, 255, 0), RGB(255, 255, 0),
        RGB(92, 92, 255), RGB(255, 0, 255), RGB(0, 255, 255), RGB(255, 255, 255)
    ]

    static let system = TerminalTheme(
        id: "system", name: "System", followsSystem: true,
        background: RGB(0, 0, 0), foreground: RGB(255, 255, 255), ansi: xterm
    )

    static let solarizedDark = TerminalTheme(
        id: "solarized-dark", name: "Solarized Dark", followsSystem: false,
        background: RGB(0, 43, 54), foreground: RGB(131, 148, 150),
        ansi: [
            RGB(7, 54, 66), RGB(220, 50, 47), RGB(133, 153, 0), RGB(181, 137, 0),
            RGB(38, 139, 210), RGB(211, 54, 130), RGB(42, 161, 152), RGB(238, 232, 213),
            RGB(0, 43, 54), RGB(203, 75, 22), RGB(88, 110, 117), RGB(101, 123, 131),
            RGB(131, 148, 150), RGB(108, 113, 196), RGB(147, 161, 161), RGB(253, 246, 227)
        ]
    )

    static let dracula = TerminalTheme(
        id: "dracula", name: "Dracula", followsSystem: false,
        background: RGB(40, 42, 54), foreground: RGB(248, 248, 242),
        ansi: [
            RGB(33, 34, 44), RGB(255, 85, 85), RGB(80, 250, 123), RGB(241, 250, 140),
            RGB(189, 147, 249), RGB(255, 121, 198), RGB(139, 233, 253), RGB(248, 248, 242),
            RGB(98, 114, 164), RGB(255, 110, 103), RGB(90, 247, 142), RGB(244, 249, 157),
            RGB(202, 169, 250), RGB(255, 146, 208), RGB(154, 237, 254), RGB(255, 255, 255)
        ]
    )

    static let nord = TerminalTheme(
        id: "nord", name: "Nord", followsSystem: false,
        background: RGB(46, 52, 64), foreground: RGB(216, 222, 233),
        ansi: [
            RGB(59, 66, 82), RGB(191, 97, 106), RGB(163, 190, 140), RGB(235, 203, 139),
            RGB(129, 161, 193), RGB(180, 142, 173), RGB(136, 192, 208), RGB(229, 233, 240),
            RGB(76, 86, 106), RGB(191, 97, 106), RGB(163, 190, 140), RGB(235, 203, 139),
            RGB(129, 161, 193), RGB(180, 142, 173), RGB(143, 188, 187), RGB(236, 239, 244)
        ]
    )
}
