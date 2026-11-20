import SwiftUI

/// Home screen: splash card (logo, marquee, splash art, history ticker), Quick Connect card and
/// shortcuts card, in a stacked or side-by-side layout that scales uniformly with the window.
/// Mirrors the Windows client's HomeView (1.1.0 layout overhaul); sizes live in `HomeMetrics`.
struct HomeView: View {
    @StateObject private var store = BBSEntryStore.shared
    @EnvironmentObject var appState: AppState
    @ObservedObject private var crtStore = CrtSettingsStore.shared

    /// View > Side-by-Side Home Screen. The LAYOUT tile flips the same value, so the menu
    /// check, the saved setting and the window fit stay in step.
    @AppStorage(AppPreferences.homeSideBySide) private var sideBySide = false

    /// View > Phosphor (spec §7). Green / Amber / White turn the whole home screen into a monochrome
    /// tube; Color removes it. The CRT effect itself is never applied here — that lives on the Quick
    /// Connect thumbnails (`CrtThumbnailView`).
    @AppStorage(AppPreferences.phosphor) private var phosphor = PhosphorMode.color.rawValue

    // Quick Connect slots. 3–4 only show side-by-side but stay saved while hidden.
    @AppStorage("quick_connect_1_id") private var quickConnect1Id: String = ""
    @AppStorage("quick_connect_2_id") private var quickConnect2Id: String = ""
    @AppStorage("quick_connect_3_id") private var quickConnect3Id: String = ""
    @AppStorage("quick_connect_4_id") private var quickConnect4Id: String = ""

    // Quick connect picker
    @State private var showingQuickConnectPicker = false
    @State private var pickingSlot: Int = 0

    // Facts overlay (opened by clicking the history ticker)
    @State private var showingFacts = false

    // Glitch effect state
    @State private var glitchSlices: [GlitchSlice] = []
    @State private var majorGlitchTimer: Timer?

    /// Header logo click target. No tooltip.
    private static let headerLogoURL = URL(string: "https://deadmodemsociety.com/terminator/")
    /// Splash art click target. No tooltip.
    private static let splashArtURL = URL(string: "https://absinthebbs.net/")

    /// The marquee text. Also the cracktro's scroller text (`CracktroView`).
    static let originalMarqueeText = ">>> You're looking at a fresh zero day drop from JSONBourne <<< TERMinator, a fresh new BBS terminal app for people who live their life 64K at a time. Greetings to all the crews still pushing pixels in 16 colors, all the SysOps who never sleep, and anyone still rocking a 1084S monitor like it's 1989. Special thx to aNACHRONiST (aNSt) for providing his excellent skillz and for making textmode look like pixel CG! If this thing breaks, you get to keep both pieces. Send fixes, not complaints. >>> end of line <<<"

    struct GlitchSlice: Identifiable {
        let id = UUID()
        let startY: Int        // Start row in pixels (source image coordinates)
        let height: Int        // Height in pixels
        let xOffset: CGFloat   // Horizontal displacement in display points
        let rgbShift: CGFloat  // RGB separation amount (0 = none)
    }

