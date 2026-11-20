import AppKit
import CoreText
import SceneKit
import SwiftUI

/// The About box's cracktro (spec §11), an old cracked-software intro. Back to front:
/// black · a parallax starfield · parallax planets · the bouncing luma-keyed header logo · the splash
/// art as a real 3D card tumbling on all three axes while it zooms in and out and now and then flies
/// past the camera · a Gradius-style shooter with power-ups · a rainbow sine scroller · a water
/// reflection of the scroller and the shooter · color-cycling edge lines.
/// (There are no copper bars: that layer was removed from all three clients 2026-09-13.)
/// Mirrors the Windows client's `Controls/CracktroScroller.cs` — same values, same motion maths.
///
/// The two flat layers are SwiftUI `Canvas`es inside `TimelineView(.animation)` and the card is a
/// SceneKit plane under a perspective camera. All three live in one AppKit container view rather than
/// a SwiftUI `ZStack`, because that is the only way to be **sure** the card sits above the stars,
/// logo and below the scroller, water and rainbow lines: a hosted AppKit view's
/// z-order against SwiftUI-drawn siblings isn't guaranteed, while subview order is.
struct CracktroView: NSViewRepresentable {
    /// The scroller's text — the home screen marquee (`HomeView.originalMarqueeText`).
    let text: String

    func makeNSView(context: Context) -> CracktroHostView {
        CracktroHostView(text: text)
    }

    func updateNSView(_ nsView: CracktroHostView, context: Context) {}
}

/// Holds the three layers in AppKit order: back canvas, 3D card, front canvas.
final class CracktroHostView: NSView {
    private let engine: CracktroEngine
    private let backLayerView: NSHostingView<CracktroBackCanvas>
    private let cardView: CracktroCardView
    private let frontLayerView: NSHostingView<CracktroFrontCanvas>

    init(text: String) {
        let engine = CracktroEngine(text: text)
        self.engine = engine
        self.backLayerView = NSHostingView(rootView: CracktroBackCanvas(engine: engine))
        self.cardView = CracktroCardView(frame: .zero)
        self.frontLayerView = NSHostingView(rootView: CracktroFrontCanvas(engine: engine))
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        // Layer 1 of the cracktro is this view's black; both canvases and the card must be see-through
        // or whatever sits under them is lost.
        for hosted in [backLayerView, frontLayerView] as [NSView] {
            hosted.wantsLayer = true
            hosted.layer?.backgroundColor = NSColor.clear.cgColor
        }

        addSubview(backLayerView)
        addSubview(cardView)
        addSubview(frontLayerView)
    }

    required init?(coder: NSCoder) {
        fatalError("CracktroHostView is created in code only")
    }

    override var isFlipped: Bool { true }

    /// The three layers are laid out by hand in `layout()`, so a resize has to ask for one.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        backLayerView.frame = bounds
        cardView.frame = bounds
        frontLayerView.frame = bounds
        cardView.viewSize = bounds.size
    }
}

// MARK: - The tumbling 3D card

/// The splash art as a flat SceneKit plane: a perspective camera with a **horizontal** 45° field of
/// view placed so that one world unit is one point at depth 0, exactly like the Windows `Viewport3D`.
/// The card tumbles on all three axes (X 53°/s, Y 97°/s, Z 31°/s, applied in that order), zooms by
/// depth, stays on screen and above the waterline, and flies past the camera every so often.
final class CracktroCardView: SCNView, SCNSceneRendererDelegate {
    /// World units = screen points at depth 0.
    private static let cardWidth: CGFloat = 88
    private static let cardHeight: CGFloat = 110
    private static let fieldOfView: CGFloat = 45
    /// Where the water starts; the card stays above it.
    private static let waterY: CGFloat = 178
    private static let flyByFirst: Double = 9       // seconds until the first fly-past
    private static let flyByEvery: Double = 17      // then one every this many seconds
    private static let flyByDuration: Double = 3.2  // flying at the camera
    private static let flyByGone: Double = 0.8      // out of sight behind the camera
    private static let flyByReturn: Double = 2.6    // coming back in from far away

    /// Written on the main thread by `layout()`; SceneKit's render callback must not touch `bounds`.
    var viewSize: CGSize = .zero

