import AppKit
import SwiftUI

/// One board in the screensaver's slideshow.
struct ScreensaverSlide: Identifiable {
    let id = UUID()
    let name: String
    let image: NSImage
}

/// The idle screensaver (spec §8): a slideshow of the phonebook boards' snapshots hopping around
/// over a faint still frame of digital rain, with a fake GibsonCoin miner on a plane behind it and
/// big credits scrolling along the bottom. Mirrors the Windows client's `Controls/ScreensaverOverlay.cs`.
/// The pieces hop rather than slide, frames are capped at 30 fps, and after 15 minutes (or once the
/// screen sleeps or locks) it fades to black and stops, so an idle client doesn't spin the fans up.
///
/// Any key, any click, or mouse movement over 12 pt ends it; the dismissing key or click is consumed.
/// The host (`ContentView`) stops drawing the home screen underneath while it is up and restarts the
/// idle timer when it finishes.
struct ScreensaverView: View {
    let slides: [ScreensaverSlide]
    /// Called once the fade-out has finished: the host removes the overlay.
    let onFinished: () -> Void

    @StateObject private var model = ScreensaverModel()
    @StateObject private var keys = KeyMonitorHolder()

    /// `#020204`.
    private static let ground = Color(red: 0.008, green: 0.008, blue: 0.016)
    /// `#55FFFF` — the picture frame, its glow and the caption.
    private static let cyan = Color(red: 0.333, green: 1.0, blue: 1.0)
    /// `#FF55FF` / `#55FFFF` / `#55DD55` — the credits, in the command line prompt's colors.
    private static let creditsMagenta = Color(red: 1.0, green: 0.333, blue: 1.0)
    private static let creditsGreen = Color(red: 0.333, green: 0.867, blue: 0.333)

    /// Room around the drifting block for its glow, so rasterizing the block doesn't clip it. The
    /// drift range is still measured from the 448 × 369 block itself, as WPF measures it.
    private static let glowPadding: CGFloat = 24

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                Self.ground

                // Asleep: nothing but black, so there is nothing left to render.
                if !model.asleep {
                    rain(size: size)

                    // One plane behind the BBS artwork: the artwork passes over it.
                    GibsonMinerView(model: model.miner)
                        .position(x: size.width / 2 + model.minerOffset.width,
                                  y: ScreensaverModel.centerY(in: size) + model.minerOffset.height)

                    slideBlock(size: size)

                    credits(size: size)
                }

