import SwiftUI

// MARK: - Layout metrics

/// Every size of the home layout in unscaled layout units, and the natural footprint of each
/// layout (used for the scale-to-fit container, the window fit and the aspect lock).
///
/// The numbers are the Windows client's (`Views/HomeView.xaml` + `HomeView.SetSideBySide`),
/// so both clients fit the same window. Text rows carry explicit heights so the footprint is
/// exact rather than font-dependent.
enum HomeMetrics {
    static let cardRadius: CGFloat = 10
    /// Transparent border that only reserves the visible outline's width.
    static let cardBorder: CGFloat = 1.5
    static let cardPadding: CGFloat = 20
    /// The Quick Connect (stacked) and shortcuts cards use a tighter vertical padding.
    static let cardPaddingTight: CGFloat = 14

    // Splash card content (600 wide inner panel).
    static let splashPanelWidth: CGFloat = 600
    static let logoHeight: CGFloat = 80
    static let logoGap: CGFloat = 8
    /// Windows: the marquee Border is 26 high (Padding 0,4 + an 18-high canvas) with a 16 margin under it.
    static let marqueeHeight: CGFloat = CrtMarqueeView.stripHeight
    static let marqueeGap: CGFloat = 16
    /// splash_screen.png is 640x800, shown 450 high (Windows MaxHeight 450).
    static let splashArtSize = CGSize(width: 360, height: 450)
    static let splashArtGap: CGFloat = 16
    static let tickerHeight: CGFloat = 48

    static var splashContentHeight: CGFloat {
        logoHeight + logoGap + marqueeHeight + marqueeGap + splashArtSize.height + splashArtGap + tickerHeight
    }
    static var splashCardSize: CGSize {
        CGSize(width: splashPanelWidth + 2 * (cardPadding + cardBorder),
               height: splashContentHeight + 2 * (cardPadding + cardBorder))
    }

    // Quick Connect card.
    static func sidePanelWidth(sideBySide: Bool) -> CGFloat { sideBySide ? 420 : 600 }
    static let headingHeight: CGFloat = 14
    static let headingGap: CGFloat = 8
    static let tileContentSize = CGSize(width: 172, height: 150)
    static let snapshotSize = CGSize(width: 172, height: 129)
    /// Tile button = content + 4 padding + 2 border each side.
    static let tileInset: CGFloat = 6
    static var tileOuterSize: CGSize {
        CGSize(width: tileContentSize.width + 2 * tileInset, height: tileContentSize.height + 2 * tileInset)
    }
    static let connectGap: CGFloat = 6
    static let connectHeight: CGFloat = 30
    static let tileRowGap: CGFloat = 24
    static let tileColumnGap: CGFloat = 12
    /// One Quick Connect slot: tile + CONNECT button.
    static var slotHeight: CGFloat { tileOuterSize.height + connectGap + connectHeight }

    static func quickConnectPaddingV(sideBySide: Bool) -> CGFloat { sideBySide ? cardPadding : cardPaddingTight }
    /// The card's natural content height: heading + 1 row (stacked) or 2 rows (side-by-side).
    static func quickConnectContentHeight(sideBySide: Bool) -> CGFloat {
        headingHeight + headingGap + slotHeight + (sideBySide ? tileRowGap + slotHeight : 0)
    }
    static func quickConnectCardSize(sideBySide: Bool) -> CGSize {
        let width = sidePanelWidth(sideBySide: sideBySide) + 2 * (cardPadding + cardBorder)
        if sideBySide {
            // Stretched to the splash card's height; the shortcuts card sits below inside the column.
            return CGSize(width: width,
                          height: splashCardSize.height - cardGap - shortcutsCardSize(sideBySide: true).height)
        }
        return CGSize(width: width,
                      height: quickConnectContentHeight(sideBySide: false) + 2 * (cardPaddingTight + cardBorder))
    }