    var body: some View {
        // Scale-to-fit container: the whole layout scales uniformly with the window, up and
        // down, centered. Sizes inside stay in unscaled layout units.
        GeometryReader { geometry in
            let natural = HomeMetrics.naturalSize(sideBySide: sideBySide)
            let scale = fitScale(available: geometry.size, natural: natural)
            layout(scale: scale)
                .frame(width: natural.width, height: natural.height)
                .scaleEffect(scale, anchor: .center)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(Color.background)
        .screenEffect(phosphor: PhosphorMode(rawValue: phosphor) ?? .color)
        .onAppear {
            // After any departing view's onDisappear (the terminal clears its own aspect lock
            // there), so the home lock is the one left standing.
            DispatchQueue.main.async {
                HomeWindowFit.homeDidAppear(sideBySide: sideBySide)
            }
        }
        .onDisappear {
            HomeWindowFit.releaseAspectLock()
        }
        .onChange(of: sideBySide) { newValue in
            // The card the facts overlay covers changes size with the layout.
            showingFacts = false
            // Settle the layout first, then fit the window to the new footprint.
            DispatchQueue.main.async {
                HomeWindowFit.fitToLayout(sideBySide: newValue)
            }
        }
        .sheet(isPresented: $showingQuickConnectPicker) {
            QuickConnectPickerView(store: store) { selectedEntry in
                // The @AppStorage bindings write the same `quick_connect_<n>_id` keys
                // (`AppPreferences.quickConnectKey`), so this both saves the slot and refreshes the tile.
                let id = selectedEntry.id.uuidString
                switch pickingSlot {
                case 1: quickConnect1Id = id
                case 2: quickConnect2Id = id
                case 3: quickConnect3Id = id
                case 4: quickConnect4Id = id
                default: break
                }
                showingQuickConnectPicker = false
            }
        }
    }

    private func fitScale(available: CGSize, natural: CGSize) -> CGFloat {
        guard available.width > 0, available.height > 0, natural.width > 0, natural.height > 0 else { return 1 }
        return max(0.01, min(available.width / natural.width, available.height / natural.height))
    }

    // MARK: - Layout

    /// Two layouts, one set of elements. Stacked: side column under the splash card, 16 apart.
    /// Side-by-side: side column to the right, 24 apart, stretched to the splash card's height.
    @ViewBuilder
    private func layout(scale: CGFloat) -> some View {
        Group {
            if sideBySide {
                HStack(alignment: .top, spacing: HomeMetrics.sideBySideGap) {
                    splashCard
                    sideColumn(scale: scale)
                }
            } else {
                VStack(spacing: HomeMetrics.cardGap) {
                    splashCard
                    sideColumn(scale: scale)
                }
            }
        }
        .padding(HomeMetrics.layoutMargins(sideBySide: sideBySide))
    }

    /// Quick Connect card over the shortcuts card, 16 apart, in both layouts.
    private func sideColumn(scale: CGFloat) -> some View {
        VStack(spacing: HomeMetrics.cardGap) {
            quickConnectCard(scale: scale)
            shortcutsCard
        }
    }

    // MARK: - Splash card

    private var splashCard: some View {
        HomeCard(outline: .cardMagenta) {
            VStack(spacing: 0) {
                // Header Logo (click opens the TERMinator page on deadmodemsociety.com)
                if let logoImage = Bundle.main.image(forResource: "header_logo") {
                    Image(nsImage: logoImage)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                        .frame(height: HomeMetrics.logoHeight)
                        .contentShape(Rectangle())
                        .onTapGesture { openInBrowser(Self.headerLogoURL) }
                        .handCursor()
                } else {
                    Color.clear.frame(height: HomeMetrics.logoHeight)
                }

                Spacer().frame(height: HomeMetrics.logoGap)

                // CRT Marquee Banner
                CrtMarqueeView(text: Self.originalMarqueeText)
                    .frame(width: HomeMetrics.splashPanelWidth, height: HomeMetrics.marqueeHeight)

                Spacer().frame(height: HomeMetrics.marqueeGap)

                // Splash Art with glitch, static burst and scanline sweep (click opens absinthebbs.net).
                // The overlays aspect-fit exactly like the art, so they never leave the image.
                if let splashImage = Bundle.main.image(forResource: "splash_screen") {
                    let splashPixels = Self.pixelSize(of: splashImage)
                    ZStack {
                        GlitchImageView(image: splashImage)
                        SplashStaticBurstView(imagePixelSize: splashPixels)
                            .allowsHitTesting(false)
                        SplashScanlineView(imagePixelSize: splashPixels)
                            .allowsHitTesting(false)
                    }
                    .frame(width: HomeMetrics.splashArtSize.width, height: HomeMetrics.splashArtSize.height)
                    // Windows HomeView.xaml order: SplashImage, StaticBurstImage, ScanlineImage, then the
                    // GlitchCanvas ON TOP, so displaced slices cover the burst and the scanline. The
                    // Windows SplashContainer spans the 600 panel, so a displaced slice may poke past the
                    // art's edges into it; the overlay is 600 wide for the same reason (layout unaffected).
                    .overlay(
                        GlitchSlicesOverlay(image: splashImage, slices: glitchSlices)
                            .frame(width: HomeMetrics.splashPanelWidth,
                                   height: HomeMetrics.splashArtSize.height)
                            .allowsHitTesting(false)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { openInBrowser(Self.splashArtURL) }
                    .handCursor()
                    .onAppear { scheduleMajorGlitch() }
                    .onDisappear {
                        majorGlitchTimer?.invalidate()
                        majorGlitchTimer = nil
                    }
                } else {
                    Color.clear.frame(width: HomeMetrics.splashArtSize.width, height: HomeMetrics.splashArtSize.height)
                }

                Spacer().frame(height: HomeMetrics.splashArtGap)

                // History Ticker (click opens the full facts list)
                HistoryTickerView(onOpenFacts: { showingFacts = true })
                    .frame(width: HomeMetrics.splashPanelWidth, height: HomeMetrics.tickerHeight)
            }
            .frame(width: HomeMetrics.splashPanelWidth, height: HomeMetrics.splashContentHeight)
        }
        .overlay {
            if showingFacts {
                FactsOverlayView(cardSize: HomeMetrics.splashCardSize) {
                    showingFacts = false
                }
            }
        }
    }

    // MARK: - Quick Connect card

    private func quickConnectCard(scale: CGFloat) -> some View {
        let panelWidth = HomeMetrics.sidePanelWidth(sideBySide: sideBySide)
        let paddingV = HomeMetrics.quickConnectPaddingV(sideBySide: sideBySide)
        let cardSize = HomeMetrics.quickConnectCardSize(sideBySide: sideBySide)
        let contentHeight = cardSize.height - 2 * (paddingV + HomeMetrics.cardBorder)

        return HomeCard(outline: .cardCyan,
                        padding: EdgeInsets(top: paddingV, leading: HomeMetrics.cardPadding,
                                            bottom: paddingV, trailing: HomeMetrics.cardPadding)) {
            VStack(spacing: 0) {
                // The heading decrypts on every return to the home screen (spec §5).
                DecryptText(text: "QUICK CONNECT")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.amberAccent)
                    .frame(height: HomeMetrics.headingHeight)

                Spacer().frame(height: HomeMetrics.headingGap)

                HStack(alignment: .top, spacing: HomeMetrics.tileColumnGap) {
                    quickConnectSlot(slotNumber: 1, entryId: quickConnect1Id, scale: scale)
                    quickConnectSlot(slotNumber: 2, entryId: quickConnect2Id, scale: scale)
                }

                // Slots 3–4: second row, side-by-side only
                if sideBySide {
                    Spacer().frame(height: HomeMetrics.tileRowGap)
                    HStack(alignment: .top, spacing: HomeMetrics.tileColumnGap) {
                        quickConnectSlot(slotNumber: 3, entryId: quickConnect3Id, scale: scale)
                        quickConnectSlot(slotNumber: 4, entryId: quickConnect4Id, scale: scale)
                    }
                }
            }
            // Side-by-side: the card takes the column's slack and centers its content.
            .frame(width: panelWidth, height: contentHeight, alignment: .center)
        }
    }

    private func quickConnectSlot(slotNumber: Int, entryId: String, scale: CGFloat) -> some View {
        let entry = store.entries.first { $0.id.uuidString == entryId }

        return VStack(spacing: 0) {
            // Tile: click opens the phonebook picker for this slot (filled or empty)
            Button {
                pickingSlot = slotNumber
                showingQuickConnectPicker = true
            } label: {
                QuickConnectTileContent(slotNumber: slotNumber, entry: entry, scale: scale,
                                        crtEnabled: crtStore.current.enabled)
            }
            .buttonStyle(HomeTileButtonStyle())

            // Amber CONNECT button below the tile, full tile width
            HomeConnectButton {
                if let entry = entry {
                    store.updateLastConnected(for: entry)
                    // A window of its own, or here (Options > Separate Window per BBS)
                    SessionLauncher.connect(entry)
                }
            }
            .disabled(entry == nil)
            .padding(.top, HomeMetrics.connectGap)
        }
    }

    // MARK: - Shortcuts card

    private var shortcutsCard: some View {
        let panelWidth = HomeMetrics.sidePanelWidth(sideBySide: sideBySide)

        return HomeCard(outline: .cardViolet,
                        padding: EdgeInsets(top: HomeMetrics.cardPaddingTight, leading: HomeMetrics.cardPadding,
                                            bottom: HomeMetrics.cardPaddingTight, trailing: HomeMetrics.cardPadding)) {
            HStack(spacing: 0) {
                ShortcutTile(label: "PHONEBOOK", icon: "person.crop.rectangle") {
                    appState.currentView = .phonebook
                }
                ShortcutTile(label: "CRT MODE", icon: "display") {
                    CrtSettingsWindow.show()
                }
                ShortcutTile(label: "LAYOUT", icon: "rectangle.split.2x1") {
                    sideBySide.toggle()
                }
                ShortcutTile(label: "COMMAND", icon: "terminal") {
                    // ContentView shows the Elite confirmation ("Are you Elite enough for command
                    // line mode?"), then the console. Same notification as View > Command Line Mode.
                    NotificationCenter.default.post(name: .showCommandLine, object: nil)
                }
                ShortcutTile(label: "SETTINGS", icon: "gearshape") {
                    appState.openSettings()
                }
            }
            .frame(width: HomeMetrics.shortcutsRowWidth, height: HomeMetrics.shortcutTileHeight)
            .frame(width: panelWidth, height: HomeMetrics.shortcutTileHeight)
        }
    }

    // MARK: - Links

    /// A browser that can't be opened is ignored, never a crash.
    private func openInBrowser(_ url: URL?) {
        guard let url = url else { return }
        _ = NSWorkspace.shared.open(url)
    }

    /// The image's size in pixels (the overlays work in source pixels, like Windows).
    private static func pixelSize(of image: NSImage) -> CGSize {
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return CGSize(width: cg.width, height: cg.height)
        }
        return image.size
    }

