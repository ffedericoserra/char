import AppKit

/// Edit the light/dark palettes below, then rebuild to try your changes.
@MainActor
struct ThemePalette {
    let editorBackground: NSColor
    let sidebarBackground: NSColor
    let text: NSColor
    let sidebarText: NSColor
    let secondaryText: NSColor
    let icons: NSColor
    let divider: NSColor
    // Empty family uses the system font. Settings overrides the editor family.
    var editorFontFamily = ""
    var sidebarFont: NSFont = .systemFont(ofSize: 13)
    var titleFont: NSFont = .systemFont(ofSize: 14, weight: .bold)
    var statusFont: NSFont = .systemFont(ofSize: 15)

    static let light = ThemePalette(
        editorBackground: NSColor(white: 1, alpha: 1),
        sidebarBackground: NSColor(white: 0.965, alpha: 1),
        text: NSColor(white: 0.22, alpha: 1),
        sidebarText: NSColor(white: 0.15, alpha: 1),
        secondaryText: NSColor(white: 0.4, alpha: 1),
        icons: NSColor(white: 0.45, alpha: 1),
        divider: NSColor(white: 0.88, alpha: 1),
        editorFontFamily: "",
        sidebarFont: .systemFont(ofSize: 13),
        titleFont: .systemFont(ofSize: 14, weight: .bold),
        statusFont: .systemFont(ofSize: 15)
    )

    static let dark = ThemePalette(
        editorBackground: NSColor(white: 0.12, alpha: 1),
        sidebarBackground: NSColor(white: 0.095, alpha: 1),
        text: NSColor(white: 0.88, alpha: 1),
        sidebarText: NSColor(white: 0.85, alpha: 1),
        secondaryText: NSColor(white: 0.62, alpha: 1),
        icons: NSColor(white: 0.65, alpha: 1),
        divider: NSColor(white: 0.24, alpha: 1),
        editorFontFamily: "",
        sidebarFont: .systemFont(ofSize: 13),
        titleFont: .systemFont(ofSize: 14, weight: .bold),
        statusFont: .systemFont(ofSize: 15)
    )
}

@MainActor
enum AppTheme {
    static var isDark: Bool { UserDefaults.standard.bool(forKey: "darkTheme") }
    static var palette: ThemePalette { isDark ? .dark : .light }

    static func toggle() {
        UserDefaults.standard.set(!isDark, forKey: "darkTheme")
        apply()
    }

    static func apply() {
        NSApp.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        for window in NSApp.windows {
            (window.windowController as? EditorWindowController)?.applyTheme()
        }
    }
}
