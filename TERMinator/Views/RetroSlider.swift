import SwiftUI

/// Slider styled to match the Windows client: a rounded dark groove with a
/// green phosphor gradient filling up to the thumb, and a round amber thumb
/// that glows on hover and brightens to white while being dragged.
///
/// SwiftUI's stock Slider can't be re-templated on macOS, so this draws the
/// track and thumb directly and drives the value from a drag gesture. A plain
/// click anywhere on the track jumps to that position.
struct RetroSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// Snap increment. 0 means continuous.
    var step: Double = 0
    /// Spoken name for VoiceOver. Drawing the track by hand means this view has no
    /// control of its own to inherit a label from, so the row passes its own down.
    var accessibilityName: String = ""
    /// Spoken value, already formatted the way the row displays it ("35%", "3 px"),
    /// so VoiceOver reads what is on screen rather than a bare 0.35.
    var accessibilityValueText: String = ""

    private let trackHeight: CGFloat = 6
    private let thumbSize: CGFloat = 16
    private let glowSpread: CGFloat = 10

    @State private var isHovering = false
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, thumbSize)
            let travel = width - thumbSize
            let thumbX = thumbSize / 2 + travel * normalized

            ZStack(alignment: .leading) {
                // Groove
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(Color.crtBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: trackHeight / 2)
                            .stroke(Color.termDarkGray, lineWidth: 1)
                    )
                    .frame(height: trackHeight)

                // Filled portion, left of the thumb
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(LinearGradient(colors: [.accentGreenDim, .accentGreen],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(thumbX, trackHeight), height: trackHeight)

                // Thumb, with a phosphor glow behind it
                ZStack {
                    Circle()
                        .fill(Color.amberAccent)
                        .opacity(isDragging ? 0.50 : (isHovering ? 0.30 : 0))
                        .frame(width: thumbSize + glowSpread, height: thumbSize + glowSpread)
                    Circle()
                        .fill(isDragging ? Color.termWhite : Color.amberAccent)
                        .overlay(Circle().stroke(Color.crtBackground, lineWidth: 2))
                        .frame(width: thumbSize, height: thumbSize)
                }
                .offset(x: thumbX - (thumbSize + glowSpread) / 2)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        setValue(fromX: gesture.location.x, travel: travel)
                    }
                    .onEnded { _ in isDragging = false }
            )
            .onHover { isHovering = $0 }
        }
        .frame(height: 22)
        // Hand-drawn track + DragGesture means AppKit sees no control here at all,
        // so without this the slider is unreachable by VoiceOver and the keyboard.
        .accessibilityElement()
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(Text(accessibilityValueText.isEmpty
                                 ? String(format: "%.2f", value)
                                 : accessibilityValueText))
        .accessibilityAdjustableAction { direction in
            let increment = step > 0 ? step : (range.upperBound - range.lowerBound) / 20
            switch direction {
            case .increment: value = min(value + increment, range.upperBound)
            case .decrement: value = max(value - increment, range.lowerBound)
            @unknown default: break
            }
        }
    }

    private var normalized: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return CGFloat((clamped - range.lowerBound) / span)
    }

    private func setValue(fromX x: CGFloat, travel: CGFloat) {
        guard travel > 0 else { return }
        let offset = min(max(x - thumbSize / 2, 0), travel)
        let span = range.upperBound - range.lowerBound
        var next = range.lowerBound + Double(offset / travel) * span
        if step > 0 {
            next = (next / step).rounded() * step
        }
        value = min(max(next, range.lowerBound), range.upperBound)
    }
}