    // MARK: - Glitch Effect

    private func scheduleMajorGlitch() {
        let delay = Double.random(in: 2.0...5.0)
        majorGlitchTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            triggerMajorGlitch()
        }
    }

    private func triggerMajorGlitch() {
        guard let image = Bundle.main.image(forResource: "splash_screen"),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            scheduleMajorGlitch()
            return
        }

        let imageHeight = cgImage.height
        let sliceCount = Int.random(in: 3...6)
        var newSlices: [GlitchSlice] = []

        for _ in 0..<sliceCount {
            let startY = Int.random(in: 0..<imageHeight)
            let maxHeight = min(imageHeight - startY, imageHeight / 5)
            let height = Int.random(in: 5...max(10, maxHeight))
            let xOffset = CGFloat.random(in: -25...25)
            let rgbShift: CGFloat = Bool.random() ? CGFloat.random(in: 2...6) : 0

            newSlices.append(GlitchSlice(
                startY: startY,
                height: height,
                xOffset: xOffset,
                rgbShift: rgbShift
            ))
        }

        glitchSlices = newSlices

        let duration = Double.random(in: 0.03...0.08)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            self.glitchSlices = []
            self.scheduleMajorGlitch()
        }
    }
}

// MARK: - Quick Connect tile content

/// A Quick Connect tile's content: the snapshot (exact 4:3, the whole 16:10 grid stretched,
/// nearest-neighbor, with the CRT effect on top when CRT mode is on), the target-lock HUD and the
/// board name. Hovering the tile arms the target lock and replays the name's decrypt (spec §5), so
/// the hover state lives here rather than in `HomeView`.
private struct QuickConnectTileContent: View {
    let slotNumber: Int
    let entry: BBSEntry?
    let scale: CGFloat
    let crtEnabled: Bool

