import AppKit
import SwiftUI

/// The home screen's and the command line's screen effect (spec §7), i.e. everything Windows does in
/// `MainWindow.ApplyPhosphor` / `ApplyConsoleEffect`:
///
/// * **Phosphor** (Green / Amber / White): the view becomes a monochrome tube — luminance × the
///   phosphor color, brightness × 1.2. `Color` removes it. Applied to the home screen and the command
///   line, never to the terminal.
/// * **CRT on the command line**: with CRT mode on the console gets the full CRT post-process with
///   the terminal's own settings (live from the CRT window and `crt on|off`), and if a phosphor mode
///   is set the CRT is tinted with that color at tint amount 1 — Windows combines them because an
///   element can carry only one effect there. CRT off → the phosphor tint alone, or nothing in Color
///   mode.
///
/// Both stages are SwiftUI shader effects (`ScreenEffects.metal`): the tint is a `colorEffect`, the
/// CRT a `layerEffect` reusing the terminal's pipeline maths. Scanline and grille pitch are in real
/// device pixels of the view's on-screen size, and the animated features (flicker, interlace, rolling
/// bar, noise, sweep) tick at 30 fps only while the view is on screen — a `TimelineView` is only in
/// play when one of them is on.
///
/// Fail-soft: until the view has been measured (or if it measures empty) the content is drawn
/// untouched rather than through a shader with no geometry.
struct ScreenEffectModifier: ViewModifier {
    /// The CRT settings, or nil where the CRT stage never applies (the home screen — there the CRT
    /// lives on the Quick Connect thumbnails, see `CrtThumbnailView`).
    var crt: CrtSettings?
    /// The phosphor mode; `.color` means no tint.
    var phosphor: PhosphorMode

    /// How far the CRT shader may sample from a pixel: the curvature displaces by a couple of
    /// percent of the view, the glow taps by a pixel and a half.
    private static let maxSampleOffset = CGSize(width: 96, height: 96)

    @State private var size: CGSize = .zero
    @State private var backingScale: CGFloat = 2
    @State private var epoch = Date()

    func body(content: Content) -> some View {
        let measured = content.background(sizeReader)
        let tint = phosphor.tintColor

        return Group {
            // Not measured yet (or measured empty): draw the content as it is, but keep the reader
            // attached so the next layout pass brings the effect in.
            if size.width < 1 || size.height < 1 {
                measured
            } else if let settings = crt, settings.enabled {
                if CrtShader.isAnimated(settings) {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                        measured.layerEffect(
                            crtShader(settings, tint: tint,
                                      time: timeline.date.timeIntervalSince(epoch)),
                            maxSampleOffset: Self.maxSampleOffset)
                    }
                } else {
                    measured.layerEffect(crtShader(settings, tint: tint, time: 0),
                                         maxSampleOffset: Self.maxSampleOffset)
                }
            } else if let tint = tint {
                measured.colorEffect(ShaderLibrary.phosphorTint(.color(tint)))
            } else {
                measured
            }
        }
    }

    /// Reads the view's size without changing its layout, so the shader can work in the view's own
    /// coordinates and measure its pitch in device pixels.
    private var sizeReader: some View {
        GeometryReader { geometry in
            Color.clear
                .onAppear {
                    size = geometry.size
                    backingScale = NSApp.keyWindow?.backingScaleFactor
                        ?? NSScreen.main?.backingScaleFactor ?? 2
                }
                .onChange(of: geometry.size) { newSize in
                    size = newSize
                }
        }
    }

    /// The CRT stage's arguments, in the same order as `crtScreen` in `ScreenEffects.metal`.
    private func crtShader(_ s: CrtSettings, tint: Color?, time: Double) -> Shader {
        let pixels = CGSize(width: max(1, size.width * backingScale),
                            height: max(1, size.height * backingScale))
        // One bright band per scanlinePitch device pixels.
        let scanlineCount = pixels.height / max(1, CGFloat(s.scanlinePitch))
        // A phosphor mode wins over the settings' own tube color, at full strength.
        let tintColor = tint ?? Color(hex: s.tintColor) ?? .white
        let tintAmount = tint != nil ? 1.0 : s.tintAmount

        return ShaderLibrary.crtScreen(
            .float2(size.width, size.height),
            .float2(pixels.width, pixels.height),
            .color(tintColor),
            .float(CGFloat(time)),
            .float(CGFloat(s.curvature)),
            .float(CGFloat(s.overscan)),
            .float(CGFloat(s.scanlineIntensity)),
            .float(scanlineCount),
            .float(CGFloat(max(0.05, s.beamWidth))),
            .float(CGFloat(s.interlace)),
            .float(CGFloat(s.maskIntensity)),
            .float(CGFloat(max(1, s.maskPitch))),
            .float(CGFloat(s.glow)),
            .float(CGFloat(s.bloomThreshold)),
            .float(CGFloat(s.vignette)),
            .float(CGFloat(s.brightness)),
            .float(CGFloat(s.aberration)),
            .float(CGFloat(s.flicker)),
            .float(CGFloat(tintAmount)),
            .float(CGFloat(s.verticalHold)),
            .float(CGFloat(s.noise)),
            .float(CGFloat(s.scanSweep))
        )
    }
}

extension View {
    /// The home screen's / command line's screen effect (see `ScreenEffectModifier`). Pass `crt` only
    /// where the full CRT effect applies (the command line).
    func screenEffect(crt: CrtSettings? = nil, phosphor: PhosphorMode) -> some View {
        modifier(ScreenEffectModifier(crt: crt, phosphor: phosphor))
    }
}

extension PhosphorMode {
    /// The tube color for the monochrome modes, nil in `Color` mode.
    var tintColor: Color? {
        tintHex.flatMap { Color(hex: $0) }
    }

    /// The saved mode (`AppPreferences.phosphor`), for the places that read it outside a SwiftUI
    /// `@AppStorage` binding.
    static var current: PhosphorMode {
        let raw = UserDefaults.standard.string(forKey: AppPreferences.phosphor) ?? ""
        return PhosphorMode(rawValue: raw) ?? .color
    }
}

extension Color {
    /// `#RRGGBB` (or `RRGGBB`) → Color. nil for anything else, so a bad value can only mean "no
    /// effect", never a crash.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255.0,
                  green: Double((value >> 8) & 0xFF) / 255.0,
                  blue: Double(value & 0xFF) / 255.0)
    }
}