    private let cardNode = SCNNode()
    private let cameraNode = SCNNode()
    private var startTime: TimeInterval = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect, options: nil)
        build()
    }

    override init(frame frameRect: NSRect, options: [String: Any]?) {
        super.init(frame: frameRect, options: options)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func build() {
        let scene = SCNScene()

        // Lit art plus a self-lit (emissive) copy: lighting alone only ever darkens the art, so the
        // emissive half keeps it bright at every angle while the lit half still shades it as it turns.
        // Front = diffuse art + 50% emissive art; back = diffuse art tinted #B0B0B0 + 35% emissive.
        //
        // The levels are baked into darkened copies of the image rather than dialled in with
        // `SCNMaterialProperty.intensity`: SceneKit honours `intensity` on only a few properties
        // (never `diffuse`), so the back-face tint and the emissive strengths would be ignored.
        // No art, no card — Windows does the same (`BuildSplashCard` returns null and the viewport
        // stays empty); everything else still runs.
        if let art = Bundle.main.image(forResource: "splash_screen") {
            let artBack = Self.darkened(art, by: 0xB0 / 255.0) ?? art  // WPF tints the back #B0B0B0

            let front = SCNMaterial()
            front.lightingModel = .lambert
            front.diffuse.contents = art
            // Set explicitly: an unset `ambient` is not a reliable stand-in for the diffuse, and the
            // ambient light is what keeps the card readable as it turns away from the directional one.
            front.ambient.contents = art
            front.emission.contents = Self.darkened(art, by: 0.5) ?? art
            front.isDoubleSided = false

            let back = SCNMaterial()
            back.lightingModel = .lambert
            back.diffuse.contents = artBack
            back.ambient.contents = artBack
            back.emission.contents = Self.darkened(art, by: 0.35) ?? artBack
            back.isDoubleSided = false

            let frontPlane = SCNNode(geometry: SCNPlane(width: Self.cardWidth, height: Self.cardHeight))
            frontPlane.geometry?.firstMaterial = front
            frontPlane.position = SCNVector3(0, 0, 0.01)

            let backPlane = SCNNode(geometry: SCNPlane(width: Self.cardWidth, height: Self.cardHeight))
            backPlane.geometry?.firstMaterial = back
            backPlane.position = SCNVector3(0, 0, -0.01)
            backPlane.eulerAngles = SCNVector3(0, CGFloat.pi, 0)

            cardNode.addChildNode(frontPlane)
            cardNode.addChildNode(backPlane)
        }
        scene.rootNode.addChildNode(cardNode)

        // Ambient keeps it readable edge-on; the light from the viewer brightens it as it faces us.
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.color = NSColor(white: 0x90 / 255.0, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        let directional = SCNNode()
        directional.light = SCNLight()
        directional.light?.type = .directional
        directional.light?.color = NSColor(white: 0xA0 / 255.0, alpha: 1)
        // Shining along (0.25, −0.3, −1): a light node points down its own −z axis.
        directional.position = SCNVector3(-0.25 * 100, 0.3 * 100, 1 * 100)
        directional.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(directional)

        let camera = SCNCamera()
        camera.fieldOfView = Self.fieldOfView
        camera.projectionDirection = .horizontal
        // WPF's Viewport3D near plane is 0.125, so the card fills the screen on a fly-past instead of
        // being clipped away a whole unit out. The far plane clears the −14 × cameraDistance return.
        camera.zNear = 0.125
        camera.zFar = 40000
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 600)
        scene.rootNode.addChildNode(cameraNode)

        self.scene = scene
        pointOfView = cameraNode
        backgroundColor = .clear
        autoenablesDefaultLighting = false
        allowsCameraControl = false
        antialiasingMode = .multisampling4X
        isPlaying = true
        rendersContinuously = true
        delegate = self
    }

    override var isOpaque: Bool { false }

    /// The card's art with every color channel multiplied by `factor`, so the front's 50% emissive
    /// copy, the back's #B0B0B0 diffuse tint and its 35% emissive copy are baked into the image
    /// (see `build()` for why `SCNMaterialProperty.intensity` is not used).
    private static func darkened(_ image: NSImage, by factor: Double) -> NSImage? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = source.width
        let height = source.height
        let bytesPerRow = width * 4
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                          | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
        for index in stride(from: 0, to: bytesPerRow * height, by: 4) {
            for channel in 0..<3 {
                bytes[index + channel] = UInt8(min(255, Double(bytes[index + channel]) * factor))
            }
        }
        guard let scaled = context.makeImage() else { return nil }
        return NSImage(cgImage: scaled, size: NSSize(width: width, height: height))
    }

    /// Windows unhooks `CompositionTarget.Rendering` when the About box closes. The equivalent here is
    /// to stop rendering the moment the view leaves its window (the sheet tearing down), and to pick it
    /// back up if it is ever put back in one.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let onScreen = window != nil
        isPlaying = onScreen
        rendersContinuously = onScreen
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        if startTime == 0 {
            startTime = time
        }
        let size = viewSize
        guard size.width > 0, size.height > 0 else { return }
        let t = time - startTime

        let cameraDistance = size.width / 2 / tan(Self.fieldOfView / 2 * CGFloat.pi / 180)
        cameraNode.position = SCNVector3(0, 0, cameraDistance)

        // Zoom: mostly far away, then a swoop in close.
        let swoop = 0.5 + 0.5 * sin(t * 0.55)
        let scale = 0.45 + 0.8 * swoop * swoop
        var depth = cameraDistance * CGFloat(1 - 1 / scale)

        // Keep the whole card (up to its half-diagonal when rolled) inside the screen and above the
        // waterline.
        let reach = sqrt(Self.cardWidth * Self.cardWidth + Self.cardHeight * Self.cardHeight)
            / 2 * CGFloat(scale)
        let screenX = size.width / 2 + CGFloat(sin(t * 0.63)) * max(0, size.width / 2 - reach)
        let middleY = Self.waterY / 2
        let screenY = middleY + CGFloat(sin(t * 1.21)) * max(0, middleY - reach)

        var offsetX = (screenX - size.width / 2) / CGFloat(scale)
        var offsetY = (size.height / 2 - screenY) / CGFloat(scale)

        // Every so often it breaks off and flies straight at us, past the camera and out of sight,
        // then shoots back in from far away and picks up its usual drift.
        if t >= Self.flyByFirst {
            let local = (t - Self.flyByFirst).truncatingRemainder(dividingBy: Self.flyByEvery)
            if local < Self.flyByDuration {
                let p = local / Self.flyByDuration
                let ease = p * p                     // gently accelerates toward the camera
                depth += (cameraDistance * 1.2 - depth) * CGFloat(ease)
                offsetX *= CGFloat(1 - min(1, p * 1.6))
                offsetY *= CGFloat(1 - min(1, p * 1.6))
            } else if local < Self.flyByDuration + Self.flyByGone {
                depth = cameraDistance * 1.2         // behind the camera: not drawn
            } else if local < Self.flyByDuration + Self.flyByGone + Self.flyByReturn {
                let p = (local - Self.flyByDuration - Self.flyByGone) / Self.flyByReturn
                let ease = 1 - pow(1 - p, 3)         // decelerates into place
                let farDepth = -cameraDistance * 14
                depth = farDepth + (depth - farDepth) * CGFloat(ease)
                offsetX *= CGFloat(ease)
                offsetY *= CGFloat(ease)
            }
        }

        // Tumble on all three axes, applied in order X, Y, Z, then the position.
        let radians = CGFloat.pi / 180
        var transform = SCNMatrix4MakeRotation(CGFloat(t * 53).truncatingRemainder(dividingBy: 360) * radians, 1, 0, 0)
        transform = SCNMatrix4Mult(transform,
                                   SCNMatrix4MakeRotation(CGFloat(t * 97).truncatingRemainder(dividingBy: 360) * radians, 0, 1, 0))
        transform = SCNMatrix4Mult(transform,
                                   SCNMatrix4MakeRotation(CGFloat(t * 31).truncatingRemainder(dividingBy: 360) * radians, 0, 0, 1))
        transform = SCNMatrix4Mult(transform, SCNMatrix4MakeTranslation(offsetX, offsetY, depth))
        cardNode.transform = transform
    }
}