    /// View > Phosphor. The home screen's own monochrome tint is a SwiftUI `colorEffect`, which
    /// cannot filter the AppKit-hosted CRT thumbnail, so the mode is handed to that view's shader
    /// instead (§7). The plain snapshot below it — the only thing shown with CRT off — is tinted by
    /// the screen-wide effect like everything else.
    @AppStorage(AppPreferences.phosphor) private var phosphor = PhosphorMode.color.rawValue

    @State private var isHovered = false
    @State private var nameTrigger = 0

    var body: some View {
        content
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    nameTrigger += 1
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let entry = entry {
            VStack(spacing: 0) {
                ZStack {
                    if let snapshotData = entry.snapshotData,
                       let nsImage = NSImage(data: snapshotData) {
                        // Exact 4:3, the whole 16:10 snapshot stretched (no cropping), nearest-neighbor.
                        Image(nsImage: nsImage)
                            .resizable()
                            .interpolation(.none)
                            .frame(width: HomeMetrics.snapshotSize.width, height: HomeMetrics.snapshotSize.height)

                        // CRT effect on the thumbnail when CRT mode is on; the plain image
                        // stays underneath so a failed effect just shows the snapshot.
                        if crtEnabled {
                            CrtThumbnailView(imageData: snapshotData, layoutScale: scale,
                                             phosphor: PhosphorMode(rawValue: phosphor) ?? .color)
                                .frame(width: HomeMetrics.snapshotSize.width, height: HomeMetrics.snapshotSize.height)
                                .allowsHitTesting(false)
                        }
                    } else {
                        Rectangle()
                            .fill(Color.background)
                            .overlay(
                                Text("No Snapshot")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.textSecondary)
                            )
                    }

                    // Target lock: corner brackets + "<PROTO> // host:port", over the snapshot only.
                    TargetLockOverlay(target: targetCaption(for: entry), locked: isHovered)
                }
                .frame(width: HomeMetrics.snapshotSize.width, height: HomeMetrics.snapshotSize.height)
                .clipped()

                // The name decrypts on appear and replays on hover (spec §5).
                DecryptText(text: entry.name, replayTrigger: nameTrigger)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.accentGreen)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: HomeMetrics.snapshotSize.width,
                           height: HomeMetrics.tileContentSize.height - HomeMetrics.snapshotSize.height - 4)
                    .padding(.top, 4)
            }
            .frame(width: HomeMetrics.tileContentSize.width, height: HomeMetrics.tileContentSize.height, alignment: .top)
        } else {
            VStack(spacing: 6) {
                Text("Quick Connect \(slotNumber)")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.amberAccent)
                Text("Click to choose")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.textSecondary)
            }
            .frame(width: HomeMetrics.tileContentSize.width, height: HomeMetrics.tileContentSize.height)
        }
    }

    /// "TELNET // absinthebbs.net:1940" — PROTO is TELNET / SSH / TELNETS / RAW / WS / WSS.
    private func targetCaption(for entry: BBSEntry) -> String {
        "\(entry.connectionProtocol.tracerName.uppercased()) // \(entry.host):\(entry.port)"
    }
}