                Color.black
                    .opacity(model.sleepFade)
                    .allowsHitTesting(false)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .onAppear {
                model.start(size: size, slides: slides, onFinished: onFinished)
            }
            .onChange(of: size) { newSize in
                model.updateSize(newSize)
            }
        }
        .background(Self.ground)
        .opacity(model.opacity)
        .contentShape(Rectangle())
        .onTapGesture {
            model.dismiss()
        }
        // Only real movement counts: the first reported position is just recorded.
        .onContinuousHover(coordinateSpace: .local) { phase in
            if case .active(let location) = phase {
                model.noteMouse(location)
            }
        }
        .onAppear {
            NSCursor.hide()
            keys.monitor.start { _ in
                model.dismiss()
                return true    // the saver owns the keyboard while it is up
            }
        }
        .onDisappear {
            NSCursor.unhide()
            keys.monitor.stop()
            model.stop()
        }
    }

    // MARK: - Layers

    /// Two stacked copies of the pre-rendered, vertically tiling rain frame, sliding down together
    /// and wrapping every screen height. No per-glyph animation: the animated rain was too heavy
    /// under the moving picture and the credits.
    @ViewBuilder
    private func rain(size: CGSize) -> some View {
        if let image = model.rainImage {
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .offset(y: model.rainOffset)
                Image(nsImage: image)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .offset(y: model.rainOffset - size.height)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
            .opacity(0.18)
            .allowsHitTesting(false)
        }
    }

    /// The 448 × 336 picture frame with the board name decrypting under it, as one block, hopping
    /// to a new spot in the free space with each slide.
    private func slideBlock(size: CGSize) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let slide = model.currentSlide {
                    Image(nsImage: slide.image)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: ScreensaverModel.frameSize.width,
                               height: ScreensaverModel.frameSize.height)
                        .offset(x: model.jitterX)
                        .opacity(model.imageOpacity)
                }
            }
            .frame(width: ScreensaverModel.frameSize.width, height: ScreensaverModel.frameSize.height)
            .clipped()
            .overlay(Rectangle().strokeBorder(Self.cyan, lineWidth: 1))
            .shadow(color: Self.cyan.opacity(0.45), radius: 10.5)

            DecryptText(text: model.currentSlide?.name ?? "", duration: 0.7,
                        replayTrigger: model.captionTrigger)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(Self.cyan)
                .lineLimit(1)
                .frame(width: ScreensaverModel.frameSize.width,
                       height: ScreensaverModel.captionHeight)
                .padding(.top, ScreensaverModel.captionGap)
        }
        .frame(width: ScreensaverModel.blockSize.width, height: ScreensaverModel.blockSize.height)
        .padding(Self.glowPadding)
        .scaleEffect(model.blockScale)
        // Rasterized (at its final scale, like the Windows Viewbox's BitmapCache) and then moved with
        // a transform rather than re-rendering the glow.
        .drawingGroup()
        .position(x: size.width / 2 + model.driftOffset.width,
                  y: ScreensaverModel.centerY(in: size) + model.driftOffset.height)
        .allowsHitTesting(false)
    }

    /// The credits band along the bottom: clipped, 64 pt tall, 12 pt above the bottom edge, the text
    /// 10 pt from the band's top, scrolling left at 110 pt/s.
    private func credits(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            creditsText
                .fixedSize()
                .offset(x: model.creditsX, y: 10)
        }
        .frame(width: size.width, height: ScreensaverModel.creditsBandHeight, alignment: .topLeading)
        .clipped()
        .position(x: size.width / 2,
                  y: size.height - ScreensaverModel.creditsBottomMargin
                      - ScreensaverModel.creditsBandHeight / 2)
        .allowsHitTesting(false)
    }

    private var creditsText: some View {
        (Text("TERM").foregroundColor(Self.creditsMagenta)
            + Text("inator").foregroundColor(Self.cyan)
            + Text(ScreensaverModel.creditsTail).foregroundColor(Self.creditsGreen))
            .font(.system(size: 34, weight: .bold, design: .monospaced))
            .shadow(color: Self.cyan.opacity(0.5), radius: 7)
            // Rasterized once with its glow, then just slid, rather than re-rendering the shadow
            // every frame as it scrolls (the credits' own fixedSize keeps the whole line in it).
            .padding(14)
            .drawingGroup()
            .padding(-14)
    }

    // MARK: - Slides

    /// Every board that has a snapshot — saved snapshots and the bundled ones the preloaded boards
    /// use, since macOS keeps both in `BBSEntry.snapshotData` (so the bug Windows had, where a file
    /// on disk was required and every preloaded board dropped out, can't happen here). Anything that
    /// fails to decode is skipped; with nothing at all the splash art stands in.
    static func buildSlides() -> [ScreensaverSlide] {
        var result: [ScreensaverSlide] = []
        for entry in BBSEntryStore.shared.entries {
            guard let data = entry.snapshotData, let image = NSImage(data: data) else { continue }
            result.append(ScreensaverSlide(name: entry.name, image: image))
        }
        if result.isEmpty, let splash = Bundle.main.image(forResource: "splash_screen") {
            result.append(ScreensaverSlide(name: "TERMinator", image: splash))
        }
        return result
    }
}

// MARK: - The clock

/// The screensaver's motion, slideshow and dismissal. Positions are integrated from elapsed time
/// (dt capped at 0.1 s) by one 30 fps timer rather than by SwiftUI animations, so the rain, the
/// credits and the miner all step in lockstep — the same shape as the Windows overlay's frame timer.
/// The picture hops to a new spot with each slide and the miner on its own 4 s clock (at 5, 9, 13, …
/// against the slides' 0, 6, 12, …, so the two never move together).
final class ScreensaverModel: ObservableObject {
    static let slideInterval: Double = 6
    static let rainScrollSpeed: CGFloat = 40
    static let frameInterval: Double = 1.0 / 30
    /// After this long the saver fades to black and stops animating.
    static let sleepAfter: Double = 15 * 60
    static let creditsBandHeight: CGFloat = 64
    static let creditsBottomMargin: CGFloat = 12
    static let creditsSpeed: CGFloat = 110
    static let minerJumpInterval: Double = 4
    static let mouseMoveThreshold: CGFloat = 12
    /// Margin the block stays inside; the miner's is 30.
    static let blockMargin: CGFloat = 40
    static let minerMargin: CGFloat = 30

    /// 4:3, like the terminal's picture (70% of 640 × 480).
    static let frameSize = CGSize(width: 448, height: 336)
    static let captionGap: CGFloat = 13
    static let captionHeight: CGFloat = 20
    static var blockSize: CGSize {
        CGSize(width: frameSize.width, height: frameSize.height + captionGap + captionHeight)
    }

