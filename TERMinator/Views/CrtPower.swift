import SwiftUI

/// Old-tube power on / off on the window's content (spec §7). Mirrors the Windows client's
/// `Effects/CrtPower.cs` — same shapes, same timings, same easings.
///
/// **On (~0.92 s)**: a small round glowing dot pops in (scale 0.2 → 1 in 0.12 s) and holds until
/// 0.30 s; it fades over 0.14 s as a bright line spreads across (0.26 s, ease-out) together with the
/// content's width; the line fades while the content opens vertically from 0.004 → 1 (0.36 s,
/// ease-out), then the transform is back to identity.
///
/// **Off (~0.69 s)**: the content collapses vertically 1 → 0.004 (0.17 s, ease-in) as the line lights
/// up, content width and line squeeze to 0 (0.14 s, ease-in), and the dot appears as the line
/// vanishes, lingers 0.12 s and shrinks to 0.3× while fading (0.26 s). The content is left collapsed
/// so nothing flashes before the app really quits.
///
/// **Where — app start and exit ONLY**: the launch power-on runs once the window is showing
/// (`ContentView.onAppear`), and `AppDelegate.applicationShouldTerminate` plays the power-off before
/// replying. Never on connect or disconnect (that was tried on Windows and removed 2026-09-13).
///
/// The values are driven from elapsed time by one timer rather than by SwiftUI animations: the
/// sequence is a set of overlapping keyframe tracks with different easings, which is exactly what
/// `BootSequenceModel` already does for its typing. A new effect replaces one still running.
final class CrtPowerModel: ObservableObject {
    static let shared = CrtPowerModel()

    /// The collapsed height of the picture — the bright line.
    static let lineScaleY: CGFloat = 0.004
    /// Diameter of the glowing dot. It has to be a real circle: a very short stretch of the line
    /// looked like a dash.
    static let dotSize: CGFloat = 9

    private static let dotDuration: Double = 0.30
    private static let spreadDuration: Double = 0.26
    private static let openDuration: Double = 0.36
    private static let collapseDuration: Double = 0.17
    private static let squeezeDuration: Double = 0.14
    private static let dotLingerDuration: Double = 0.12
    private static let dotFadeDuration: Double = 0.26

    /// How long `powerOn()` takes, e.g. to start the boot screen's typing once the picture is open.
    static var powerOnDuration: Double { dotDuration + spreadDuration + openDuration }
    /// How long `powerOff(completion:)` takes.
    static var powerOffDuration: Double {
        collapseDuration + squeezeDuration + dotLingerDuration + dotFadeDuration
    }

    /// True while the line / dot layer has anything to draw.
    @Published private(set) var isActive = false
    @Published private(set) var contentScaleX: CGFloat = 1
    @Published private(set) var contentScaleY: CGFloat = 1
    @Published private(set) var lineOpacity: Double = 0
    @Published private(set) var lineScaleX: CGFloat = 0
    @Published private(set) var dotOpacity: Double = 0
    @Published private(set) var dotScale: CGFloat = 1

    private var timer: Timer?
    private var startedAt: Date?
    private var runningOff = false
    private var completion: (() -> Void)?

    private init() {}

    deinit {
        timer?.invalidate()
    }

    /// Collapses the content at once, without starting the effect: call this the moment the view
    /// appears so the picture isn't drawn for a frame before `powerOn()` runs on the next turn of
    /// the main loop (Windows sets the transform before `ContentRendered`).
    func prepareForPowerOn() {
        guard timer == nil else { return }
        isActive = true
        contentScaleX = 0
        contentScaleY = Self.lineScaleY
        lineScaleX = 0
        lineOpacity = 0
        dotOpacity = 0
        dotScale = 0.2
    }

    func powerOn() {
        start(off: false, completion: nil)
    }

    /// Plays the power-off and calls `completion` when the dot has faded. The content is left
    /// collapsed.
    func powerOff(completion: @escaping () -> Void) {
        start(off: true, completion: completion)
    }

    private func start(off: Bool, completion: (() -> Void)?) {
        timer?.invalidate()
        timer = nil

        runningOff = off
        self.completion = completion
        startedAt = Date()
        isActive = true

        if off {
            contentScaleX = 1
            contentScaleY = 1
            lineScaleX = 1
            lineOpacity = 0
            dotOpacity = 0
            dotScale = 1
        } else {
            contentScaleX = 0
            contentScaleY = Self.lineScaleY
            lineScaleX = 0
            lineOpacity = 0
            dotOpacity = 1
            dotScale = 0.2
        }

        // .common so the effect keeps running during menu tracking / a window resize.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func tick() {
        let elapsed = Date().timeIntervalSince(startedAt ?? Date())
        if runningOff {
            tickOff(elapsed)
        } else {
            tickOn(elapsed)
        }
    }

