import SwiftUI

/// Home screen with splash image, quick connect slots, history ticker, and navigation.
/// Desktop-optimized layout mirroring the Windows version.
struct HomeView: View {
    @StateObject private var store = BBSEntryStore.shared
    @EnvironmentObject var appState: AppState

    // Quick connect state
    @AppStorage("quick_connect_1_id") private var quickConnect1Id: String = ""
    @AppStorage("quick_connect_2_id") private var quickConnect2Id: String = ""

    // Glitch effect state
    @State private var glitchSlices: [GlitchSlice] = []
    @State private var glitchTimer: Timer?
    @State private var majorGlitchTimer: Timer?

    // Marquee text
    private let marqueeText = ">>> You're looking at a fresh zero day drop from JSONBourne <<< TERMinator, a fresh new BBS terminal app for people who live their life 64K at a time. Greetings to all the crews still pushing pixels in 16 colors, all the SysOps who never sleep, and anyone still rocking a 1084S monitor like it's 1989. Special thx to aNACHRONiST (aNSt) for providing his excellent skillz and for making textmode look like pixel CG! If this thing breaks, you get to keep both pieces. Send fixes, not complaints. >>> end of line <<<"

    struct GlitchSlice: Identifiable {
        let id = UUID()
        let startY: Int        // Start row in pixels (source image coordinates)
        let height: Int        // Height in pixels
        let xOffset: CGFloat   // Horizontal displacement in display points
        let rgbShift: CGFloat  // RGB separation amount (0 = none)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                // Header Logo
                if let logoImage = Bundle.main.image(forResource: "header_logo") {
                    Image(nsImage: logoImage)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 384)
                        .padding(.top, 16)
                }

                // CRT Marquee Banner
                CrtMarqueeView(text: marqueeText)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                Spacer().frame(height: 12)

                // Splash Art with glitch effect
                if let splashImage = Bundle.main.image(forResource: "splash_screen") {
                    GlitchImageView(image: splashImage, slices: glitchSlices)
                        .frame(width: 384, height: 480)
                        .onAppear { scheduleMajorGlitch() }
                        .onDisappear {
                            majorGlitchTimer?.invalidate()
                            majorGlitchTimer = nil
                        }
                }

                Spacer().frame(height: 12)

                // History Ticker
                HistoryTickerView()
                    .frame(maxWidth: 600)

                Spacer().frame(height: 16)

                // Quick Connect Slots
                HStack(spacing: 16) {
                    quickConnectSlot(slotNumber: 1, entryId: quickConnect1Id)
                    quickConnectSlot(slotNumber: 2, entryId: quickConnect2Id)
                }
                .frame(maxWidth: 600)

                Spacer().frame(height: 16)

                // Separator
                Rectangle()
                    .fill(Color.panelBorder)
                    .frame(height: 1)
                    .frame(maxWidth: 600)

                Spacer().frame(height: 16)

                // Navigation Buttons (matches Windows: 184px wide amber buttons)
                HStack(spacing: 12) {
                    RetroButton("PHONEBOOK", style: .amber) {
                        appState.currentView = .phonebook
                    }
                    .frame(width: 184)

                    RetroButton("SETTINGS", style: .amber) {
                        appState.currentView = .settings
                    }
                    .frame(width: 184)
                }
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)
        }
        .background(Color.background)
    }

    // MARK: - Quick Connect Slot

    @ViewBuilder
    private func quickConnectSlot(slotNumber: Int, entryId: String) -> some View {
        let entry = store.entries.first { $0.id.uuidString == entryId }

        VStack(spacing: 0) {
            // Tile area (clickable to pick if empty)
            Button {
                if entry == nil {
                    appState.currentView = .phonebook
                }
            } label: {
                VStack(spacing: 4) {
                    if let entry = entry {
                        if let snapshotData = entry.snapshotData,
                           let nsImage = NSImage(data: snapshotData) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .interpolation(.none)
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 172, height: 130)
                                .clipped()
                        } else {
                            Rectangle()
                                .fill(Color.background)
                                .frame(width: 172, height: 130)
                                .overlay(
                                    Text("No Snapshot")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.textSecondary)
                                )
                        }

                        Text(entry.name)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.accentGreen)
                            .lineLimit(1)
                            .padding(.top, 4)
                    } else {
                        Rectangle()
                            .fill(Color.background)
                            .frame(width: 172, height: 130)
                            .overlay(
                                VStack(spacing: 6) {
                                    Text("Quick Connect \(slotNumber)")
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundColor(.textSecondary)
                                    Text("Click to choose")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.textSecondary.opacity(0.6))
                                }
                            )

                        Text("Empty")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.textSecondary)
                            .padding(.top, 4)
                    }
                }
                .padding(4)
            }
            .buttonStyle(QuickConnectTileButtonStyle())

            // CONNECT button below tile (matches Windows)
            RetroButton("CONNECT", style: .amber) {
                if let entry = entry {
                    store.updateLastConnected(for: entry)
                    appState.currentView = .terminal(entry)
                }
            }
            .disabled(entry == nil)
            .padding(.top, 6)
            .frame(width: 184)
        }
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