// MARK: - Shortcut tile

/// One shortcut tile: SF Symbol icon over a label that decrypts and replays on hover (spec §5).
private struct ShortcutTile: View {
    let label: String
    let icon: String
    let action: () -> Void

    @State private var labelTrigger = 0

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundColor(.amberAccent)
                DecryptText(text: label, replayTrigger: labelTrigger)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)
                    .padding(.top, 6)
            }
            .frame(width: HomeMetrics.shortcutTileWidth - 2 * HomeMetrics.tileInset,
                   height: HomeMetrics.shortcutTileHeight - 2 * HomeMetrics.tileInset)
        }
        .buttonStyle(HomeTileButtonStyle())
        .padding(.horizontal, HomeMetrics.shortcutTileMarginH)
        .onHover { hovering in
            if hovering {
                labelTrigger += 1
            }
        }
    }
}

// MARK: - CONNECT button

/// The amber CONNECT button under a Quick Connect tile: bold, full tile width, fixed height so
/// the layout metrics stay exact.
private struct HomeConnectButton: View {
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text("CONNECT")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.amberAccent)
                .frame(width: HomeMetrics.tileOuterSize.width, height: HomeMetrics.connectHeight)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isHovered ? Color.amberAccentDim.opacity(0.3) : Color.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(isHovered ? Color.amberAccent : Color.amberAccentDim, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1.0 : 0.5)
        .onHover { hovering in
            guard hovering != isHovered else { return }   // exactly one pop per push
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        // CONNECT hands the screen to the terminal with the pointer still on the button and no
        // exit event follows, which would leave the hand cursor stuck.
        .onDisappear {
            if isHovered {
                isHovered = false
                NSCursor.pop()
            }
        }
    }
}

// MARK: - Facts overlay

/// Every ticker fact on its own card, laid over the splash card at exactly the card's size (so
/// the list can never grow the card): a `#0D0D1A` 70% backdrop and a centered amber-outlined
/// card at 90% of the splash card's width and height. Closes on the ✕, Esc, clicking the
/// backdrop, and (from HomeView) toggling the layout.
private struct FactsOverlayView: View {
    let cardSize: CGSize
    let onClose: () -> Void

