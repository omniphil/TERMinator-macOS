import SwiftUI

/// Terminal and app theme colors matching the Android version.
extension Color {
    // MARK: - App Theme Colors
    // Note: Using "app" prefix to avoid conflict with SwiftUI's built-in Color.primary

    /// Primary accent color - bright cyan/blue
    static let appPrimary = Color(red: 0, green: 0.667, blue: 1) // #00AAFF

    /// Dark primary variant
    static let appPrimaryDark = Color(red: 0, green: 0.533, blue: 0.867) // #0088DD

    /// Light primary variant
    static let appPrimaryLight = Color(red: 0.588, green: 0.933, blue: 0.973) // #96EEF8

    /// Accent color - bright green/cyan
    static let accent = Color(red: 0, green: 1, blue: 0.667) // #00FFAA

    /// Logo "TERM" stripe color - dark blue
    static let logoTermColor = Color(red: 0.2, green: 0.314, blue: 0.58) // #335094

    // MARK: - DOS 16-Color Palette

    static let termBlack = Color(red: 0, green: 0, blue: 0) // #000000
    static let termBlue = Color(red: 0, green: 0, blue: 0.667) // #0000AA
    static let termGreen = Color(red: 0, green: 0.667, blue: 0) // #00AA00
    static let termCyan = Color(red: 0, green: 0.667, blue: 0.667) // #00AAAA
    static let termRed = Color(red: 0.667, green: 0, blue: 0) // #AA0000
    static let termMagenta = Color(red: 0.667, green: 0, blue: 0.667) // #AA00AA
    static let termBrown = Color(red: 0.667, green: 0.333, blue: 0) // #AA5500
    static let termLightGray = Color(red: 0.667, green: 0.667, blue: 0.667) // #AAAAAA
    static let termDarkGray = Color(red: 0.333, green: 0.333, blue: 0.333) // #555555
    static let termLightBlue = Color(red: 0.333, green: 0.333, blue: 1) // #5555FF
    static let termLightGreen = Color(red: 0.333, green: 1, blue: 0.333) // #55FF55
    static let termLightCyan = Color(red: 0.333, green: 1, blue: 1) // #55FFFF
    static let termLightRed = Color(red: 1, green: 0.333, blue: 0.333) // #FF5555
    static let termLightMagenta = Color(red: 1, green: 0.333, blue: 1) // #FF55FF
    static let termYellow = Color(red: 1, green: 1, blue: 0.333) // #FFFF55
    static let termWhite = Color(red: 1, green: 1, blue: 1) // #FFFFFF

    // MARK: - UI Colors

    // MARK: - UI Colors (matching Windows RetroTheme)

    /// Background dark - #0D0D1A
    static let background = Color(red: 0.051, green: 0.051, blue: 0.102)

    /// Background medium - #1A1A2E
    static let backgroundMedium = Color(red: 0.102, green: 0.102, blue: 0.180)

    /// Background light - #25253A
    static let backgroundLight = Color(red: 0.145, green: 0.145, blue: 0.227)

    /// Surface color - #16213E
    static let surface = Color(red: 0.086, green: 0.129, blue: 0.243)

    /// Darker background for CRT effects
    static let crtBackground = Color(red: 0.031, green: 0.075, blue: 0.125) // #081320

    /// Card/panel background (same as backgroundMedium)
    static let cardBackground = Color(red: 0.102, green: 0.102, blue: 0.180)

    /// Text on background
    static let onBackground = Color(red: 0.878, green: 0.941, blue: 1) // #E0F0FF

    /// Primary text - #CCCCCC
    static let textPrimary = Color(red: 0.8, green: 0.8, blue: 0.8)

    /// Secondary text color - #888899
    static let textSecondary = Color(red: 0.533, green: 0.533, blue: 0.6)

    /// Control button inactive color
    static let ctrlButtonInactive = Color(red: 0.2, green: 0.2, blue: 0.333) // #333355

    /// Border color - #2A2A4A
    static let panelBorder = Color(red: 0.165, green: 0.165, blue: 0.290)

    /// Border highlight - #3A3A5C
    static let borderHighlight = Color(red: 0.227, green: 0.227, blue: 0.361)

    /// Section header background
    static let sectionHeader = Color(red: 0.055, green: 0.11, blue: 0.165) // #0E1C2A

    /// Amber accent - #FFAA00
    static let amberAccent = Color(red: 1, green: 0.667, blue: 0)

    /// Dimmer amber - #CC8800
    static let amberAccentDim = Color(red: 0.8, green: 0.533, blue: 0)

    /// Accent green bright - #33FF33
    static let accentGreen = Color(red: 0.2, green: 1, blue: 0.2)

    /// Accent green dim - #00AA00
    static let accentGreenDim = Color(red: 0, green: 0.667, blue: 0)

    /// Accent red - #FF3333
    static let accentRed = Color(red: 1, green: 0.2, blue: 0.2)
}

/// Convenience accessors for common UI color needs
extension Color {
    /// The main green color used for retro terminal text
    static var retroGreen: Color { .termLightGreen }

    /// The accent color used for buttons and highlights
    static var retroAccent: Color { .logoTermColor }

    /// Grid pattern color
    static var gridColor: Color { .termGreen.opacity(0.1) }
}

/// Home screen card and ticker colors added with the 1.1.0 layout overhaul (Windows RetroTheme).
extension Color {
    /// Splash card outline - #FF2BD6
    static let cardMagenta = Color(red: 1, green: 0.169, blue: 0.839)

    /// Quick Connect card outline - #22E6FF
    static let cardCyan = Color(red: 0.133, green: 0.902, blue: 1)

    /// Shortcuts card outline and the card drop-shadow glow - #7B5CFF
    static let cardViolet = Color(red: 0.482, green: 0.361, blue: 1)

    /// History ticker / facts text - #55DD55
    static let tickerGreen = Color(red: 0.333, green: 0.867, blue: 0.333)

    /// History ticker text while hovered - #9CFF9C
    static let tickerGreenBright = Color(red: 0.612, green: 1, blue: 0.612)
}

/// Hacker flair colors added with 1.1.0 (spec §5).
extension Color {
    /// Boot screen and connection log background - #050508. Also the command line's ground.
    static let deepBlack = Color(red: 0.020, green: 0.020, blue: 0.031)

    /// Boot screen "press any key to skip" hint - #555566
    static let bootHint = Color(red: 0.333, green: 0.333, blue: 0.400)
}
