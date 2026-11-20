import Foundation
import Combine

/// CRT / scanline post-process parameters.
///
/// Mirrors the Windows client's CrtSettings. Values are pushed straight into
/// the Metal fragment shader every frame, so edits show on the live terminal
/// without reconnecting.
struct CrtSettings: Codable, Equatable {
    var enabled: Bool = false

    /// Name of the last preset applied, for the options window.
    var preset: String = defaultPresetName

    /// Depth of the raster lines, 0 (none) to 1 (black between lines).
    var scanlineIntensity: Double = 0.35
    /// Backing-store pixels between raster lines, so lines stay crisp at any size.
    var scanlinePitch: Double = 3
    /// Raster beam thickness. 1 is a soft wide sweep, 0.2 a tight filament.
    var beamWidth: Double = 1.0
    /// Alternating-field dimming, 0 to 1.
    var interlace: Double = 0
    /// Aperture-grille strength, 0 to 1.
    var maskIntensity: Double = 0
    /// Backing-store pixels per RGB triad of the aperture grille.
    var maskPitch: Double = 3

    /// Barrel distortion of the tube face, 0 (flat) to 1.
    var curvature: Double = 0
    /// Pulls the picture back inside the curved face so a strong curvature
    /// doesn't clip the outer rows and columns.
    var overscan: Double = 0
    /// Corner darkening, 0 (none) to 1.
    var vignette: Double = 0.15
    /// Mains-hum brightness wobble, 0 to 1.
    var flicker: Double = 0

    /// Phosphor bloom around bright glyphs, 0 to 1.
    var glow: Double = 0.25
    /// Only pixels brighter than this bloom.
    var bloomThreshold: Double = 0.35
    /// Horizontal red/blue separation, 0 to 1.
    var aberration: Double = 0
    /// Output gain — scanlines and the grille cost light, this buys it back.
    var brightness: Double = 1.15
    /// Blend toward a single-phosphor tube, 0 (full color) to 1.
    var tintAmount: Double = 0
    /// Phosphor color used when `tintAmount` is above 0.
    var tintColor: String = "#FFFFFF"

    /// Rolling hum bar drifting up the screen, 0 to 1.
    var verticalHold: Double = 0
    /// Static / snow grain, 0 to 1.
    var noise: Double = 0
    /// Brightness of the refresh line sweeping down the screen, 0 to 1.
    var scanSweep: Double = 0

    /// The look the Reset button restores.
    static let defaultPresetName = "Subtle Scanlines"

    /// Factory settings — the mildest preset, full color, white tube.
    static func factory() -> CrtSettings { preset(named: defaultPresetName) }

    /// Named starting points, roughly mildest-to-wildest: color tubes, then
    /// single phosphor screens, then the beaten-up end of the range.
    static let presetNames = [
        "Subtle Scanlines",
        "Classic CRT",
        "Studio Monitor",
        "Composite TV",
        "Console TV",
        "Arcade Monitor",
        "Green Phosphor",
        "Amber Phosphor",
        "Paper White",
        "Gas Plasma",
        "Night Owl",
        "Worn Out Tube"
    ]

    /// Phosphor colors offered in the options window. Every preset's tintColor
    /// is one of these so the picker is never left blank.
    static let tintOptions: [(name: String, hex: String)] = [
        ("White", "#FFFFFF"),
        ("Green", "#33FF66"),
        ("Amber", "#FFB000"),
        ("Blue",  "#88BBFF"),
        ("Paper", "#FFE8C8")
    ]