    private let cardPadding = EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 10)

    var body: some View {
        let factsWidth = cardSize.width * 0.9
        let factsHeight = cardSize.height * 0.9
        let contentWidth = factsWidth - 2 * HomeMetrics.cardBorder - cardPadding.leading - cardPadding.trailing
        let contentHeight = factsHeight - 2 * HomeMetrics.cardBorder - cardPadding.top - cardPadding.bottom

        ZStack {
            // Backdrop over the whole card; a click on it closes the overlay.
            RoundedRectangle(cornerRadius: HomeMetrics.cardRadius)
                .fill(Color.background.opacity(0.7))
                .onTapGesture { onClose() }

            HomeCard(outline: .amberAccent, padding: cardPadding) {
                VStack(alignment: .leading, spacing: 0) {
                    ZStack(alignment: .trailing) {
                        // Decrypts each time the overlay opens (spec §5).
                        DecryptText(text: "COMPUTING & BBS HISTORY")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.amberAccent)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        FactsCloseButton(action: onClose)
                            .retroTooltip("Close (Esc)")
                    }
                    .frame(height: 28)
                    .padding(.trailing, 8)
                    .padding(.bottom, 10)

                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(HistoryFacts.all.enumerated()), id: \.offset) { _, fact in
                                Text("> \(fact)")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.tickerGreen)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.trailing, 8)
                    }
                }
                .frame(width: contentWidth, height: contentHeight)
            }

            // Esc closes the overlay wherever focus is.
            Button("") { onClose() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .onExitCommand { onClose() }
    }
}

/// 28×28 ✕ button at the top-right of the facts card.
private struct FactsCloseButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isHovered ? .amberAccent : .textPrimary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isHovered ? Color.backgroundLight : Color.backgroundMedium)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(isHovered ? Color.amberAccent : Color.panelBorder, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard hovering != isHovered else { return }   // exactly one pop per push
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        // Closing the overlay removes the button under the pointer with no exit event, which
        // would leave the hand cursor stuck.
        .onDisappear {
            if isHovered {
                isHovered = false
                NSCursor.pop()
            }
        }
    }
}

// MARK: - Splash static burst / scanline sweep (Windows HomeView)

/// Where an image of `imageSize` lands when aspect-fit into `size`, centered.
private func splashFitRect(imageSize: CGSize, in size: CGSize) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0, size.width > 0, size.height > 0 else {
        return CGRect(origin: .zero, size: size)
    }
    let scale = min(size.width / imageSize.width, size.height / imageSize.height)
    let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    return CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2,
                  width: fitted.width, height: fitted.height)
}

/// TV static over the splash art (Windows `HomeView` static burst). Every 5–8 s, 2–13 frames of
/// noise regenerated every 60 ms (120–780 ms), then clear. The noise is a quarter-resolution
/// bitmap stretched nearest-neighbor over the art for a chunky look: 18% of pixels lit, grey
/// 120–254, alpha 25–69 (non-premultiplied, as Windows' Bgra32).
private struct SplashStaticBurstView: View {
    let imagePixelSize: CGSize

    @State private var noiseFrame: CGImage?
    @State private var scheduleTimer: Timer?
    @State private var frameTimer: Timer?
    @State private var framesLeft = 0

    var body: some View {
        Canvas { context, size in
            guard let noiseFrame = noiseFrame else { return }
            let rect = splashFitRect(imageSize: imagePixelSize, in: size)
            context.draw(Image(decorative: noiseFrame, scale: 1.0).interpolation(.none), in: rect)
        }
        .onAppear {
            stop()
            scheduleNext()
        }
        .onDisappear { stop() }
    }

    private func stop() {
        scheduleTimer?.invalidate()
        scheduleTimer = nil
        frameTimer?.invalidate()
        frameTimer = nil
        noiseFrame = nil
    }

