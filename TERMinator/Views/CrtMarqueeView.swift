import SwiftUI

/// A scrolling marquee view with authentic CRT effects matching the Android/iOS version.
/// Features per-character brightness variation, phosphor glow, scanlines,
/// micro-jitter, major glitch events, random case flips, and noise artifacts.
struct CrtMarqueeView: View {
    let text: String
    var textColor: Color = Color(red: 0.4, green: 0.93, blue: 0.4) // #66EE66 - phosphor green
    var backgroundColor: Color = .background
    var scrollSpeed: Double = 50 // pixels per second

    @State private var offset: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    // Micro-jitter
    @State private var microJitterX: CGFloat = 0

    // Major glitch state
    @State private var isGlitching: Bool = false
    @State private var glitchVerticalOffset: CGFloat = 0
    @State private var glitchHorizontalOffset: CGFloat = 0
    @State private var glitchAlpha: Double = 1.0

    // Case flips with expiration times
    @State private var caseFlips: [Int: Date] = [:]
    @State private var displayText: String = ""

    // Timers
    @State private var scrollTimer: Timer?
    @State private var microJitterTimer: Timer?
    @State private var brightnessTimer: Timer?
    @State private var glitchScheduleTimer: Timer?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                backgroundColor

                ZStack {
                    // Glow layer
                    marqueeText
                        .foregroundColor(textColor.opacity(0.15))
                        .blur(radius: 4)
                        .offset(
                            x: offset + microJitterX + glitchHorizontalOffset,
                            y: glitchVerticalOffset
                        )

                    // Main text
                    marqueeText
                        .foregroundColor(textColor.opacity(0.78 * glitchAlpha))
                        .offset(
                            x: offset + microJitterX + glitchHorizontalOffset,
                            y: glitchVerticalOffset
                        )
                }
                .frame(width: max(geometry.size.width - 280, 100))
                .clipped()
            }
            .onAppear {
                containerWidth = geometry.size.width
                displayText = text
                startEffects()
            }
            .onDisappear {
                stopEffects()
            }
            .onChange(of: geometry.size.width) { newWidth in
                containerWidth = newWidth
            }
        }
        .frame(height: 36)
    }

    private var retroFont: Font {
        .custom("Menlo-Bold", size: 14)
    }

    private var marqueeText: some View {
        HStack(spacing: 0) {
            Text(displayText)
                .font(retroFont)
                .tracking(1)
                .fixedSize()
                .background(
                    GeometryReader { textGeometry in
                        Color.clear
                            .onAppear {
                                textWidth = textGeometry.size.width
                            }
                            .onChange(of: textGeometry.size.width) { newWidth in
                                if newWidth > textWidth {
                                    textWidth = newWidth
                                }
                            }
                    }
                )

            Spacer().frame(width: max(containerWidth, 100))

            Text(displayText)
                .font(retroFont)
                .tracking(1)
                .fixedSize()
        }
    }

    // MARK: - Effect Management

    private func startEffects() {
        startScrolling()
        startMicroJitter()
        startBrightnessVariation()
        scheduleNextGlitch()
    }

    private func stopEffects() {
        scrollTimer?.invalidate()
        microJitterTimer?.invalidate()
        brightnessTimer?.invalidate()
        glitchScheduleTimer?.invalidate()
        scrollTimer = nil
        microJitterTimer = nil
        brightnessTimer = nil
        glitchScheduleTimer = nil
    }

    // MARK: - Scrolling

    private func startScrolling() {
        offset = containerWidth

        scrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { _ in
            guard textWidth > 0 else { return }

            let delta = CGFloat(scrollSpeed / 60.0)
            offset -= delta

            if offset <= -textWidth {
                offset = containerWidth
            }
        }
    }

    // MARK: - Micro-Jitter

    private func startMicroJitter() {
        microJitterTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
            microJitterX = CGFloat.random(in: -2...2)
        }
    }

    // MARK: - Case Flips

    private func startBrightnessVariation() {
        brightnessTimer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { _ in
            updateDisplayText()
        }
    }

    private func updateDisplayText() {
        let now = Date()
        var chars = Array(text)

        caseFlips = caseFlips.filter { $0.value > now }

        let flipCount = Int.random(in: 1...2)
        for _ in 0..<flipCount {
            let index = Int.random(in: 0..<chars.count)
            caseFlips[index] = now.addingTimeInterval(0.25)
        }

        for (index, _) in caseFlips {
            guard index < chars.count else { continue }
            let char = chars[index]
            if char.isLowercase {
                chars[index] = Character(char.uppercased())
            } else if char.isUppercase {
                chars[index] = Character(char.lowercased())
            }
        }

        displayText = String(chars)
    }

    // MARK: - Major Glitch Events

    private func scheduleNextGlitch() {
        let delay = Double.random(in: 1.5...4.0)
        glitchScheduleTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            triggerMajorGlitch()
        }
    }

    private func triggerMajorGlitch() {
        isGlitching = true

        let glitchDuration = Double.random(in: 0.03...0.08)

        withAnimation(.linear(duration: 0.02)) {
            glitchVerticalOffset = CGFloat.random(in: -1...1)
            glitchHorizontalOffset = CGFloat.random(in: -2...2)
            glitchAlpha = Double.random(in: 0.7...0.85)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + glitchDuration) {
            withAnimation(.linear(duration: 0.02)) {
                glitchVerticalOffset = 0
                glitchHorizontalOffset = 0
                glitchAlpha = 1.0
            }
            isGlitching = false
            scheduleNextGlitch()
        }
    }
}
