import SwiftUI
import MetalKit
import QuartzCore
import Combine

/// A Quick Connect snapshot drawn through the terminal's CRT shader, so the tiles look the
/// way the boards will once connected. Same settings as the terminal, live from the CRT
/// settings window (`CrtSettingsStore`); the caller only shows this view while CRT mode is
/// on, so turning it off removes the effect.
///
/// Fail-soft: without a Metal device, a pipeline or a texture the view simply draws nothing,
/// and the plain snapshot the caller keeps underneath shows through (the layer is transparent).
struct CrtThumbnailView: NSViewRepresentable {
    /// PNG/whatever bytes of the snapshot (`BBSEntry.snapshotData`). Compared by value so
    /// SwiftUI re-renders don't re-upload the texture.
    let imageData: Data
    /// The home layout's scale-to-fit factor, so scanline / grille pitch can be measured in
    /// the real device pixels the thumbnail covers on screen (updated on window resize and
    /// on the layout toggle, because both change the scale).
    let layoutScale: CGFloat
    /// View > Phosphor (spec §7). A monochrome mode has to reach this shader directly: the rest of
    /// the home screen is tinted by a SwiftUI `colorEffect`, which cannot filter an AppKit-hosted
    /// Metal view, so without this the thumbnails would stay in color while everything around them
    /// went monochrome. `.color` leaves the CRT settings' own tube color in charge.
    var phosphor: PhosphorMode = .color

    func makeNSView(context: Context) -> CrtThumbnailMetalView {
        let view = CrtThumbnailMetalView(frame: .zero, device: nil)
        view.layoutScale = layoutScale
        view.phosphor = phosphor
        view.setImageData(imageData)
        return view
    }

    func updateNSView(_ nsView: CrtThumbnailMetalView, context: Context) {
        nsView.layoutScale = layoutScale
        nsView.phosphor = phosphor
        nsView.setImageData(imageData)
    }
}

/// The Metal view behind `CrtThumbnailView`. One static texture, one full-size quad, the
/// shared `CrtShader` pipeline. Redraws on demand for static settings and at ~30 fps only
/// while a time-based CRT feature (flicker, interlace, rolling bar, noise, sweep) is on —
/// and only while it is on screen, since SwiftUI drops the view with the home screen.
final class CrtThumbnailMetalView: MTKView, MTKViewDelegate {
    var layoutScale: CGFloat = 1 {
        didSet { if layoutScale != oldValue { updateDrawableSize() } }
    }