// MARK: - Glitch Image View

/// Canvas-based view that renders an image with horizontal slice displacement and RGB chromatic aberration.
private struct GlitchImageView: View {
    let image: NSImage
    let slices: [HomeView.GlitchSlice]

    var body: some View {
        Canvas(opaque: true) { context, size in
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

            // Aspect-fit calculations
            let imageAspect = CGFloat(cgImage.width) / CGFloat(cgImage.height)
            let containerAspect = size.width / size.height

            let displaySize: CGSize
            if imageAspect > containerAspect {
                displaySize = CGSize(width: size.width, height: size.width / imageAspect)
            } else {
                displaySize = CGSize(width: size.height * imageAspect, height: size.height)
            }

            let originX = (size.width - displaySize.width) / 2
            let originY = (size.height - displaySize.height) / 2

            // Fill background
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.background))

            let scale = displaySize.height / CGFloat(cgImage.height)

            if slices.isEmpty {
                // No glitch — draw normally
                let destRect = CGRect(x: originX, y: originY, width: displaySize.width, height: displaySize.height)
                context.draw(Image(decorative: cgImage, scale: 1.0), in: destRect)
            } else {
                // Draw image in horizontal strips, offsetting glitched slices
                let imageHeight = cgImage.height
                var y = 0

                while y < imageHeight {
                    // Find if this row belongs to a glitch slice
                    var sliceForRow: HomeView.GlitchSlice?
                    var sliceEnd = imageHeight

                    for slice in slices {
                        if y >= slice.startY && y < slice.startY + slice.height {
                            sliceForRow = slice
                            sliceEnd = slice.startY + slice.height
                            break
                        } else if slice.startY > y {
                            sliceEnd = min(sliceEnd, slice.startY)
                        }
                    }

                    let stripHeight = min(sliceEnd - y, imageHeight - y)
                    guard stripHeight > 0 else { break }

                    let cropRect = CGRect(x: 0, y: y, width: cgImage.width, height: stripHeight)
                    guard let stripImage = cgImage.cropping(to: cropRect) else {
                        y += stripHeight
                        continue
                    }

                    let displayY = originY + CGFloat(y) * scale
                    let displayH = CGFloat(stripHeight) * scale
                    let xOff = sliceForRow?.xOffset ?? 0
                    let rgbShift = sliceForRow?.rgbShift ?? 0

                    if rgbShift > 0 {
                        // Red channel shifted right
                        let redRect = CGRect(x: originX + xOff + rgbShift, y: displayY, width: displaySize.width, height: displayH)
                        context.drawLayer { ctx in
                            ctx.opacity = 0.35
                            ctx.draw(Image(decorative: stripImage, scale: 1.0), in: redRect)
                        }

                        // Cyan channel shifted left
                        let cyanRect = CGRect(x: originX + xOff - rgbShift, y: displayY, width: displaySize.width, height: displayH)
                        context.drawLayer { ctx in
                            ctx.opacity = 0.35
                            ctx.draw(Image(decorative: stripImage, scale: 1.0), in: cyanRect)
                        }
                    }

                    // Main strip
                    let destRect = CGRect(x: originX + xOff, y: displayY, width: displaySize.width, height: displayH)
                    context.draw(Image(decorative: stripImage, scale: 1.0), in: destRect)

                    y += stripHeight
                }
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

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
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
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
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

/// Quick connect tile button style (matches Windows QuickConnectTileButton)
struct QuickConnectTileButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 2)
                    .fill(configuration.isPressed ? Color.backgroundLight : Color.backgroundMedium)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(isHovered ? Color.borderHighlight : Color.panelBorder, lineWidth: 2)
            )
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}