// MARK: - The flat layers

/// One frame of the back layer: the starfield, the planets and the bouncing logo.
struct CracktroBackCanvas: View {
    let engine: CracktroEngine

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                engine.drawBack(&context, size: size,
                                t: timeline.date.timeIntervalSince(engine.startDate))
            }
        }
    }
}

/// One frame of the front layer: the shooter, the rainbow sine scroller, the water reflection and the
/// color-cycling edge lines. This layer also advances the shooter's simulation.
struct CracktroFrontCanvas: View {
    let engine: CracktroEngine

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSince(engine.startDate)
                engine.updateShooter(t: t, width: size.width)
                engine.drawFront(&context, size: size, t: t)
            }
        }
    }
}

// MARK: - The engine

/// Everything the two canvases draw and the shooter's simulation. A plain class, not an
/// `ObservableObject`: the canvases are redrawn by their `TimelineView`, so nothing needs publishing.
final class CracktroEngine {
    // Layout, all from the Windows control.
    private static let scrollSpeed: CGFloat = 140       // points per second
    private static let scrollerFontSize: CGFloat = 32
    private static let waveAmplitude: CGFloat = 20
    private static let scrollerCenterY: CGFloat = 128   // middle of the sine wave
    private static let waterY: CGFloat = 178            // where the reflection starts
    private static let logoWidth: CGFloat = 290

    let text: String
    let startDate = Date()

    /// Consolas Bold 32 on Windows; the system's monospaced face here.
    private let scrollerFont = NSFont.monospacedSystemFont(ofSize: CracktroEngine.scrollerFontSize,
                                                           weight: .bold)
    private var glyphs: [Character: (path: Path, advance: CGFloat)] = [:]
    private var textWidth: CGFloat = 0
    /// The vertical center of 'M' in the flipped glyph space, so every letter rides the wave on its
    /// middle (Windows measures the same way).
    private var glyphCenterOffset: CGFloat = 0

    private struct Star {
        let x: CGFloat
        let y: CGFloat
        let layer: Int
    }

    private let stars: [Star]
    private var logoImage: CGImage?
    private var logoLoaded = false

    init(text: String) {
        self.text = text
        // Fixed random rows, seed 1989, so the sky is the same every time the box is opened.
        var rng = CracktroRandom(seed: 1989)
        var built: [Star] = []
        built.reserveCapacity(140)
        for _ in 0..<140 {
            built.append(Star(x: CGFloat(rng.nextUnit()) * 2000,
                              y: CGFloat(rng.nextUnit()) * 220,
                              layer: Int(rng.nextUnit() * 3) % 3))
        }
        stars = built
    }

    // MARK: Back layer

    func drawBack(_ context: inout GraphicsContext, size: CGSize, t: Double) {
        guard size.width > 0, size.height > 0 else { return }
        drawStars(&context, width: size.width, t: t)
        drawPlanets(&context, width: size.width, t: t)
        drawLogo(&context, width: size.width, t: t)
    }

    /// Three layers scrolling left at 25 / 80 / 135 pt/s, the fastest 2×2 and brightest.
    private func drawStars(_ context: inout GraphicsContext, width: CGFloat, t: Double) {
        for star in stars {
            let speed = CGFloat(25 + star.layer * 55)
            let travel = (star.x + CGFloat(t) * speed).truncatingRemainder(dividingBy: width + 4)
            let x = width - travel
            let shade = Double(90 + star.layer * 80) / 255.0
            let side: CGFloat = star.layer == 2 ? 2 : 1
            context.fill(Path(CGRect(x: x, y: star.y, width: side, height: side)),
                         with: .color(Color(white: shade)))
        }
    }

    /// A background planet. `start` staggers where it is in its crossing; `speed` gives the parallax.
    private struct Planet {
        let start: Double
        let y: CGFloat
        let radius: CGFloat
        let speed: CGFloat
        let base: Color
        let bands: [Color]
        let glow: Color
        let ring: Bool
        let craters: [(x: CGFloat, y: CGFloat, r: CGFloat)]
    }

    // Slowest (farthest) first, so nearer planets pass in front.
    private static let planets: [Planet] = [
        Planet(start: 0.15, y: 150, radius: 12, speed: 4,
               base: rgb(0x5A, 0x9B, 0xFF), bands: [], glow: rgb(0x88, 0xCC, 0xFF),
               ring: false, craters: []),                                               // ice world
        Planet(start: 0.75, y: 58, radius: 7, speed: 6,
               base: rgb(0xB0, 0x7C, 0xE0), bands: [], glow: rgb(0xB0, 0x7C, 0xE0),
               ring: false, craters: [(x: -2, y: -1, r: 1.5), (x: 2.5, y: 2, r: 1.2)]),                   // little moon
        Planet(start: 0.55, y: 118, radius: 30, speed: 9,
               base: rgb(0xD9, 0x9A, 0x5B),
               bands: [rgb(0xB8, 0x73, 0x33), rgb(0xEA, 0xC0, 0x8A),
                       rgb(0x9C, 0x5A, 0x2E), rgb(0xE0, 0xA9, 0x6D)],
               glow: rgb(0xFF, 0xCC, 0x88), ring: true, craters: []),                   // ringed gas giant
        Planet(start: 0.02, y: 46, radius: 18, speed: 13,
               base: rgb(0xC8, 0x50, 0x3C), bands: [], glow: rgb(0xFF, 0x77, 0x55),
               ring: false, craters: [(x: -6, y: -4, r: 3), (x: 5, y: 3, r: 2.5),
                         (x: -2, y: 8, r: 2), (x: 8, y: -6, r: 1.6)]), // red rock
        Planet(start: 0.9, y: 172, radius: 15, speed: 17,
               base: rgb(0x2F, 0xB8, 0xA0), bands: [], glow: rgb(0x66, 0xFF, 0xDD),
               ring: false, craters: []),                                               // teal world
    ]