    // Shortcuts card.
    static let shortcutsRowWidth: CGFloat = 420
    static let shortcutTileHeight: CGFloat = 72
    static let shortcutTileMarginH: CGFloat = 5
    static let shortcutCount: CGFloat = 5
    static var shortcutTileWidth: CGFloat { shortcutsRowWidth / shortcutCount - 2 * shortcutTileMarginH }
    static func shortcutsCardSize(sideBySide: Bool) -> CGSize {
        CGSize(width: sidePanelWidth(sideBySide: sideBySide) + 2 * (cardPadding + cardBorder),
               height: shortcutTileHeight + 2 * (cardPaddingTight + cardBorder))
    }

    // Grid.
    /// Gap between the splash card and the side column (side-by-side), and between the
    /// splash card / Quick Connect card / shortcuts card (stacked).
    static let cardGap: CGFloat = 16
    static let sideBySideGap: CGFloat = 24
    static func layoutMargins(sideBySide: Bool) -> EdgeInsets {
        sideBySide ? EdgeInsets(top: 12, leading: 20, bottom: 20, trailing: 20)
                   : EdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20)
    }

    /// The whole layout, margins included: the shape the window's content area is fitted to.
    static func naturalSize(sideBySide: Bool) -> CGSize {
        let margins = layoutMargins(sideBySide: sideBySide)
        let splash = splashCardSize
        let quick = quickConnectCardSize(sideBySide: sideBySide)
        let shortcuts = shortcutsCardSize(sideBySide: sideBySide)
        if sideBySide {
            return CGSize(width: splash.width + sideBySideGap + quick.width + margins.leading + margins.trailing,
                          height: splash.height + margins.top + margins.bottom)
        }
        return CGSize(width: splash.width + margins.leading + margins.trailing,
                      height: splash.height + cardGap + quick.height + cardGap + shortcuts.height
                              + margins.top + margins.bottom)
    }

    static func aspectRatio(sideBySide: Bool) -> CGFloat {
        let size = naturalSize(sideBySide: sideBySide)
        return size.height > 0 ? size.width / size.height : 1
    }
}

// MARK: - Card

/// A home screen card: `#1A1A2E` surface, radius 10, a transparent 1.5 pt border that only
/// reserves the outline's width, a soft violet drop-shadow layer behind, and the visible
/// outline as a hit-test-invisible layer on top in the card's own color. Hovering anywhere
/// over the card thickens the outline 1.5 → 3 pt (growing inward) and fades a same-color glow
/// in (0 → 0.9 in 0.15 s, back to 0 in 0.2 s). Static otherwise — no strobe.
struct HomeCard<Content: View>: View {
    let outline: Color
    var padding: EdgeInsets = EdgeInsets(top: HomeMetrics.cardPadding, leading: HomeMetrics.cardPadding,
                                         bottom: HomeMetrics.cardPadding, trailing: HomeMetrics.cardPadding)
    @ViewBuilder let content: () -> Content

    @State private var isHovered = false
    @State private var glowOpacity: Double = 0

    var body: some View {
        content()
            .padding(padding)
            .padding(HomeMetrics.cardBorder)
            .background(
                // Separate, empty layer carrying the drop shadow: soft violet glow, blur 26 (≈ radius 13),
                // opacity 0.35, no offset. Kept apart from the card so the animated splash never renders
                // through a blur effect.
                RoundedRectangle(cornerRadius: HomeMetrics.cardRadius)
                    .fill(Color.backgroundMedium)
                    .shadow(color: Color.cardViolet.opacity(0.35), radius: 13, x: 0, y: 0)
            )
            .overlay(
                ZStack {
                    // Hover glow on both sides of the line (blur 14 ≈ radius 7).
                    RoundedRectangle(cornerRadius: HomeMetrics.cardRadius)
                        .strokeBorder(outline, lineWidth: 3)
                        .blur(radius: 7)
                        .opacity(glowOpacity)
                    RoundedRectangle(cornerRadius: HomeMetrics.cardRadius)
                        .strokeBorder(outline, lineWidth: isHovered ? 3 : HomeMetrics.cardBorder)
                }
                .allowsHitTesting(false)
            )
            .onHover { hovering in
                isHovered = hovering
                withAnimation(.easeOut(duration: hovering ? 0.15 : 0.2)) {
                    glowOpacity = hovering ? 0.9 : 0
                }
            }
    }
}

// MARK: - Tile button