    private func scheduleNext() {
        scheduleTimer?.invalidate()
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: Double.random(in: 5.0...8.0), repeats: false) { _ in
            trigger()
        }
    }

    private func trigger() {
        scheduleTimer = nil
        framesLeft = Int.random(in: 2...13)
        noiseFrame = Self.makeNoiseFrame(width: max(1, Int(imagePixelSize.width) / 4),
                                         height: max(1, Int(imagePixelSize.height) / 4))
        frameTimer?.invalidate()
        frameTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { _ in
            nextFrame()
        }
    }

    private func nextFrame() {
        framesLeft -= 1
        if framesLeft <= 0 {
            frameTimer?.invalidate()
            frameTimer = nil
            noiseFrame = nil
            scheduleNext()
            return
        }
        noiseFrame = Self.makeNoiseFrame(width: max(1, Int(imagePixelSize.width) / 4),
                                         height: max(1, Int(imagePixelSize.height) / 4))
    }

    private static func makeNoiseFrame(width: Int, height: Int) -> CGImage? {
        var rng = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var i = 0
        while i < bytes.count {
            if Double.random(in: 0..<1, using: &rng) < 0.18 {
                let brightness = UInt8.random(in: 120...254, using: &rng)
                bytes[i] = brightness
                bytes[i + 1] = brightness
                bytes[i + 2] = brightness
                bytes[i + 3] = UInt8.random(in: 25...69, using: &rng)
            }
            i += 4
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}

/// One green CRT scanline sweeping down the splash art (Windows `HomeView` scanline sweep):
/// 2 source pixels high, #66EE66 at alpha 0x30, advancing max(1, h/240) source rows every 33 ms
/// (~8 s per pass on the 800-row art), wrapping at the bottom.
private struct SplashScanlineView: View {
    let imagePixelSize: CGSize

    private static let lineColor = Color(red: 0x66 / 255.0, green: 0xEE / 255.0, blue: 0x66 / 255.0)
        .opacity(Double(0x30) / 255.0)

    /// Current top row in source pixels; -1 = not drawn yet.
    @State private var row = -1
    @State private var timer: Timer?

    var body: some View {
        Canvas { context, size in
            let h = Int(imagePixelSize.height)
            guard h > 0, row >= 0, row < h else { return }
            let rect = splashFitRect(imageSize: imagePixelSize, in: size)
            let scale = rect.height / imagePixelSize.height
            let lineRows = min(2, h - row)
            let line = CGRect(x: rect.minX, y: rect.minY + CGFloat(row) * scale,
                              width: rect.width, height: CGFloat(lineRows) * scale)
            context.fill(Path(line), with: .color(Self.lineColor))
        }
        .onAppear {
            timer?.invalidate()
            row = -1
            timer = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { _ in
                advance()
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private func advance() {
        let h = Int(imagePixelSize.height)
        guard h > 0 else { return }
        let step = max(1, Int(Double(h) / 240.0))
        row = (max(row, 0) + step) % h
    }
}

// MARK: - Glitch Image View

/// The splash art itself (Windows `SplashImage`): aspect-fit, nearest-neighbour, never displaced.
/// The glitch slices are a separate layer above the static burst and scanline (`GlitchSlicesOverlay`).
private struct GlitchImageView: View {
    let image: NSImage

    var body: some View {
        Canvas(opaque: true) { context, size in
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

            // Fill background (the card surface, so any letterboxing matches the card)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.backgroundMedium))

            let destRect = splashFitRect(imageSize: CGSize(width: cgImage.width, height: cgImage.height), in: size)
            context.draw(Image(decorative: cgImage, scale: 1.0).interpolation(.none), in: destRect)
        }
    }
}

/// Windows `HomeView.RenderSplashGlitch` / `GlitchCanvas`: each slice is a full-width strip of the
/// art redrawn ON TOP of everything, displaced by its xOffset, with two 35%-opacity copies at
/// ±rgbShift when it has one. The undisplaced art stays visible underneath; slices are drawn
/// independently (overlaps simply stack), exactly as the Windows canvas children do.
private struct GlitchSlicesOverlay: View {
    let image: NSImage
    let slices: [HomeView.GlitchSlice]

    var body: some View {
        Canvas(opaque: false) { context, size in
            guard !slices.isEmpty,
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

            let fit = splashFitRect(imageSize: CGSize(width: cgImage.width, height: cgImage.height), in: size)
            guard fit.height > 0 else { return }
            let scale = fit.height / CGFloat(cgImage.height)

            for slice in slices {
                let srcY = min(slice.startY, cgImage.height - 1)
                let srcH = min(slice.height, cgImage.height - srcY)
                guard srcY >= 0, srcH > 0,
                      let strip = cgImage.cropping(to: CGRect(x: 0, y: srcY, width: cgImage.width, height: srcH))
                else { continue }

                let stripImage = Image(decorative: strip, scale: 1.0).interpolation(.none)
                let displayY = fit.minY + CGFloat(srcY) * scale
                let displayH = CGFloat(srcH) * scale

                if slice.rgbShift > 0 {
                    for shift in [slice.rgbShift, -slice.rgbShift] {
                        let rect = CGRect(x: fit.minX + slice.xOffset + shift, y: displayY,
                                          width: fit.width, height: displayH)
                        context.drawLayer { ctx in
                            ctx.opacity = 0.35
                            ctx.draw(stripImage, in: rect)
                        }
                    }
                }

                context.draw(stripImage, in: CGRect(x: fit.minX + slice.xOffset, y: displayY,
                                                    width: fit.width, height: displayH))
            }
        }
    }
}

// MARK: - Windows RetroTheme Button Styles

/// Matches Windows RetroTheme default green button
struct RetroButtonStyle: ButtonStyle {
    let fgColor: Color
    let borderColor: Color
    let hoverBgColor: Color

    func makeBody(configuration: Configuration) -> some View {
        RetroButtonBody(configuration: configuration, fgColor: fgColor,
                        borderColor: borderColor, hoverBgColor: hoverBgColor)
    }
}

/// The style's body. `@State` has no storage in a `ButtonStyle` (only in a `View`), so the hover
/// highlight never updated while it lived there.
private struct RetroButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let fgColor: Color
    let borderColor: Color
    let hoverBgColor: Color

    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(fgColor)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(configuration.isPressed
                          ? hoverBgColor.opacity(0.5)
                          : isHovered ? hoverBgColor.opacity(0.3) : Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(isHovered ? fgColor : borderColor, lineWidth: 1)
            )
            .onHover { hovering in
                guard hovering != isHovered else { return }   // exactly one pop per push
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            // BACK / CONNECT change the screen with the pointer still on the button and no exit
            // event follows, which would leave the hand cursor stuck.
            .onDisappear {
                if isHovered {
                    isHovered = false
                    NSCursor.pop()
                }
            }
            .opacity(configuration.isPressed ? 0.9 : 1.0)
    }
}

/// Button style presets matching Windows RetroTheme
enum RetroButtonPreset {
    case amber
    case green
    case danger

    var fg: Color {
        switch self {
        case .amber: return .amberAccent
        case .green: return .accentGreen
        case .danger: return .accentRed
        }
    }

    var border: Color {
        switch self {
        case .amber: return .amberAccentDim
        case .green: return .accentGreenDim
        case .danger: return .accentRed
        }
    }

    var hoverBg: Color {
        switch self {
        case .amber: return .amberAccentDim
        case .green: return .accentGreenDim
        case .danger: return .accentRed
        }
    }
}

/// Convenience view for a retro-styled button matching Windows RetroTheme
struct RetroButton: View {
    let title: String
    let style: RetroButtonPreset
    let action: () -> Void

    init(_ title: String, style: RetroButtonPreset = .green, action: @escaping () -> Void) {
        self.title = title
        self.style = style
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
        }
        .buttonStyle(RetroButtonStyle(
            fgColor: style.fg,
            borderColor: style.border,
            hoverBgColor: style.hoverBg
        ))
    }
}

// MARK: - Quick Connect Picker

struct QuickConnectPickerView: View {
    @ObservedObject var store: BBSEntryStore
    var onSelect: (BBSEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedEntry: BBSEntry?

    var body: some View {
        VStack(spacing: 0) {
            Text("Select BBS")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(.accentGreen)
                .padding(.top, 16)
                .padding(.bottom, 8)

            if store.entries.isEmpty {
                Text("No entries in phonebook")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.textSecondary)
                    .padding(20)
            } else {
                List(store.entries, selection: $selectedEntry) { entry in
                    Text(entry.name)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(selectedEntry?.id == entry.id ? .black : .onBackground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedEntry = entry
                        }
                }
                .listStyle(.plain)
                .frame(minHeight: 200, maxHeight: 300)
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("OK") {
                    if let entry = selectedEntry {
                        onSelect(entry)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedEntry == nil)
            }
            .padding(.vertical, 12)
        }
        .frame(width: 300)
        .background(Color.background)
    }
}