    /// Everything after "TERMinator" in the credits (period after `(aNSt)`, three spaces, then the
    /// joke line, all the same green).
    static let creditsTail = " - Shoddily slapped together by JSONBourne, Artwork by aNACHRONiST (aNSt)."
        + "   No, we aren't really mining GibsonCoins, Sheesh, who do you think we are? :)"

    /// The band the block and the miner are centered in: the window minus the credits band
    /// and its bottom margin, which is what shifts both their centers up.
    static func centerY(in size: CGSize) -> CGFloat {
        (size.height - creditsBandHeight - creditsBottomMargin) / 2
    }

    @Published private(set) var opacity: Double = 0
    @Published private(set) var rainImage: NSImage?
    @Published private(set) var rainOffset: CGFloat = 0
    @Published private(set) var driftOffset: CGSize = .zero
    @Published private(set) var minerOffset: CGSize = .zero
    @Published private(set) var creditsX: CGFloat = 0
    @Published private(set) var captionTrigger: Int = 0
    @Published private(set) var jitterX: CGFloat = 0
    @Published private(set) var imageOpacity: Double = 1
    @Published private(set) var blockScale: CGFloat = 1
    /// 0–1: the black laid over everything as the saver goes to sleep; `asleep` once it is fully dark.
    @Published private(set) var sleepFade: Double = 0
    @Published private(set) var asleep = false

    let miner = GibsonMinerModel()

    private var slides: [ScreensaverSlide] = []
    @Published private(set) var slideIndex = -1

    var currentSlide: ScreensaverSlide? {
        slides.indices.contains(slideIndex) ? slides[slideIndex] : nil
    }

    private var size: CGSize = .zero
    private var creditsWidth: CGFloat = 0
    private var creditsStarted = false
    private var artworkJumpPending = true
    private var nextMinerJump: Double = 1 + ScreensaverModel.minerJumpInterval
    private var minerPlaced = false
    private var sleeping = false
    private var sleepObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var startedAt: Date?
    private var lastTime: Double = 0
    private var frameTimer: Timer?
    private var slideTimer: Timer?
    private var glitchTimer: Timer?
    private var mouseOrigin: CGPoint?
    private var mouseMonitor: Any?
    private var started = false
    private var closing = false
    private var onFinished: (() -> Void)?

    deinit {
        frameTimer?.invalidate()
        slideTimer?.invalidate()
        glitchTimer?.invalidate()
        if let mouseMonitor = mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        for (center, observer) in sleepObservers {
            center.removeObserver(observer)
        }
    }

    func start(size: CGSize, slides: [ScreensaverSlide], onFinished: @escaping () -> Void) {
        guard !started else { return }
        started = true
        self.slides = slides
        self.onFinished = onFinished
        self.size = size
        self.creditsWidth = Self.measureCredits()
        self.blockScale = Self.scale(for: size)
        // Starts just off the right edge — placed on the first frame that has a real width, the way
        // Windows waits for `ActualWidth` (SwiftUI can hand `onAppear` a zero size).
        self.creditsX = size.width

        rainImage = Self.stillRainFrame(size: size)

        // Linear, like WPF's DoubleAnimation(0, 1, 600ms).
        withAnimation(.linear(duration: 0.6)) {
            opacity = 1
        }

        nextSlide()
        let slideTimer = Timer(timeInterval: Self.slideInterval, repeats: true) { [weak self] _ in
            self?.nextSlide()
        }
        RunLoop.main.add(slideTimer, forMode: .common)
        self.slideTimer = slideTimer

        startedAt = Date()
        lastTime = 0
        let frameTimer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            self?.frame()
        }
        RunLoop.main.add(frameTimer, forMode: .common)
        self.frameTimer = frameTimer