/// Quick Connect tiles, shortcut tiles and phonebook entries share this hover look: background
/// `#1A1A2E`, border `#2A2A4A` 2 pt, corner 2, padding 4; on hover the border turns amber, the
/// background lifts to `#25253A` and an amber glow (blur 18 ≈ radius 9, opacity 0.75) comes on.
struct HomeTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HomeTileButtonBody(configuration: configuration)
    }
}

/// The style's body. `@State` only has storage inside a `View`: left in the `ButtonStyle` itself
/// it never updates, so the hover look never came on.
private struct HomeTileButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .padding(HomeMetrics.tileInset)
            .background(
                RoundedRectangle(cornerRadius: 2)
                    .fill(isHovered || configuration.isPressed ? Color.backgroundLight : Color.backgroundMedium)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(isHovered ? Color.amberAccent : Color.panelBorder, lineWidth: 2)
            )
            .shadow(color: isHovered ? Color.amberAccent.opacity(0.75) : .clear, radius: 9, x: 0, y: 0)
            .onHover { hovering in
                guard hovering != isHovered else { return }   // exactly one pop per push
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            // PHONEBOOK / SETTINGS take the whole home screen away while the pointer is still on the
            // tile and no exit event follows, which would leave the hand cursor stuck.
            .onDisappear {
                if isHovered {
                    isHovered = false
                    NSCursor.pop()
                }
            }
    }
}

/// The same hover treatment as `HomeTileButtonStyle`, for views that aren't buttons (the
/// phonebook tiles and list rows, which carry their own tap/drag gestures). `selected` keeps
/// a plain amber border with no glow; hovering still lifts the background and glows.
struct TileHoverModifier: ViewModifier {
    var selected: Bool = false
    var cornerRadius: CGFloat = 2
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(isHovered ? Color.backgroundLight : Color.backgroundMedium)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(isHovered || selected ? Color.amberAccent : Color.panelBorder, lineWidth: 2)
            )
            .shadow(color: isHovered ? Color.amberAccent.opacity(0.75) : .clear, radius: 9, x: 0, y: 0)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

extension View {
    /// Phonebook entry hover glow (every view mode). See `TileHoverModifier`.
    func tileHover(selected: Bool = false, cornerRadius: CGFloat = 2) -> some View {
        modifier(TileHoverModifier(selected: selected, cornerRadius: cornerRadius))
    }
}

// MARK: - Tooltip

/// Readable retro tooltip: `#1A1A2E` background, amber 1 pt border, radius 4, padding 8×4,
/// green `#33FF33` monospaced 12, drop shadow. Shown above the element after a short hover
/// delay. (SwiftUI's `.help()` uses the system tooltip, which can't be restyled and drew light
/// text on a light background.)
struct RetroTooltipModifier: ViewModifier {
    let text: String
    @State private var visible = false
    @State private var pending: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                pending?.cancel()
                if hovering {
                    let work = DispatchWorkItem { visible = true }
                    pending = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                } else {
                    visible = false
                }
            }
            .onDisappear {
                pending?.cancel()
                visible = false
            }
            .overlay(alignment: .top) {
                if visible {
                    Text(text)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.accentGreen)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.backgroundMedium)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.amberAccent, lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.6), radius: 6, x: 0, y: 2)
                        .fixedSize()
                        // Sit fully above the element with a 6 pt gap.
                        .alignmentGuide(.top) { d in d[.bottom] + 6 }
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .zIndex(10)
                }
            }
    }
}

extension View {
    /// App-wide readable tooltip (see `RetroTooltipModifier`).
    func retroTooltip(_ text: String) -> some View {
        modifier(RetroTooltipModifier(text: text))
    }
}

// MARK: - Cursor

/// Hand cursor while hovering, for clickable non-button elements (logo, splash art, ticker).
struct HandCursorModifier: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                guard hovering != isHovered else { return }   // exactly one pop per push
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            // Leaving the home screen while the pointer is still on the element sends no exit
            // event, which would leave the hand cursor stuck on the next screen.
            .onDisappear {
                if isHovered {
                    isHovered = false
                    NSCursor.pop()
                }
            }
    }
}

extension View {
    func handCursor() -> some View { modifier(HandCursorModifier()) }
}
