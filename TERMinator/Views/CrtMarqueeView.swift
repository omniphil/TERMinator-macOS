import SwiftUI
import AppKit

/// The home screen's scrolling marquee, drawn the way Windows `HomeView.xaml` draws it: plain
/// #66EE66 text in Consolas 12 (Menlo 12 where Consolas isn't installed — macOS doesn't ship it),
/// no glow, on a transparent strip 26 high (4 padding + an 18-high canvas, text 1 down) that spans
/// the full 600-wide panel. One pass runs from the right edge to fully off the left in
/// textWidth / 45 seconds (`HomeView.SetupAnimation`), then repeats.
///
/// Glitches as `HomeView.StartMarqueeGlitch`: ±2 px horizontal micro-jitter every 80 ms, 1-2 random
/// letter case flips every 100 ms that each hold ~350 ms, and every 1.5-4 s a 30-80 ms flicker
/// (x ±2, y ±1, opacity 0.70-0.85).
struct CrtMarqueeView: View {
    let text: String
    var textColor: Color = Color(red: 0x66 / 255.0, green: 0xEE / 255.0, blue: 0x66 / 255.0) // #66EE66
    /// Windows `HomeView.SetupAnimation`: one pass (container width to -textWidth) takes
    /// textWidth / 45 seconds, so the speed scales with the text rather than being fixed.
    var passSecondsPerPoint: Double = 1.0 / 45.0

    /// Windows: Border Padding="0,4" around an 18-high Canvas, TextBlock at Canvas.Top 1.
    static let stripHeight: CGFloat = 26
    private static let textTop: CGFloat = 5
    private static let fontSize: CGFloat = 12

    /// Consolas when present (Office for Mac installs it), else Menlo — both monospaced at 12 pt.
    private static let fontName: String =
        NSFont(name: "Consolas", size: CrtMarqueeView.fontSize) != nil ? "Consolas" : "Menlo"
    private static var nsFont: NSFont {
        NSFont(name: CrtMarqueeView.fontName, size: CrtMarqueeView.fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: CrtMarqueeView.fontSize, weight: .regular)
    }

    @State private var offset: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    // Micro-jitter
    @State private var microJitterX: CGFloat = 0

    // Major glitch state
    @State private var glitchVerticalOffset: CGFloat = 0
    @State private var glitchHorizontalOffset: CGFloat = 0
    @State private var glitchAlpha: Double = 1.0

    // Case flips with expiration times
    @State private var caseFlips: [Int: Date] = [:]
    @State private var displayText: String = ""

    // Timers
    @State private var scrollTimer: Timer?
    @State private var microJitterTimer: Timer?
    @State private var caseFlipTimer: Timer?
    @State private var glitchScheduleTimer: Timer?

    var body: some View {
        GeometryReader { geometry in
            Text(displayText)
                .font(.custom(Self.fontName, size: Self.fontSize))
                .foregroundColor(textColor)
                .opacity(glitchAlpha)
                .lineLimit(1)
                .fixedSize()
                .offset(x: offset + microJitterX + glitchHorizontalOffset,
                        y: Self.textTop + glitchVerticalOffset)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .clipped()
                .onAppear {
                    containerWidth = geometry.size.width
                    displayText = text
                    // Measured once from the unflipped text: case flips don't change a monospaced width.
                    textWidth = ceil((text as NSString).size(withAttributes: [.font: Self.nsFont]).width)
                    startEffects()
                }
                .onDisappear {
                    stopEffects()
                }
                .onChange(of: geometry.size.width) { newWidth in
                    containerWidth = newWidth
                }
        }
        .frame(height: Self.stripHeight)
        .allowsHitTesting(false)
    }

    // MARK: - Effect Management

    private func startEffects() {
        stopEffects()
        startScrolling()
        startMicroJitter()
        startCaseFlips()
        scheduleNextGlitch()
    }

    private func stopEffects() {
        scrollTimer?.invalidate()
        microJitterTimer?.invalidate()
        caseFlipTimer?.invalidate()
        glitchScheduleTimer?.invalidate()
        scrollTimer = nil
        microJitterTimer = nil
        caseFlipTimer = nil
        glitchScheduleTimer = nil
    }

    // MARK: - Scrolling

    private func startScrolling() {
        offset = containerWidth

        scrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { _ in
            guard textWidth > 0 else { return }

            // Distance of one pass over its duration (textWidth / 45 s), per 60 Hz tick.
            let passSeconds = max(Double(textWidth) * passSecondsPerPoint, 0.1)
            let delta = CGFloat(Double(containerWidth + textWidth) / passSeconds / 60.0)
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

    private func startCaseFlips() {
        caseFlipTimer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { _ in
            updateDisplayText()
        }
    }

    private func updateDisplayText() {
        let now = Date()
        var chars = Array(text)

        caseFlips = caseFlips.filter { $0.value > now }

        // Windows: 1-2 new flips per tick, letters only, each held ~350 ms.
        guard !chars.isEmpty else { return }
        let flipCount = Int.random(in: 1...2)
        for _ in 0..<flipCount {
            let index = Int.random(in: 0..<chars.count)
            if chars[index].isLetter {
                caseFlips[index] = now.addingTimeInterval(0.35)
            }
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
        // Windows sets the values outright (no easing) and clears them after 30-80 ms.
        glitchVerticalOffset = CGFloat.random(in: -1...1)
        glitchHorizontalOffset = CGFloat.random(in: -2...2)
        glitchAlpha = Double.random(in: 0.7...0.85)

        let glitchDuration = Double.random(in: 0.03...0.08)
        DispatchQueue.main.asyncAfter(deadline: .now() + glitchDuration) {
            glitchVerticalOffset = 0
            glitchHorizontalOffset = 0
            glitchAlpha = 1.0
            // Only reschedule while the marquee is still on screen (stopEffects clears the timer).
            if glitchScheduleTimer != nil {
                scheduleNextGlitch()
            }
        }
    }
}