        startMouseWatch()
        startSleepWatch()
    }

    /// Goes to sleep along with the display, and when the screen locks or the user switches away.
    private func startSleepWatch() {
        guard sleepObservers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let sources: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.screensDidSleepNotification),
            (workspace, NSWorkspace.willSleepNotification),
            (workspace, NSWorkspace.sessionDidResignActiveNotification),
            (distributed, Notification.Name("com.apple.screenIsLocked")),
        ]
        for (center, name) in sources {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.goToSleep()
            }
            sleepObservers.append((center, observer))
        }
    }

    /// Fades to black and stops every timer: nothing left to draw until the user comes back.
    private func goToSleep() {
        guard !sleeping, !closing else { return }
        sleeping = true
        frameTimer?.invalidate()
        slideTimer?.invalidate()
        glitchTimer?.invalidate()
        frameTimer = nil
        slideTimer = nil
        glitchTimer = nil
        withAnimation(.linear(duration: 1.5)) {
            sleepFade = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, self.sleeping, !self.closing else { return }
            self.asleep = true
        }
    }

    func updateSize(_ newSize: CGSize) {
        guard newSize.width > 1, newSize.height > 1 else { return }
        guard abs(newSize.width - size.width) > 0.5 || abs(newSize.height - size.height) > 0.5 else { return }
        size = newSize
        blockScale = Self.scale(for: newSize)
        rainImage = Self.stillRainFrame(size: newSize)
        rainOffset = 0
        minerPlaced = false
        artworkJumpPending = true
    }

    func stop() {
        frameTimer?.invalidate()
        slideTimer?.invalidate()
        glitchTimer?.invalidate()
        frameTimer = nil
        slideTimer = nil
        glitchTimer = nil
        if let mouseMonitor = mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        mouseMonitor = nil
        for (center, observer) in sleepObservers {
            center.removeObserver(observer)
        }
        sleepObservers = []
    }

    /// Any click ends the saver and is consumed, so it never reaches the home screen underneath —
    /// Windows handles `MouseDown` on the overlay itself. Only clicks inside the window's content
    /// area count: the title bar and the menu bar are outside the overlay there too, so their
    /// buttons keep working.
    private func startMouseWatch() {
        guard mouseMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self = self, !self.closing else { return event }
            guard let content = event.window?.contentView,
                  content.bounds.contains(content.convert(event.locationInWindow, from: nil)) else {
                return event
            }
            self.dismiss()
            return nil       // consumed
        }
    }

    /// Fades out over 0.25 s, then hands back to the host.
    func dismiss() {
        guard !closing else { return }
        closing = true
        // The slideshow and the glitch stop at once, and the click watch goes with them; the motion
        // keeps running through the fade, exactly as Windows only drops its `Rendering` handler once
        // the fade has completed.
        slideTimer?.invalidate()
        slideTimer = nil
        glitchTimer?.invalidate()
        glitchTimer = nil
        if let mouseMonitor = mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        mouseMonitor = nil

        // Linear, like WPF's DoubleAnimation(0, 250ms).
        withAnimation(.linear(duration: 0.25)) {
            opacity = 0
        }
        let finished = onFinished
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.stop()
            finished?()
        }
    }

    /// Only real movement counts: the first event just records where the pointer was.
    func noteMouse(_ location: CGPoint) {
        guard let origin = mouseOrigin else {
            mouseOrigin = location
            return
        }
        if abs(location.x - origin.x) + abs(location.y - origin.y) > Self.mouseMoveThreshold {
            dismiss()
        }
    }

    // MARK: - Motion

    private func frame() {
        guard size.width > 1, size.height > 1 else { return }
        let now = Date().timeIntervalSince(startedAt ?? Date())
        let dt = min(0.1, max(0, now - lastTime))
        lastTime = now

        if now >= Self.sleepAfter {
            goToSleep()
            return
        }
        // Nothing to see while every window is minimized or covered
        guard NSApp.windows.contains(where: { $0.occlusionState.contains(.visible) }) else { return }

        if size.height > 0 {
            rainOffset = (rainOffset + Self.rainScrollSpeed * CGFloat(dt))
                .truncatingRemainder(dividingBy: size.height)
        }

        // The credits: start just off the right edge, scroll left, and come round again once fully
        // off the left.
        if creditsWidth > 0, size.width > 0 {
            if !creditsStarted {
                creditsX = size.width
                creditsStarted = true
            }
            let next = creditsX - Self.creditsSpeed * CGFloat(dt)
            creditsX = next < -creditsWidth ? size.width : next
        }

        // The picture hops with each new slide, the miner on its own clock; each picks the spot that
        // overlaps the other the least, so the miner isn't left hidden behind the artwork. Both are
        // centered in the same band above the credits, so their offsets compare directly.
        let block = CGSize(width: Self.blockSize.width * blockScale,
                           height: Self.blockSize.height * blockScale)
        let minerBox = GibsonMinerView.boxSize
        if artworkJumpPending {
            artworkJumpPending = false
            driftOffset = jump(size: block, margin: Self.blockMargin, avoiding: minerOffset, of: minerBox)
        }
        if !minerPlaced || now >= nextMinerJump {
            if minerPlaced { nextMinerJump += Self.minerJumpInterval }
            minerPlaced = true
            minerOffset = jump(size: minerBox, margin: Self.minerMargin, avoiding: driftOffset, of: block)
        }

        miner.tick(t: now, dt: dt)
    }

    // MARK: - Slideshow

    /// Random order, never the same board twice in a row; every change plays a glitch burst and the
    /// caption decrypts over 0.7 s.
    private func nextSlide() {
        guard !slides.isEmpty else { return }
        artworkJumpPending = true
        if slides.count == 1 {
            slideIndex = 0
        } else {
            // Windows' formula exactly, starting from -1: the step is never 0, so the same board
            // never comes round twice in a row.
            slideIndex = (slideIndex + 1 + Int.random(in: 0..<(slides.count - 1))) % slides.count
        }
        captionTrigger += 1
        glitchBurst()
    }

    /// 6 frames × 45 ms: horizontal jitter ±13 pt, the image flickering 40% / 100%.
    private func glitchBurst() {
        glitchTimer?.invalidate()
        var frame = 0
        let timer = Timer(timeInterval: 0.045, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            frame += 1
            if frame <= 6 {
                self.jitterX = CGFloat(Int.random(in: -13...13))
                self.imageOpacity = frame % 2 == 0 ? 0.4 : 1.0
                return
            }
            timer.invalidate()
            self.glitchTimer = nil
            self.jitterX = 0
            self.imageOpacity = 1
        }
        RunLoop.main.add(timer, forMode: .common)
        glitchTimer = timer
    }

    /// A random offset (from the centre of the free space above the credits) for a box of `box`'s
    /// size, the best of a few tries for staying clear of the other box.
    private func jump(size box: CGSize, margin: CGFloat, avoiding other: CGSize, of otherBox: CGSize) -> CGSize {
        let rangeX = max(0, (size.width - 2 * margin - box.width) / 2)
        let rangeY = max(0, (size.height - 2 * margin - Self.creditsBandHeight
                             - Self.creditsBottomMargin - box.height) / 2)
        var best = CGSize.zero
        var bestOverlap = CGFloat.greatestFiniteMagnitude
        for _ in 0..<8 where bestOverlap > 0 {
            let x = CGFloat.random(in: -1...1) * rangeX
            let y = CGFloat.random(in: -1...1) * rangeY
            let overlapX = (box.width + otherBox.width) / 2 - abs(x - other.width)
            let overlapY = (box.height + otherBox.height) / 2 - abs(y - other.height)
            let overlap = max(0, overlapX) * max(0, overlapY)
            if overlap < bestOverlap {
                bestOverlap = overlap
                best = CGSize(width: x.rounded(), height: y.rounded())
            }
        }
        return best
    }

    // MARK: - Measurement

    /// The frame + caption scale down to fit smaller windows (40 pt margin, and clear of the
    /// credits band), never up — WPF's `StretchDirection.DownOnly`.
    private static func scale(for size: CGSize) -> CGFloat {
        let availableWidth = size.width - 2 * blockMargin
        let availableHeight = size.height - blockMargin - blockMargin
            - creditsBandHeight - creditsBottomMargin
        guard availableWidth > 1, availableHeight > 1 else { return 0.05 }
        return max(0.05, min(1, availableWidth / blockSize.width, availableHeight / blockSize.height))
    }

    /// The rain background as **one** frame, flattened into a bitmap.
    ///
    /// `DigitalRainModel.renderStillFrame` hands back a dynamically drawn `NSImage` (an
    /// `NSCustomImageRep`): its handler runs again on every draw and draws random glyphs, so the two
    /// stacked copies would show different rain and the whole field would re-scramble as it scrolled.
    /// Drawing it into a bitmap rep once is what "one pre-rendered frame" means (Windows renders a
    /// `RenderTargetBitmap`), and it also keeps the scroll free per frame.
    private static func stillRainFrame(size: CGSize) -> NSImage {
        let bounds = NSSize(width: max(1, size.width), height: max(1, size.height))
        let source = DigitalRainModel.renderStillFrame(size: bounds)

        let pixelScale = NSScreen.main?.backingScaleFactor ?? 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                        pixelsWide: max(1, Int((bounds.width * pixelScale).rounded(.up))),
                                        pixelsHigh: max(1, Int((bounds.height * pixelScale).rounded(.up))),
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return source      // fail-soft: animated-looking rain beats no rain
        }
        rep.size = bounds

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        source.draw(in: NSRect(origin: .zero, size: bounds))
        NSGraphicsContext.restoreGraphicsState()

        let flattened = NSImage(size: bounds)
        flattened.addRepresentation(rep)
        return flattened
    }

    /// The credits' pixel width, so the scroll can restart once the text is fully off the left.
    private static func measureCredits() -> CGFloat {
        let text = "TERMinator" + creditsTail
        let font = NSFont.monospacedSystemFont(ofSize: 34, weight: .bold)
        let size = (text as NSString).size(withAttributes: [.font: font])
        return ceil(size.width)
    }
}