    static func preset(named name: String) -> CrtSettings {
        var s = CrtSettings()
        s.enabled = true
        s.preset = name
        s.overscan = 0            // left for the user to dial in
        s.scanlinePitch = 3
        s.maskPitch = 3

        switch name {
        case "Subtle Scanlines":
            s.scanlineIntensity = 0.20; s.beamWidth = 1.00; s.interlace = 0
            s.maskIntensity = 0; s.curvature = 0; s.vignette = 0; s.flicker = 0
            s.glow = 0.10; s.bloomThreshold = 0.45; s.aberration = 0; s.brightness = 1.08
            s.tintAmount = 0; s.verticalHold = 0; s.noise = 0; s.scanSweep = 0

        case "Studio Monitor":     // flat, sharp, aperture-grille glass
            s.scanlineIntensity = 0.30; s.beamWidth = 0.60; s.interlace = 0.20
            s.maskIntensity = 0.70; s.curvature = 0.02; s.vignette = 0.10; s.flicker = 0
            s.glow = 0.20; s.bloomThreshold = 0.45; s.aberration = 0.03; s.brightness = 1.50
            s.tintAmount = 0; s.verticalHold = 0; s.noise = 0; s.scanSweep = 0

        case "Composite TV":       // soft and warm, colors smearing sideways
            s.scanlineIntensity = 0.30; s.beamWidth = 0.85; s.interlace = 0
            s.maskIntensity = 0.10; s.curvature = 0.22; s.vignette = 0.30; s.flicker = 0.04
            s.glow = 0.60; s.bloomThreshold = 0.25; s.aberration = 0.35; s.brightness = 1.30
            s.tintAmount = 0; s.verticalHold = 0.25; s.noise = 0.06; s.scanSweep = 0

        case "Console TV":         // big coarse consumer set
            s.scanlineIntensity = 0.45; s.scanlinePitch = 5; s.beamWidth = 0.70; s.interlace = 0.25
            s.maskIntensity = 0.40; s.maskPitch = 6; s.curvature = 0.45; s.vignette = 0.45; s.flicker = 0.10
            s.glow = 0.50; s.bloomThreshold = 0.30; s.aberration = 0.20; s.brightness = 1.40
            s.tintAmount = 0; s.verticalHold = 0.35; s.noise = 0.10; s.scanSweep = 0

        case "Arcade Monitor":
            s.scanlineIntensity = 0.55; s.beamWidth = 0.55; s.interlace = 0
            s.maskIntensity = 0.55; s.curvature = 0.10; s.vignette = 0.25; s.flicker = 0.05
            s.glow = 0.45; s.bloomThreshold = 0.30; s.aberration = 0.15; s.brightness = 1.45
            s.tintAmount = 0; s.verticalHold = 0; s.noise = 0; s.scanSweep = 0

        case "Green Phosphor":
            s.scanlineIntensity = 0.40; s.beamWidth = 0.75; s.interlace = 0
            s.maskIntensity = 0; s.curvature = 0.18; s.vignette = 0.35; s.flicker = 0.08
            s.glow = 0.55; s.bloomThreshold = 0.25; s.aberration = 0; s.brightness = 1.25
            s.tintAmount = 1.0; s.tintColor = "#33FF66"
            s.verticalHold = 0; s.noise = 0; s.scanSweep = 0

        case "Amber Phosphor":
            s.scanlineIntensity = 0.40; s.beamWidth = 0.75; s.interlace = 0
            s.maskIntensity = 0; s.curvature = 0.18; s.vignette = 0.35; s.flicker = 0.08
            s.glow = 0.55; s.bloomThreshold = 0.25; s.aberration = 0; s.brightness = 1.25
            s.tintAmount = 1.0; s.tintColor = "#FFB000"
            s.verticalHold = 0; s.noise = 0; s.scanSweep = 0

        case "Paper White":        // mono VGA — flat, clean, easy to read
            s.scanlineIntensity = 0.25; s.beamWidth = 0.90; s.interlace = 0
            s.maskIntensity = 0; s.curvature = 0.05; s.vignette = 0.10; s.flicker = 0
            s.glow = 0.30; s.bloomThreshold = 0.45; s.aberration = 0; s.brightness = 1.15
            s.tintAmount = 1.0; s.tintColor = "#FFE8C8"
            s.verticalHold = 0; s.noise = 0; s.scanSweep = 0

        case "Gas Plasma":         // luggable orange panel: glowing, no raster
            s.scanlineIntensity = 0; s.beamWidth = 1.00; s.interlace = 0
            s.maskIntensity = 0; s.curvature = 0; s.vignette = 0.20; s.flicker = 0
            s.glow = 0.70; s.bloomThreshold = 0.20; s.aberration = 0; s.brightness = 1.20
            s.tintAmount = 1.0; s.tintColor = "#FFB000"
            s.verticalHold = 0; s.noise = 0; s.scanSweep = 0

        case "Night Owl":          // dimmed and cooled for a dark room
            s.scanlineIntensity = 0.30; s.beamWidth = 0.90; s.interlace = 0
            s.maskIntensity = 0; s.curvature = 0.10; s.vignette = 0.55; s.flicker = 0
            s.glow = 0.45; s.bloomThreshold = 0.35; s.aberration = 0; s.brightness = 0.85
            s.tintAmount = 0.35; s.tintColor = "#88BBFF"
            s.verticalHold = 0; s.noise = 0; s.scanSweep = 0

        case "Worn Out Tube":
            s.scanlineIntensity = 0.50; s.scanlinePitch = 4; s.beamWidth = 0.60; s.interlace = 0.30
            s.maskIntensity = 0.35; s.maskPitch = 4; s.curvature = 0.35; s.vignette = 0.55; s.flicker = 0.30
            s.glow = 0.65; s.bloomThreshold = 0.20; s.aberration = 0.40; s.brightness = 1.35
            s.tintAmount = 0.15; s.tintColor = "#FFE8C8"
            s.verticalHold = 0.55; s.noise = 0.22; s.scanSweep = 0

        default:                   // "Classic CRT"
            s.preset = "Classic CRT"
            s.scanlineIntensity = 0.35; s.beamWidth = 0.80; s.interlace = 0
            s.maskIntensity = 0.25; s.curvature = 0.12; s.vignette = 0.20; s.flicker = 0
            s.glow = 0.30; s.bloomThreshold = 0.35; s.aberration = 0.06; s.brightness = 1.25
            s.tintAmount = 0; s.verticalHold = 0; s.noise = 0; s.scanSweep = 0
        }
        return s
    }

    /// Tint as linear-ish RGB components for the shader.
    var tintRGB: (Float, Float, Float) {
        var hex = tintColor.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return (1, 1, 1) }
        return (Float((value >> 16) & 0xFF) / 255.0,
                Float((value >> 8) & 0xFF) / 255.0,
                Float(value & 0xFF) / 255.0)
    }
}

/// Shared, persisted CRT settings. The Metal view reads `current` every frame,
/// so any change is on screen immediately.
final class CrtSettingsStore: ObservableObject {
    static let shared = CrtSettingsStore()

    private static let defaultsKey = "crt_settings"

    @Published var current: CrtSettings {
        didSet { save() }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(CrtSettings.self, from: data) {
            current = decoded
        } else {
            current = CrtSettings()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(current) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