    /// Lit from the upper left: a soft highlight fading to a dark night side at the rim.
    private static let planetShade = Gradient(stops: [
        .init(color: Color(white: 1, opacity: 0x45 / 255.0), location: 0),
        .init(color: Color(white: 0, opacity: 0), location: 0.35),
        .init(color: Color(white: 0, opacity: 0xC8 / 255.0), location: 0.95),
        .init(color: Color(white: 0, opacity: 0xE6 / 255.0), location: 1),
    ])

    private func drawPlanets(_ context: inout GraphicsContext, width: CGFloat, t: Double) {
        var layer = context
        layer.opacity = 0.8   // background: never louder than the foreground

        for planet in Self.planets {
            let r = planet.radius
            let cycle = width + 2 * r + 160
            let travel = (CGFloat(t) * planet.speed + CGFloat(planet.start) * cycle)
                .truncatingRemainder(dividingBy: cycle)
            let cx = width + r + 80 - travel
            if cx < -r * 2 - 10 || cx > width + r * 2 + 10 { continue }
            let center = CGPoint(x: cx, y: planet.y)

            // Glow: the color at 33% alpha out to 78% of 1.3r, fading to nothing at the edge.
            let glowGradient = Gradient(stops: [
                .init(color: planet.glow.opacity(0x55 / 255.0), location: 0),
                .init(color: planet.glow.opacity(0x55 / 255.0), location: 0.78),
                .init(color: planet.glow.opacity(0), location: 1),
            ])
            let glowRadius = r * 1.3
            layer.fill(Path(ellipseIn: CGRect(x: cx - glowRadius, y: planet.y - glowRadius,
                                              width: glowRadius * 2, height: glowRadius * 2)),
                       with: .radialGradient(glowGradient, center: center,
                                             startRadius: 0, endRadius: glowRadius))

            if planet.ring {
                drawRingHalf(&layer, center: center, r: r, back: true)
            }

            // The body, clipped to the circle.
            let body = CGRect(x: cx - r, y: planet.y - r, width: 2 * r, height: 2 * r)
            var disc = layer
            disc.clip(to: Path(ellipseIn: body))
            disc.fill(Path(body), with: .color(planet.base))
            if !planet.bands.isEmpty {
                let stripes = 9
                let stripeHeight = 2 * r / CGFloat(stripes)
                var index = 0
                while index < stripes {
                    let band = planet.bands[(index / 2) % planet.bands.count]
                    let wobble = CGFloat(sin(Double(index) * 1.7)) * stripeHeight * 0.3
                    disc.fill(Path(CGRect(x: cx - r,
                                          y: planet.y - r + CGFloat(index) * stripeHeight + wobble,
                                          width: 2 * r, height: stripeHeight * 0.9)),
                              with: .color(band))
                    index += 2
                }
            }
            for crater in planet.craters {
                let rect = CGRect(x: cx + crater.x - crater.r, y: planet.y + crater.y - crater.r,
                                  width: crater.r * 2, height: crater.r * 2)
                disc.fill(Path(ellipseIn: rect), with: .color(Color(white: 0, opacity: 0x70 / 255.0)))
            }
            // Shade: origin (0.32,0.3), center (0.4,0.38), radius 0.75 of the bounding box.
            let shadeCenter = CGPoint(x: body.minX + body.width * 0.4, y: body.minY + body.height * 0.38)
            disc.fill(Path(ellipseIn: body),
                      with: .radialGradient(Self.planetShade, center: shadeCenter,
                                            startRadius: 0, endRadius: body.width * 0.75))

            if planet.ring {
                drawRingHalf(&layer, center: center, r: r, back: false)
            }
        }
    }

    /// One half of a tilted ring: the far half goes behind the planet, the near half in front.
    private func drawRingHalf(_ context: inout GraphicsContext, center: CGPoint, r: CGFloat, back: Bool) {
        var ring = context
        ring.translateBy(x: center.x, y: center.y)
        ring.rotate(by: .degrees(-18))
        ring.translateBy(x: -center.x, y: -center.y)
        ring.clip(to: Path(back ? CGRect(x: center.x - 3 * r, y: center.y - 3 * r, width: 6 * r, height: 3 * r)
                                : CGRect(x: center.x - 3 * r, y: center.y, width: 6 * r, height: 3 * r)))
        ring.stroke(Path(ellipseIn: CGRect(x: center.x - r * 1.9, y: center.y - r * 0.45,
                                           width: r * 3.8, height: r * 0.9)),
                    with: .color(Self.rgb(0xE0, 0xCC, 0xA0).opacity(0xB0 / 255.0)), lineWidth: 2.5)
        ring.stroke(Path(ellipseIn: CGRect(x: center.x - r * 1.55, y: center.y - r * 0.33,
                                           width: r * 3.1, height: r * 0.66)),
                    with: .color(Self.rgb(0xA8, 0x88, 0x60).opacity(0x80 / 255.0)), lineWidth: 1.2)
    }

    /// The header logo, 290 wide, black keyed out, bouncing like a ball and swaying side to side.
    private func drawLogo(_ context: inout GraphicsContext, width: CGFloat, t: Double) {
        if !logoLoaded {
            logoLoaded = true
            logoImage = Self.lumaKeyedLogo()
        }
        guard let logo = logoImage else { return }
        let height = Self.logoWidth * CGFloat(logo.height) / CGFloat(logo.width)
        let x = (width - Self.logoWidth) / 2
            + CGFloat(sin(t * 0.9)) * (width - Self.logoWidth) * 0.35
        let y = 4 + (1 - CGFloat(abs(sin(t * 2.4)))) * 16
        context.draw(Image(decorative: logo, scale: 1),
                     in: CGRect(x: x, y: y, width: Self.logoWidth, height: height))
    }