    private func tickOn(_ t: Double) {
        let spreadStart = Self.dotDuration
        let openStart = Self.dotDuration + Self.spreadDuration
        let total = Self.powerOnDuration

        if t >= total {
            finish(collapsed: false)
            return
        }

        dotScale = 0.2 + 0.8 * Self.easeOut(Self.progress(t, 0, 0.12))
        dotOpacity = Self.keyframes(t, [(0, 1), (spreadStart, 1), (spreadStart + 0.14, 0)])

        let spread = Self.easeOut(Self.progress(t, spreadStart, Self.spreadDuration))
        contentScaleX = CGFloat(spread)
        lineScaleX = CGFloat(spread)
        lineOpacity = Self.keyframes(t, [(0, 0), (spreadStart, 0), (spreadStart + 0.08, 1),
                                         (openStart, 1), (openStart + Self.openDuration, 0)])

        let open = Self.easeOut(Self.progress(t, openStart, Self.openDuration))
        contentScaleY = Self.lineScaleY + (1 - Self.lineScaleY) * CGFloat(open)
    }

    private func tickOff(_ t: Double) {
        let squeezeEnd = Self.collapseDuration + Self.squeezeDuration
        let fadeStart = squeezeEnd + Self.dotLingerDuration
        let total = Self.powerOffDuration

        if t >= total {
            finish(collapsed: true)
            return
        }

        let collapse = Self.easeIn(Self.progress(t, 0, Self.collapseDuration))
        contentScaleY = 1 + (Self.lineScaleY - 1) * CGFloat(collapse)

        let squeeze = Self.easeIn(Self.progress(t, Self.collapseDuration, Self.squeezeDuration))
        contentScaleX = 1 - CGFloat(squeeze)
        lineScaleX = 1 - CGFloat(squeeze)

        lineOpacity = Self.keyframes(t, [(0, 0), (0.08, 0), (0.20, 1),
                                         (squeezeEnd - 0.03, 1), (squeezeEnd, 0)])
        dotOpacity = Self.keyframes(t, [(0, 0), (squeezeEnd - 0.06, 0), (squeezeEnd, 1),
                                        (fadeStart, 1), (fadeStart + Self.dotFadeDuration, 0)])
        dotScale = 1 - 0.7 * CGFloat(Self.progress(t, fadeStart, Self.dotFadeDuration))
    }

    private func finish(collapsed: Bool) {
        timer?.invalidate()
        timer = nil
        startedAt = nil
        isActive = false
        lineOpacity = 0
        dotOpacity = 0
        lineScaleX = collapsed ? 0 : 1
        if collapsed {
            // Left collapsed on purpose: the app is quitting, nothing should flash.
            contentScaleX = 0
            contentScaleY = Self.lineScaleY
        } else {
            contentScaleX = 1
            contentScaleY = 1
        }
        let done = completion
        completion = nil
        done?()
    }

    // MARK: - Curves

    private static func progress(_ t: Double, _ start: Double, _ duration: Double) -> Double {
        guard duration > 0 else { return t >= start ? 1 : 0 }
        return min(1, max(0, (t - start) / duration))
    }

    /// WPF's `CubicEase` with `EasingMode.EaseOut`.
    private static func easeOut(_ p: Double) -> Double {
        let q = 1 - p
        return 1 - q * q * q
    }

    /// WPF's `CubicEase` with `EasingMode.EaseIn`.
    private static func easeIn(_ p: Double) -> Double {
        p * p * p
    }

    /// Linear key frames (time, value), like `DoubleAnimationUsingKeyFrames` with
    /// `LinearDoubleKeyFrame`s.
    private static func keyframes(_ t: Double, _ frames: [(Double, Double)]) -> Double {
        guard let first = frames.first else { return 0 }
        if t <= first.0 { return first.1 }
        for index in 1..<frames.count {
            let previous = frames[index - 1]
            let current = frames[index]
            if t <= current.0 {
                let span = current.0 - previous.0
                guard span > 0 else { return current.1 }
                let ratio = (t - previous.0) / span
                return previous.1 + (current.1 - previous.1) * ratio
            }
        }
        return frames[frames.count - 1].1
    }
}

// MARK: - The screen

/// Wraps the window's content in the power transform and puts the glowing line and dot on their own
/// non-interactive layer above everything. The content is built by the caller **once** per render of
/// its own view, so a power-on frame only re-renders this wrapper, never the home screen under it.
struct CrtPowerScreen<Content: View>: View {
    @ObservedObject private var power = CrtPowerModel.shared

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            content
                .scaleEffect(x: power.contentScaleX, y: power.contentScaleY, anchor: .center)

            if power.isActive {
                CrtPowerGlow(power: power)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// The bright line and the round glowing dot, centered, over everything.
private struct CrtPowerGlow: View {
    @ObservedObject var power: CrtPowerModel

    /// `#E8FFFF` — the line and the dot's halo.
    private static let lineColor = Color(red: 0.910, green: 1.0, blue: 1.0)
    /// `#F4FFFF` — the dot itself.
    private static let dotColor = Color(red: 0.957, green: 1.0, blue: 1.0)

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Self.lineColor)
                .frame(height: 3)
                .shadow(color: .white, radius: 9)
                .scaleEffect(x: power.lineScaleX, y: 1, anchor: .center)
                .opacity(power.lineOpacity)

            Circle()
                .fill(Self.dotColor)
                .frame(width: CrtPowerModel.dotSize, height: CrtPowerModel.dotSize)
                // A wide soft halo, so it reads as a glowing point of light rather than a speck.
                .shadow(color: Self.lineColor, radius: 14)
                .scaleEffect(power.dotScale)
                .opacity(power.dotOpacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
