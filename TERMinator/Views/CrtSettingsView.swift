import SwiftUI

/// Live editor for the CRT / scanline post-process.
///
/// Every control writes straight through to `CrtSettingsStore.shared`, which
/// the Metal view reads each frame — so the terminal behind this window
/// updates as the sliders move, against real ANSI art.
struct CrtSettingsView: View {
    @ObservedObject private var store = CrtSettingsStore.shared
    @Environment(\.dismiss) private var dismiss

    /// Supplied when an AppKit NSWindow hosts this view: `dismiss` only knows how
    /// to close windows SwiftUI itself opened, so DONE needs the real closer.
    var onDone: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("CRT & SCANLINE EFFECTS")
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundColor(.accent)
                .padding(.bottom, 12)

            // Master switch + preset picker
            HStack {
                Toggle("Enable CRT effect", isOn: Binding(
                    get: { store.current.enabled },
                    set: { store.current.enabled = $0 }
                ))
                .toggleStyle(.checkbox)

                Spacer()

                Text("Preset")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.appPrimary)

                Picker("", selection: presetBinding) {
                    ForEach(CrtSettings.presetNames + ["Custom"], id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
            }
            .padding(12)
            .background(Color.crtBackground)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accent, lineWidth: 1))
            .padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    section("RASTER")
                    slider("Scanlines", \.scanlineIntensity, 0...1, percent: true)
                    slider("Line spacing", \.scanlinePitch, 2...8, unit: "px", step: 1)
                    slider("Beam width", \.beamWidth, 0.2...1, percent: true)
                    slider("Interlace", \.interlace, 0...1, percent: true)
                    slider("Shadow mask", \.maskIntensity, 0...1, percent: true)
                    slider("Mask pitch", \.maskPitch, 2...9, unit: "px", step: 1)

                    section("TUBE")
                    slider("Curvature", \.curvature, 0...1, percent: true)
                    slider("Overscan", \.overscan, 0...0.4, percent: true)
                    slider("Vignette", \.vignette, 0...1, percent: true)
                    slider("Flicker", \.flicker, 0...1, percent: true)

                    section("PHOSPHOR")
                    slider("Glow", \.glow, 0...1, percent: true)
                    slider("Color bleed", \.aberration, 0...1, percent: true)
                    slider("Brightness", \.brightness, 0.5...2, multiplier: true)
                    slider("Monochrome", \.tintAmount, 0...1, percent: true)

                    HStack {
                        Text("Tube color")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.appPrimary)
                            .frame(width: 110, alignment: .leading)
                        Picker("", selection: Binding(
                            get: { store.current.tintColor },
                            set: { store.current.tintColor = $0; markCustom() }
                        )) {
                            ForEach(CrtSettings.tintOptions, id: \.hex) { option in
                                Text(option.name).tag(option.hex)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                        Spacer()
                    }
                    .padding(.bottom, 8)

                    section("SIGNAL")
                    slider("Roll bar", \.verticalHold, 0...1, percent: true)
                    slider("Static", \.noise, 0...1, percent: true)
                    slider("Scan sweep", \.scanSweep, 0...1, percent: true)
                }
                .disabled(!store.current.enabled)
                .opacity(store.current.enabled ? 1.0 : 0.45)
                .padding(.trailing, 6)
            }

            HStack {
                Spacer()
                Button("RESET") { resetToFactory() }
                    .font(.system(size: 12, design: .monospaced))
                Button("DONE") { if let onDone { onDone() } else { dismiss() } }
                    .font(.system(size: 12, design: .monospaced))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(minWidth: 500, maxWidth: .infinity,
               minHeight: 340, maxHeight: .infinity,
               alignment: .topLeading)
        .background(Color.crtBackground)
    }

    // MARK: - Pieces

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundColor(.termCyan)
            .padding(.top, 10)
            .padding(.bottom, 7)
    }

    /// One label | slider | live-value row, bound to a single settings field.
    private func slider(_ label: String,
                        _ key: WritableKeyPath<CrtSettings, Double>,
                        _ range: ClosedRange<Double>,
                        percent: Bool = false,
                        multiplier: Bool = false,
                        unit: String = "",
                        step: Double = 0) -> some View {
        let shown = format(store.current[keyPath: key], percent: percent,
                           multiplier: multiplier, unit: unit)
        return HStack(spacing: 0) {
            Text(label)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.appPrimary)
                .frame(width: 110, alignment: .leading)

            RetroSlider(value: binding(key), range: range, step: step,
                        accessibilityName: label, accessibilityValueText: shown)
                .padding(.horizontal, 12)

            Text(shown)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.accent)
                .frame(width: 62, alignment: .trailing)
        }
        .padding(.bottom, 8)
    }

    private func binding(_ key: WritableKeyPath<CrtSettings, Double>) -> Binding<Double> {
        Binding(
            get: { store.current[keyPath: key] },
            set: { store.current[keyPath: key] = $0; markCustom() }
        )
    }

    /// Selecting a named preset reloads every slider; "Custom" is just a label
    /// for whatever the sliders currently say.
    private var presetBinding: Binding<String> {
        Binding(
            get: { store.current.preset },
            set: { name in
                guard name != "Custom" else { return }
                var preset = CrtSettings.preset(named: name)
                preset.enabled = store.current.enabled
                store.current = preset
            }
        )
    }

    private func markCustom() {
        if store.current.preset != "Custom" {
            store.current.preset = "Custom"
        }
    }

    /// Restores factory settings — every slider, the preset selection and the
    /// tube color. The on/off switch is left alone, so Reset never turns the
    /// effect on behind the user's back.
    private func resetToFactory() {
        var factory = CrtSettings.factory()
        factory.enabled = store.current.enabled
        store.current = factory
    }

    private func format(_ value: Double, percent: Bool,
                        multiplier: Bool, unit: String) -> String {
        if percent { return String(format: "%.0f%%", value * 100) }
        if multiplier { return String(format: "%.2fx", value) }
        if !unit.isEmpty { return String(format: "%.0f %@", value, unit) }
        return String(format: "%.2f", value)
    }
}