    /// View > Phosphor: overrides the CRT settings' tube color at full strength (see `crtTint`).
    var phosphor: PhosphorMode = .color {
        didSet { if phosphor != oldValue, isPaused { needsDisplay = true } }
    }

    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var nearestSampler: MTLSamplerState?
    private var texture: MTLTexture?
    private var currentData: Data?
    private var settingsSink: AnyCancellable?
    private var settings: CrtSettings = CrtSettingsStore.shared.current
    private let crtEpoch = CACurrentMediaTime()

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device ?? MTLCreateSystemDefaultDevice())
        commonInit()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        self.device = MTLCreateSystemDefaultDevice()
        commonInit()
    }

    // macOS MTKView needs wantsLayer
    override var wantsLayer: Bool {
        get { true }
        set { super.wantsLayer = newValue }
    }

    private func commonInit() {
        guard let device = device else { return }   // fail-soft: nothing is drawn

        delegate = self
        framebufferOnly = true
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        // The drawable is sized by hand (see updateDrawableSize) so the pitch follows the
        // on-screen size through the layout scaling, not the unscaled layout size.
        autoResizeDrawable = false
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.isOpaque = false
            metalLayer.magnificationFilter = .linear
            metalLayer.minificationFilter = .linear
        }

        commandQueue = device.makeCommandQueue()
        pipelineState = try? CrtShader.makePipeline(device: device)

        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .nearest
        samplerDesc.magFilter = .nearest
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        nearestSampler = device.makeSamplerState(descriptor: samplerDesc)

        applySettings(CrtSettingsStore.shared.current)
        settingsSink = CrtSettingsStore.shared.$current
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newSettings in
                self?.applySettings(newSettings)
            }
    }

    /// Mirrors the terminal's CRT settings; static settings redraw once, animated ones tick.
    private func applySettings(_ s: CrtSettings) {
        settings = s
        let animated = CrtShader.isAnimated(s)
        if animated {
            enableSetNeedsDisplay = false
            preferredFramesPerSecond = 30
            isPaused = false
        } else {
            isPaused = true
            enableSetNeedsDisplay = true
            needsDisplay = true
        }
    }

    func setImageData(_ data: Data) {
        guard data != currentData else { return }
        currentData = data
        texture = makeTexture(from: data)
        if isPaused { needsDisplay = true }
    }

    private func makeTexture(from data: Data) -> MTLTexture? {
        guard let device = device,
              let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let loader = MTKTextureLoader(device: device)
        // Top-left origin, like the terminal's pixel buffer, so the quad's texture
        // coordinates show the picture the right way up.
        return try? loader.newTexture(cgImage: cgImage, options: [
            .SRGB: false,
            .origin: MTKTextureLoader.Origin.topLeft,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
        ])
    }

    // MARK: - Geometry

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    /// Drawable = the real device pixels this thumbnail covers on screen: layout size ×
    /// backing scale × the home layout's scale-to-fit factor.
    private func updateDrawableSize() {
        let backing = window?.backingScaleFactor ?? (NSScreen.main?.backingScaleFactor ?? 2)
        let scale = max(0.01, backing * layoutScale)
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()),
                          height: max(1, (bounds.height * scale).rounded()))
        if size != drawableSize {
            drawableSize = size
            if isPaused { needsDisplay = true }
        }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let texture = texture,
              let pipelineState = pipelineState,
              let commandQueue = commandQueue,
              let drawable = currentDrawable,
              let renderPassDescriptor = currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }

        let drawableW = Float(drawable.texture.width)
        let drawableH = Float(drawable.texture.height)

        // The whole view: the caller already stretched the thumbnail to 4:3.
        var quadParams = (
            offset: SIMD2<Float>(0, 0),
            size: SIMD2<Float>(1, 1)
        )
        var crtParams = CrtShader.params(settings: settings,
                                         quadWidth: drawableW, quadHeight: drawableH,
                                         textureW: Float(texture.width), textureH: Float(texture.height),
                                         time: Float(CACurrentMediaTime() - crtEpoch))
        // A phosphor mode wins over the settings' own tube color, at full strength — the same
        // combination the command line uses (§7). The shader's tint stage is already the phosphor
        // maths (luminance 0.299/0.587/0.114 × tint), so the thumbnail goes monochrome with the
        // rest of the home screen. In Color mode the settings' tint is left untouched.
        if let tint = Self.tintRGB(phosphor) {
            crtParams.tint = SIMD4<Float>(tint.0, tint.1, tint.2, 1)
            crtParams.tintAmount = 1
        }

        encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                                        width: Double(drawableW), height: Double(drawableH),
                                        znear: 0, zfar: 1))
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(&quadParams, length: MemoryLayout.size(ofValue: quadParams), index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(nearestSampler, index: 0)
        encoder.setFragmentBytes(&crtParams, length: MemoryLayout<CrtShader.Params>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// The phosphor tube color as shader floats (Green `#33FF66`, Amber `#FFB000`, White
    /// `#EEF4FF`, straight from `PhosphorMode.tintHex`), or nil in Color mode. Parsed here rather
    /// than going through `Color`, since the shader wants plain components.
    private static func tintRGB(_ phosphor: PhosphorMode) -> (Float, Float, Float)? {
        guard var hex = phosphor.tintHex else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return (Float((value >> 16) & 0xFF) / 255,
                Float((value >> 8) & 0xFF) / 255,
                Float(value & 0xFF) / 255)
    }
}