    /// The header logo with its black background keyed out (alpha = the brightest channel), so the
    /// stars show around it. Keeping the RGB and setting alpha to that maximum is the premultiplied
    /// form of Windows' un-premultiplied keying, i.e. the same picture.
    private static func lumaKeyedLogo() -> CGImage? {
        guard let image = Bundle.main.image(forResource: "header_logo"),
              let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = source.width
        let height = source.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        // Core Graphics owns the buffer, so the pointer stays valid for as long as the context does.
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: space, bitmapInfo: info) else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
        for index in stride(from: 0, to: bytesPerRow * height, by: 4) {
            let maximum = max(bytes[index], max(bytes[index + 1], bytes[index + 2]))
            bytes[index + 3] = maximum
        }
        return context.makeImage()
    }

    // MARK: Front layer

    func drawFront(_ context: inout GraphicsContext, size: CGSize, t: Double) {
        guard size.width > 0, size.height > 0 else { return }
        ensureGlyphs()

        drawShooter(&context, t: t)

        // The scroller, with a dark drop shadow so it pops off the background.
        let scroll = (CGFloat(t) * Self.scrollSpeed)
            .truncatingRemainder(dividingBy: textWidth + size.width)
        let startX = size.width - scroll
        drawScroller(&context, width: size.width, t: t, startX: startX, reflection: false)

        // Water: a dark blue band with the scroller and the whole shooter layer mirrored in it.
        let waterRect = CGRect(x: 0, y: Self.waterY, width: size.width, height: size.height - Self.waterY)
        if waterRect.height > 0 {
            var water = context
            water.clip(to: Path(waterRect))
            water.fill(Path(waterRect),
                       with: .linearGradient(
                        Gradient(colors: [Self.rgb(0x02, 0x0A, 0x30).opacity(0xD0 / 255.0),
                                          Self.rgb(0x00, 0x00, 0x08).opacity(0xF0 / 255.0)]),
                        startPoint: CGPoint(x: 0, y: Self.waterY),
                        endPoint: CGPoint(x: 0, y: size.height)))

            var mirror = water
            mirror.concatenate(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 2 * Self.waterY))
            mirror.opacity = 0.32
            drawShooter(&mirror, t: t)
            drawScroller(&mirror, width: size.width, t: t, startX: startX, reflection: true)
        }

        // Color-cycling lines along the top, the waterline and the bottom.
        drawRainbowLine(&context, width: size.width, y: 0, thickness: 2, t: t)
        drawRainbowLine(&context, width: size.width, y: Self.waterY - 1, thickness: 1, t: t + 0.5)
        drawRainbowLine(&context, width: size.width, y: size.height - 2, thickness: 2, t: t + 1)
    }

    /// Each letter rides a wave around y = 128; the fill runs white (top) → a rainbow color whose hue
    /// runs across the screen and cycles over time, with a 1 pt outline at 45% brightness and a black
    /// drop shadow offset 3,3.
    private func drawScroller(_ context: inout GraphicsContext, width: CGFloat, t: Double,
                              startX: CGFloat, reflection: Bool) {
        var x = startX
        var index = 0
        for character in text {
            let entry = glyph(character)
            if x > width { break }
            if x + entry.advance >= 0 && !character.isWhitespace {
                let wave = CGFloat(sin(Double(x) * 0.018 + t * 4.2)) * Self.waveAmplitude
                let y = Self.scrollerCenterY - glyphCenterOffset + wave
                let ripple = reflection ? CGFloat(sin(t * 6 + Double(index) * 0.9)) * 2.5 : 0
                let color = Self.hsv((Double(x) * 0.6 + t * 220).truncatingRemainder(dividingBy: 360), 0.85, 1)
                let bounds = entry.path.boundingRect

                if !reflection {
                    var shadow = context
                    shadow.translateBy(x: x + 3, y: y + 3)
                    shadow.fill(entry.path, with: .color(.black))
                }
                var letter = context
                letter.translateBy(x: x + ripple, y: y)
                let fill = Gradient(stops: [
                    .init(color: .white, location: 0.05),
                    .init(color: color, location: 0.55),
                ])
                letter.fill(entry.path,
                            with: .linearGradient(fill,
                                                  startPoint: CGPoint(x: 0, y: bounds.minY),
                                                  endPoint: CGPoint(x: 0, y: bounds.maxY)))
                letter.stroke(entry.path, with: .color(Self.darken(color)), lineWidth: 1)
            }
            x += entry.advance
            index += 1
        }
    }

    private func drawRainbowLine(_ context: inout GraphicsContext, width: CGFloat, y: CGFloat,
                                 thickness: CGFloat, t: Double) {
        var stops: [Gradient.Stop] = []
        for i in 0...6 {
            stops.append(.init(color: Self.hsv((Double(i) * 60 + t * 180).truncatingRemainder(dividingBy: 360), 1, 1),
                               location: Double(i) / 6.0))
        }
        context.fill(Path(CGRect(x: 0, y: y, width: width, height: thickness)),
                     with: .linearGradient(Gradient(stops: stops),
                                           startPoint: CGPoint(x: 0, y: y),
                                           endPoint: CGPoint(x: width, y: y)))
    }

    /// Glyph outlines, cached. Core Text hands them over y-up from the baseline, so they are flipped
    /// into the canvas' y-down space; `glyphCenterOffset` is then the middle of 'M', which is what
    /// puts every letter's center on the wave.
    private func ensureGlyphs() {
        guard textWidth <= 0 else { return }
        var total: CGFloat = 0
        for character in text {
            total += glyph(character).advance
        }
        textWidth = total
        glyphCenterOffset = glyph("M").path.boundingRect.midY
    }

    private func glyph(_ character: Character) -> (path: Path, advance: CGFloat) {
        if let cached = glyphs[character] { return cached }

        let font = scrollerFont as CTFont
        let utf16 = Array(String(character).utf16)
        var ids = [CGGlyph](repeating: 0, count: max(1, utf16.count))
        guard CTFontGetGlyphsForCharacters(font, utf16, &ids, utf16.count), let id = ids.first else {
            let empty = (path: Path(), advance: CGFloat(0))
            glyphs[character] = empty
            return empty
        }
        let advance = CGFloat(CTFontGetAdvancesForGlyphs(font, .horizontal, [id], nil, 1))
        var flip = CGAffineTransform(scaleX: 1, y: -1)
        let path: Path
        if let outline = CTFontCreatePathForGlyph(font, id, nil),
           let flipped = outline.copy(using: &flip) {
            path = Path(flipped)
        } else {
            path = Path()
        }
        let entry = (path: path, advance: advance)
        glyphs[character] = entry
        return entry
    }

    // MARK: Shooter

    // A little Gradius-style ship on the left: it bobs around, steers toward the next enemy or
    // power-up and keeps firing; waves of spinning fans snake in from the right, some shoot pellets
    // back, and hits burst into sparks and a shock ring. The ship never dies.

    private struct Shot { var x: CGFloat; var y: CGFloat; var vy: CGFloat }
    private struct Enemy { var x: CGFloat; var y: CGFloat; var baseY: CGFloat; var fired: Bool = false }
    private struct Pellet { var x: CGFloat; var y: CGFloat; var vx: CGFloat; var vy: CGFloat }
    private struct Spark {
        var x: CGFloat; var y: CGFloat; var vx: CGFloat; var vy: CGFloat
        var age: Double; var life: Double; var color: Color
    }
    private struct ShockRing { var x: CGFloat; var y: CGFloat; var age: Double; var color: Color }
    private struct PowerUp { var x: CGFloat; var y: CGFloat; var baseY: CGFloat }
    private struct Popup { var x: CGFloat; var y: CGFloat; var age: Double; var text: String }

    private static let maxFireLevel = 4               // single, double, triple, quad
    private static let maxLevelHoldSeconds: Double = 8  // then it powers back down so the cycle repeats
    private static let powerUpSpeed: CGFloat = 80
    private static let diagonalShotVy: CGFloat = 110
    private static let fireLevelNames = ["", "SINGLE", "DOUBLE", "TRIPLE", "QUAD"]
    private static let shipTop: CGFloat = 26
    private static let shipBottom: CGFloat = 166
    private static let shotSpeed: CGFloat = 460
    private static let enemySpeed: CGFloat = 105
    private static let pelletSpeed: CGFloat = 120

    private static let shipHull =
        CracktroEngine.polygon([(15, 0), (4, -3), (-9, -4), (-13, -2), (-13, 2), (-9, 4), (4, 3)])
    private static let shipWings: Path = {
        var path = CracktroEngine.polygon([(2, -3), (-8, -10), (-11, -10), (-6, -3)])
        path.addPath(CracktroEngine.polygon([(2, 3), (-8, 10), (-11, 10), (-6, 3)]))
        return path
    }()
    private static let fanPath: Path = {
        var path = Path()
        for i in 0..<4 {
            let a = Double(i) * Double.pi / 2
            path.addPath(CracktroEngine.polygon([(0, 0),
                                                 (CGFloat(cos(a) * 9), CGFloat(sin(a) * 9)),
                                                 (CGFloat(cos(a + 0.7) * 6), CGFloat(sin(a + 0.7) * 6))]))
        }
        return path
    }()

    private static let sparkColors: [Color] = [CracktroEngine.rgb(0xFF, 0xFF, 0xAA),
                                               CracktroEngine.rgb(0xFF, 0xAA, 0x00),
                                               CracktroEngine.rgb(0xFF, 0x55, 0x55)]

    private static func polygon(_ points: [(CGFloat, CGFloat)]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: first.0, y: first.1))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: point.0, y: point.1))
        }
        path.closeSubpath()
        return path
    }

    private var shots: [Shot] = []
    private var enemies: [Enemy] = []
    private var pellets: [Pellet] = []
    private var sparks: [Spark] = []
    private var rings: [ShockRing] = []
    private var powerUps: [PowerUp] = []
    private var popups: [Popup] = []
    private var fireLevel = 1
    private var maxLevelSince: Double = 0
    private var nextPowerUpTime: Double = 2.0
    private var shipX: CGFloat = 42
    private var shipY: CGFloat = 95
    private var lastShooterTime: Double = 0
    private var nextShotTime: Double = 0
    private var nextWaveTime: Double = 0.8
    private var waveSpawnsLeft = 0
    private var nextSpawnTime: Double = 0
    private var waveBaseY: CGFloat = 95

    /// Advances the simulation. Called once per frame by the front canvas; a second call with the
    /// same time does nothing.
    func updateShooter(t: Double, width: CGFloat) {
        guard width > 0, t > lastShooterTime else { return }
        let dt = min(0.05, max(0, t - lastShooterTime))
        lastShooterTime = t
        let step = CGFloat(dt)

        // Waves of five fans, snaking in along the same curve.
        if t >= nextWaveTime {
            waveSpawnsLeft = 5
            nextSpawnTime = t
            waveBaseY = 45 + CGFloat(Double.random(in: 0..<1)) * 105
            nextWaveTime = t + 2.6 + Double.random(in: 0..<1) * 1.4
        }
        if waveSpawnsLeft > 0 && t >= nextSpawnTime {
            enemies.append(Enemy(x: width + 12, y: waveBaseY, baseY: waveBaseY))
            waveSpawnsLeft -= 1
            nextSpawnTime = t + 0.2
        }

        for index in enemies.indices {
            enemies[index].x -= Self.enemySpeed * step
            enemies[index].y = enemies[index].baseY
                + CGFloat(sin(Double(enemies[index].x) * 0.035)) * 24
            if !enemies[index].fired && enemies[index].x < width * 0.8
                && enemies[index].x > shipX + 80 && Double.random(in: 0..<1) < 0.012 {
                enemies[index].fired = true
                let dx = shipX - enemies[index].x
                let dy = shipY - enemies[index].y
                let length = max(1, sqrt(dx * dx + dy * dy))
                pellets.append(Pellet(x: enemies[index].x, y: enemies[index].y,
                                      vx: dx / length * Self.pelletSpeed,
                                      vy: dy / length * Self.pelletSpeed))
            }
        }
        enemies.removeAll { $0.x < -20 }

        // Power-up capsules drift in every couple of seconds, bobbing a little.
        if t >= nextPowerUpTime {
            let y = 40 + CGFloat(Double.random(in: 0..<1)) * 120
            powerUps.append(PowerUp(x: width + 10, y: y, baseY: y))
            nextPowerUpTime = t + 1.8 + Double.random(in: 0..<1) * 0.8
        }
        for index in powerUps.indices {
            powerUps[index].x -= Self.powerUpSpeed * step
            powerUps[index].y = powerUps[index].baseY
                + CGFloat(sin(t * 3 + Double(powerUps[index].baseY))) * 6
        }

        // The ship drifts side to side and steers for the next capsule once it's close, otherwise the
        // next enemy in line (or cruises when the sky is clear).
        shipX = 42 + CGFloat(sin(t * 0.7)) * 16
        let nextPowerUp = powerUps.filter { $0.x > shipX }.min { $0.x < $1.x }
        let nextEnemy = enemies.filter { $0.x > shipX + 30 }.min { $0.x < $1.x }
        var targetY: CGFloat?
        if let capsule = nextPowerUp, capsule.x < width * 0.7 {
            targetY = capsule.y
        } else if let enemy = nextEnemy {
            targetY = enemy.y
        } else if let capsule = nextPowerUp {
            targetY = capsule.y
        }
        let cruise = 95 + CGFloat(sin(t * 0.9)) * 45
        let desiredY = min(max(targetY ?? cruise, Self.shipTop), Self.shipBottom)
        shipY += min(max(desiredY - shipY, -95 * step), 95 * step)

        for index in powerUps.indices {
            guard abs(powerUps[index].x - shipX) < 14, abs(powerUps[index].y - shipY) < 12 else { continue }
            powerUps[index].x = -100
            var label = "MAX"
            if fireLevel < Self.maxFireLevel {
                fireLevel += 1
                label = Self.fireLevelNames[fireLevel]
                if fireLevel == Self.maxFireLevel {
                    maxLevelSince = t
                }
            }
            rings.append(ShockRing(x: shipX, y: shipY, age: 0, color: Self.rgb(0x55, 0xFF, 0xFF)))
            popups.append(Popup(x: shipX, y: shipY - 14, age: 0, text: label))
        }
        powerUps.removeAll { $0.x < -15 }

        if fireLevel == Self.maxFireLevel && t - maxLevelSince > Self.maxLevelHoldSeconds {
            fireLevel = 1
            popups.append(Popup(x: shipX, y: shipY - 14, age: 0, text: "POWER DOWN"))
        }

        if t >= nextShotTime {
            let noseX = shipX + 15
            switch fireLevel {
            case 1:
                fire(noseX, shipY, 0)
            case 2:
                fire(noseX, shipY - 4, 0)
                fire(noseX, shipY + 4, 0)
            case 3:
                fire(noseX, shipY, 0)
                fire(noseX, shipY, -Self.diagonalShotVy)
                fire(noseX, shipY, Self.diagonalShotVy)
            default:
                fire(noseX, shipY - 4, 0)
                fire(noseX, shipY + 4, 0)
                fire(noseX, shipY, -Self.diagonalShotVy)
                fire(noseX, shipY, Self.diagonalShotVy)
            }
            nextShotTime = t + 0.2
        }
        for index in shots.indices {
            shots[index].x += Self.shotSpeed * step
            shots[index].y += shots[index].vy * step
        }

        for index in popups.indices {
            popups[index].age += dt
            popups[index].y -= 25 * step
        }
        popups.removeAll { $0.age >= 0.9 }

        for index in pellets.indices {
            pellets[index].x += pellets[index].vx * step
            pellets[index].y += pellets[index].vy * step
            if abs(pellets[index].x - shipX) < 9 && abs(pellets[index].y - shipY) < 6 {
                // Soaks it up on the shields.
                burst(x: pellets[index].x, y: pellets[index].y, count: 4, ring: false)
                pellets[index].x = -100
            }
        }
        pellets.removeAll { $0.x < -10 || $0.x > width + 10 || $0.y < -10 || $0.y > 230 }

        // Hits
        for index in shots.indices {
            guard let hit = enemies.firstIndex(where: {
                abs($0.x - shots[index].x) < 10 && abs($0.y - shots[index].y) < 9
            }) else { continue }
            burst(x: enemies[hit].x, y: enemies[hit].y, count: 14, ring: true)
            enemies.remove(at: hit)
            shots[index].x = width + 100
        }
        shots.removeAll { $0.x > width + 10 || $0.y < -10 || $0.y > 230 }

        for index in sparks.indices {
            sparks[index].age += dt
            sparks[index].x += sparks[index].vx * step
            sparks[index].y += sparks[index].vy * step
            sparks[index].vx *= 0.97
            sparks[index].vy *= 0.97
        }
        sparks.removeAll { $0.age >= $0.life }
        for index in rings.indices {
            rings[index].age += dt
        }
        rings.removeAll { $0.age >= 0.35 }
    }

    private func fire(_ x: CGFloat, _ y: CGFloat, _ vy: CGFloat) {
        shots.append(Shot(x: x, y: y, vy: vy))
    }

    private func burst(x: CGFloat, y: CGFloat, count: Int, ring: Bool) {
        for _ in 0..<count {
            let angle = Double.random(in: 0..<1) * Double.pi * 2
            let speed = 40 + Double.random(in: 0..<1) * 120
            sparks.append(Spark(x: x, y: y,
                                vx: CGFloat(cos(angle) * speed), vy: CGFloat(sin(angle) * speed),
                                age: 0, life: 0.3 + Double.random(in: 0..<1) * 0.3,
                                color: Self.sparkColors[Int.random(in: 0..<Self.sparkColors.count)]))
        }
        if ring {
            rings.append(ShockRing(x: x, y: y, age: 0, color: Self.rgb(0xFF, 0xDD, 0x88)))
        }
    }

    private func drawShooter(_ context: inout GraphicsContext, t: Double) {
        for pellet in pellets {
            context.fill(Path(ellipseIn: CGRect(x: pellet.x - 3, y: pellet.y - 3, width: 6, height: 6)),
                         with: .color(Self.rgb(0xFF, 0x55, 0xFF)))
            context.fill(Path(ellipseIn: CGRect(x: pellet.x - 1.2, y: pellet.y - 1.2, width: 2.4, height: 2.4)),
                         with: .color(.white))
        }

        for powerUp in powerUps {
            let pulse = 0.5 + 0.5 * sin(t * 10)
            let alpha = (0x40 + 0x50 * pulse) / 255.0
            context.fill(Path(ellipseIn: CGRect(x: powerUp.x - 11, y: powerUp.y - 11, width: 22, height: 22)),
                         with: .color(Self.rgb(0x55, 0xFF, 0xFF).opacity(alpha)))
            let capsule = Path(roundedRect: CGRect(x: powerUp.x - 7, y: powerUp.y - 5, width: 14, height: 10),
                               cornerRadius: 5)
            context.fill(capsule, with: .color(Self.rgb(0xFF, 0x33, 0x22)))
            context.stroke(capsule, with: .color(Self.rgb(0xFF, 0xDD, 0x66)), lineWidth: 1)
            context.fill(Path(CGRect(x: powerUp.x - 4, y: powerUp.y - 3, width: 5, height: 1.5)),
                         with: .color(.white.opacity(0xC0 / 255.0)))
        }

        for shot in shots {
            var layer = context
            if shot.vy != 0 {
                layer.translateBy(x: shot.x, y: shot.y)
                layer.rotate(by: .radians(atan2(Double(shot.vy), Double(Self.shotSpeed))))
                layer.translateBy(x: -shot.x, y: -shot.y)
            }
            layer.fill(Path(CGRect(x: shot.x - 3, y: shot.y - 2.5, width: 18, height: 5)),
                       with: .color(Self.rgb(0xFF, 0xFF, 0x55).opacity(0x60 / 255.0)))
            layer.fill(Path(CGRect(x: shot.x, y: shot.y - 1, width: 12, height: 2)),
                       with: .color(Self.rgb(0xFF, 0xFF, 0xCC)))
        }

        for enemy in enemies {
            var layer = context
            layer.translateBy(x: enemy.x, y: enemy.y)
            var blades = layer
            blades.rotate(by: .degrees((t * 480).truncatingRemainder(dividingBy: 360)))
            blades.fill(Self.fanPath, with: .color(Self.rgb(0xFF, 0xAA, 0x00)))
            blades.stroke(Self.fanPath, with: .color(Self.rgb(0xFF, 0x33, 0x33)), lineWidth: 1)
            layer.fill(Path(ellipseIn: CGRect(x: -2, y: -2, width: 4, height: 4)), with: .color(.white))
        }

        // The ship, with a flickering engine flame.
        var ship = context
        ship.translateBy(x: shipX, y: shipY)
        let flame = 5 + CGFloat(Double.random(in: 0..<1)) * 6
        ship.fill(Self.polygon([(-13, -2.5), (-13 - flame, 0), (-13, 2.5)]),
                  with: .color(Self.rgb(0xFF, 0x8A, 0x00)))
        ship.fill(Self.polygon([(-13, -1.2), (-13 - flame * 0.55, 0), (-13, 1.2)]),
                  with: .color(Self.rgb(0xFF, 0xFF, 0xAA)))
        ship.fill(Self.shipWings, with: .color(Self.rgb(0x22, 0xE6, 0xFF)))
        ship.stroke(Self.shipWings, with: .color(Self.rgb(0x0A, 0x6A, 0x80)), lineWidth: 0.8)
        ship.fill(Self.shipHull, with: .color(Self.rgb(0xE0, 0xE0, 0xF0)))
        ship.stroke(Self.shipHull, with: .color(Self.rgb(0x5A, 0x5A, 0x7A)), lineWidth: 0.8)
        ship.fill(Path(ellipseIn: CGRect(x: 0, y: -2.6, width: 6, height: 3.2)),
                  with: .color(Self.rgb(0xFF, 0x2B, 0xD6)))

        for spark in sparks {
            let alpha = 1 - spark.age / spark.life
            context.fill(Path(CGRect(x: spark.x - 1, y: spark.y - 1, width: 2, height: 2)),
                         with: .color(spark.color.opacity(max(0, alpha))))
        }
        for ring in rings {
            let alpha = max(0, 1 - ring.age / 0.35)
            let radius = 4 + CGFloat(ring.age) * 70
            context.stroke(Path(ellipseIn: CGRect(x: ring.x - radius, y: ring.y - radius,
                                                  width: radius * 2, height: radius * 2)),
                           with: .color(ring.color.opacity(alpha)), lineWidth: 1.5)
        }
        for popup in popups {
            let alpha = min(1, 2.5 * (1 - popup.age / 0.9))
            let label = Text(popup.text)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(Self.rgb(0x55, 0xFF, 0xFF).opacity(max(0, alpha)))
            context.draw(context.resolve(label), at: CGPoint(x: popup.x, y: popup.y), anchor: .center)
        }
    }

    // MARK: Helpers

    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> Color {
        Color(red: Double(r) / 255.0, green: Double(g) / 255.0, blue: Double(b) / 255.0)
    }

    /// The scroller outline's 45% brightness.
    static func darken(_ color: Color) -> Color {
        let components = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.white
        return Color(red: Double(components.redComponent) * 0.45,
                     green: Double(components.greenComponent) * 0.45,
                     blue: Double(components.blueComponent) * 0.45)
    }

    /// HSV → Color, as the Windows control's `Hsv`.
    static func hsv(_ hue: Double, _ saturation: Double, _ value: Double) -> Color {
        let h = hue.truncatingRemainder(dividingBy: 360)
        let c = value * saturation
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = value - c
        let rgb: (Double, Double, Double)
        switch h {
        case ..<60: rgb = (c, x, 0)
        case ..<120: rgb = (x, c, 0)
        case ..<180: rgb = (0, c, x)
        case ..<240: rgb = (0, x, c)
        case ..<300: rgb = (x, 0, c)
        default: rgb = (c, 0, x)
        }
        return Color(red: rgb.0 + m, green: rgb.1 + m, blue: rgb.2 + m)
    }
}

/// A tiny deterministic generator, so the starfield is identical every time (Windows seeds `Random`
/// with 1989).
private struct CracktroRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 6364136223846793005 &+ 1442695040888963407
        if state == 0 { state = 0x9E3779B97F4A7C15 }
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    /// 0 ..< 1.
    mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(UInt64(1) << 53)
    }
}
