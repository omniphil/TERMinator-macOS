import MetalKit
import AppKit
import QuartzCore

/// Metal-based terminal renderer with guaranteed nearest-neighbor scaling.
/// Renders terminal at native resolution (cols*fontW x rows*fontH) then GPU-scales to screen.
final class TerminalMetalView: MTKView, MTKViewDelegate {
    weak var terminalViewModel: TerminalViewModel?
    var onReady: (() -> Void)?

    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var terminalTexture: MTLTexture?
    private var nearestSampler: MTLSamplerState?
    private var linearSampler: MTLSamplerState?

    // Dynamic terminal dimensions (updated from viewModel each frame)
    private var currentWidth = 640   // screenColumns * fontWidth
    private var currentHeight = 400  // screenRows * fontHeight

    private var didNotifyReady = false

    // Persistent pixel buffer (reused across frames to avoid per-frame allocation): what the texture holds
    private var pixelBuffer: [UInt32] = []
    /// The text layer alone (glyphs + cursor), kept so a graphics-only frame can re-composite just the sixel
    /// rectangle over it without redrawing every glyph (Windows' partial sixel upload, 2026-09-15).
    private var textPixels: [UInt32] = []
    private var lastSixelVersion: Int = -1

    /// The shader's parameter block; the shader itself now lives in `CrtShader`, shared
    /// with the Quick Connect thumbnails and the command line console.
    private typealias CrtParams = CrtShader.Params

    /// Baseline for the shader's animated effects (flicker, interlace, roll
    /// bar, static, scan sweep). The view already redraws at 60fps, so no
    /// extra timer is needed.
    private let crtEpoch = CACurrentMediaTime()

    private var lastRenderedVersion: Int = -1
    private var lastBgActive: Bool = false
    private var lastTileActive: Bool = false


    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device ?? MTLCreateSystemDefaultDevice())
        commonInit()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        self.device = MTLCreateSystemDefaultDevice()
        commonInit()
    }

    private func commonInit() {
        guard let device = device else {
            print("[TerminalMetalView] No Metal device available")
            return
        }

        delegate = self
        framebufferOnly = true
        preferredFramesPerSecond = 60
        isPaused = false
        enableSetNeedsDisplay = false

        // On macOS, the layer is CAMetalLayer
        if let metalLayer = self.layer as? CAMetalLayer {
            metalLayer.magnificationFilter = .nearest
            metalLayer.minificationFilter = .nearest
            // Allow underlays (bg image, tiles) to show through transparent pixels
            metalLayer.isOpaque = false
        }

        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        commandQueue = device.makeCommandQueue()

        setupSamplers(device: device)
        setupPipeline()
        createTerminalTexture()
    }

    private func setupSamplers(device: MTLDevice) {
        let nearestDesc = MTLSamplerDescriptor()
        nearestDesc.minFilter = .nearest
        nearestDesc.magFilter = .nearest
        nearestDesc.sAddressMode = .clampToEdge
        nearestDesc.tAddressMode = .clampToEdge
        nearestSampler = device.makeSamplerState(descriptor: nearestDesc)

        let linearDesc = MTLSamplerDescriptor()
        linearDesc.minFilter = .linear
        linearDesc.magFilter = .linear
        linearDesc.sAddressMode = .clampToEdge
        linearDesc.tAddressMode = .clampToEdge
        linearSampler = device.makeSamplerState(descriptor: linearDesc)
    }

    // macOS MTKView needs wantsLayer
    override var wantsLayer: Bool {
        get { true }
        set { super.wantsLayer = newValue }
    }

    private func setupPipeline() {
        guard let device = device else { return }

        // The quad vertex shader + CRT fragment shader are shared with the thumbnails.
        do {
            pipelineState = try CrtShader.makePipeline(device: device)
        } catch {
            print("[TerminalMetalView] Failed to create pipeline: \(error)")
        }
    }

    private func createTerminalTexture() {
        guard let device = device else { return }

        let textureDescriptor = MTLTextureDescriptor()
        textureDescriptor.pixelFormat = .bgra8Unorm
        textureDescriptor.width = currentWidth
        textureDescriptor.height = currentHeight
        textureDescriptor.usage = [.shaderRead, .shaderWrite]
        textureDescriptor.storageMode = .shared

        terminalTexture = device.makeTexture(descriptor: textureDescriptor)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let viewModel = terminalViewModel,
              let pipelineState = pipelineState,
              let commandQueue = commandQueue,
              let drawable = currentDrawable,
              let renderPassDescriptor = currentRenderPassDescriptor else { return }

        if !didNotifyReady {
            didNotifyReady = true
            DispatchQueue.main.async { [weak self] in
                self?.onReady?()
            }
        }

        let fontW = viewModel.fontWidth > 0 ? viewModel.fontWidth : 8
        let fontH = viewModel.fontHeight > 0 ? viewModel.fontHeight : 16
        let cols = viewModel.screenColumns > 0 ? viewModel.screenColumns : 80
        let rows = viewModel.screenRows > 0 ? viewModel.screenRows : 25
        let neededWidth = cols * fontW
        let neededHeight = rows * fontH

        if neededWidth != currentWidth || neededHeight != currentHeight {
            currentWidth = neededWidth
            currentHeight = neededHeight
            createTerminalTexture()
            pixelBuffer = []
            textPixels = []
            lastRenderedVersion = -1

        }

        guard let texture = terminalTexture else { return }

        // Force re-render when bg/tile underlay state changes (affects transparent bg regions)
        // Also re-render when scrollback state changes (underlays hidden during scrollback)
        let scrollNow = viewModel.isInScrollback
        let bgNow = viewModel.bgActive && !scrollNow
        let tileNow = viewModel.tileMapActive && !viewModel.tileAtlasPixels.isEmpty && !scrollNow
        if bgNow != lastBgActive || tileNow != lastTileActive {
            lastRenderedVersion = -1
            lastBgActive = bgNow
            lastTileActive = tileNow
        }

        let currentVersion = viewModel.displayBufferVersion
        if currentVersion != lastRenderedVersion {
            if viewModel.displayBuffer.isEmpty {
                let pixelCount = currentWidth * currentHeight
                textPixels = []   // stale text must not come back under a partial sixel composite
                if pixelBuffer.count == pixelCount {
                    _ = pixelBuffer.withUnsafeMutableBytes { $0.initializeMemory(as: UInt32.self, repeating: 0xFF000000) }
                    let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                           size: MTLSize(width: currentWidth, height: currentHeight, depth: 1))
                    pixelBuffer.withUnsafeBytes { ptr in
                        guard let base = ptr.baseAddress else { return }
                        texture.replace(region: region, mipmapLevel: 0, withBytes: base, bytesPerRow: currentWidth * 4)
                    }
                }
            } else {
                renderTerminalToTexture(viewModel: viewModel, texture: texture)
            }
            lastRenderedVersion = currentVersion
            lastSixelVersion = viewModel.sixelVersion
            _ = viewModel.takeSixelDirtyRect()   // the full redraw already has it
        } else if viewModel.sixelVersion != lastSixelVersion {
            lastSixelVersion = viewModel.sixelVersion
            if let rect = viewModel.takeSixelDirtyRect() {
                compositeSixelRect(rect, viewModel: viewModel, texture: texture)
            }
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        let drawableW = Float(drawable.texture.width)
        let drawableH = Float(drawable.texture.height)
        let textureW = Float(currentWidth)
        let textureH = Float(currentHeight)

        // Aspect-fit: maintain correct text proportions at any window size.
        // SwiftUI-managed windows ignore contentAspectRatio, so the window
        // may not match the terminal's aspect ratio. We fit the content and
        // center it so any bars are evenly distributed.
        //
        // ⚠️ macOS PETSCII 2026-09-04: viewModel.displayAspect FORCES a non-natural
        // aspect, for EVERY mode. No text mode had square pixels: 80x25 is a 720x400
        // grid that filled a 4:3 monitor, and the Commodore modes render 320x200 (or
        // 640x200) shown at 6:5 (or 4:3). The picture is deliberately
        // stretched vertically. With displayAspect nil this is arithmetically
        // identical to the uniform min() scale it replaced — verified both branches.
        // Any mouse/overlay cell mapping must use the SAME algorithm or clicks land
        // on the wrong cell in a Commodore mode.
        let naturalAspect = textureH > 0 ? textureW / textureH : 1.6
        let aspect = viewModel.displayAspect.map { Float($0) } ?? naturalAspect

        var scaledW = drawableW
        var scaledH = aspect > 0 ? scaledW / aspect : drawableH
        if scaledH > drawableH {
            scaledH = drawableH
            scaledW = scaledH * aspect
        }

        let sizeX = scaledW / drawableW
        let sizeY = scaledH / drawableH

        // Center horizontally, top-align vertically
        let offsetX = (1.0 - sizeX) / 2.0
        let offsetY = 1.0 - sizeY

        var quadParams = (
            offset: SIMD2<Float>(offsetX, offsetY),
            size: SIMD2<Float>(sizeX, sizeY)
        )



        let viewport = MTLViewport(
            originX: 0, originY: 0,
            width: Double(drawableW), height: Double(drawableH),
            znear: 0.0, zfar: 1.0
        )
        renderEncoder.setViewport(viewport)
        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setVertexBytes(&quadParams, length: MemoryLayout.size(ofValue: quadParams), index: 0)
        renderEncoder.setFragmentTexture(texture, index: 0)
        let smoothing = UserDefaults.standard.bool(forKey: "font_smoothing")
        renderEncoder.setFragmentSamplerState(smoothing ? linearSampler : nearestSampler, index: 0)

        var crtParams = buildCrtParams(quadWidth: scaledW, quadHeight: scaledH,
                                       textureW: textureW, textureH: textureH)
        renderEncoder.setFragmentBytes(&crtParams,
                                       length: MemoryLayout<CrtParams>.stride,
                                       index: 0)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        renderEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Reads the shared CRT settings and converts them into shader units (see
    /// `CrtShader.params`). Scanline and grille pitch are in real drawable pixels.
    ///
    /// View > Phosphor tints the session too (Windows puts its tint on the container every screen lives in). The SwiftUI
    /// tint can't reach this Metal layer, so the phosphor goes into this shader's own tint stage: over the CRT at
    /// full strength when CRT is on (as `ScreenEffect` does), or alone — every other stage neutral, brightness × 1.2
    /// like `phosphorTint` — when it's off.
    private func buildCrtParams(quadWidth: Float, quadHeight: Float,
                                textureW: Float, textureH: Float) -> CrtParams {
        var settings = CrtSettingsStore.shared.current
        if let tintHex = PhosphorMode.current.tintHex {
            if !settings.enabled {
                settings = Self.tintOnlySettings
            }
            settings.tintColor = tintHex
            settings.tintAmount = 1
        }
        return CrtShader.params(settings: settings,
                         quadWidth: quadWidth, quadHeight: quadHeight,
                         textureW: textureW, textureH: textureH,
                         time: Float(CACurrentMediaTime() - crtEpoch))
    }

    /// The CRT shader with only its tint stage engaged (Windows' CrtShaderEffect.CreateTintOnly).
    private static let tintOnlySettings: CrtSettings = {
        var s = CrtSettings()
        s.enabled = true
        s.scanlineIntensity = 0; s.interlace = 0; s.maskIntensity = 0
        s.curvature = 0; s.overscan = 0; s.vignette = 0; s.flicker = 0
        s.glow = 0; s.aberration = 0; s.brightness = 1.2
        s.verticalHold = 0; s.noise = 0; s.scanSweep = 0
        return s
    }()

    private func renderTerminalToTexture(viewModel: TerminalViewModel, texture: MTLTexture) {
        let columns = viewModel.screenColumns
        let rows = viewModel.screenRows
        guard columns > 0, rows > 0 else { return }
        let fontWidth = viewModel.fontWidth > 0 ? viewModel.fontWidth : 8
        let fontHeight = viewModel.fontHeight > 0 ? viewModel.fontHeight : 16
        let bytesPerRow = (fontWidth + 7) / 8

        let pixelCount = currentWidth * currentHeight

        if pixelBuffer.count != pixelCount {
            pixelBuffer = [UInt32](repeating: 0xFF000000, count: pixelCount)
        }
        if textPixels.count != pixelCount {
            textPixels = [UInt32](repeating: 0xFF000000, count: pixelCount)
        }

        guard let fontBitmap = viewModel.fontBitmap else { return }

        let customPalette = viewModel.palette
        // True-colour overrides, in lockstep with displayBuffer (0 = use the palette index; see TerminalViewModel)
        let fgRGB = viewModel.displayFgRGB
        let bgRGB = viewModel.displayBgRGB

        // Determine which cells should have transparent backgrounds (for bg image / tile underlay)
        // During scrollback, disable underlay transparency so scrollback text has solid backgrounds
        let inScrollback = viewModel.isInScrollback
        let bgActive = viewModel.bgActive && !inScrollback
        let bgR1 = Int(viewModel.bgRow)
        let bgC1 = Int(viewModel.bgCol)
        let bgR2 = bgR1 + Int(viewModel.bgCellH) - 1
        let bgC2 = bgC1 + Int(viewModel.bgCellW) - 1

        let tileActive = viewModel.tileMapActive && !viewModel.tileAtlasPixels.isEmpty && !inScrollback
        let tileR1 = viewModel.tileMapRow1
        let tileC1 = viewModel.tileMapCol1
        let tileR2 = viewModel.tileMapRow2
        let tileC2 = viewModel.tileMapCol2

        fontBitmap.withUnsafeBytes { (fontPtr: UnsafeRawBufferPointer) in
            guard let fontBase = fontPtr.baseAddress else { return }

            for row in 0..<min(rows, currentHeight / fontHeight) {
                for col in 0..<min(columns, currentWidth / fontWidth) {
                    let index = row * columns + col
                    guard index < viewModel.displayBuffer.count else { continue }

                    let cell = viewModel.displayBuffer[index]
                    let cellUnsigned = UInt32(bitPattern: cell)
                    let charCode = Int(cellUnsigned & 0xFF)
                    // Use packed fg/bg bytes (matching Windows TerminalCanvas.cs)
                    var fgIndex = Int((cellUnsigned >> 16) & 0x7F)
                    var bgIndex = Int((cellUnsigned >> 24) & 0xFF)

                    // Blink attribute: bit 15 of packed cell (bit 7 of legacy_attr)
                    //
                    // ⚠️ macOS PETSCII 2026-09-04: in a Commodore (BGBRIGHT|NOBLINK) mode
                    // that bit means "background colour 8-15", NOT blink — and both lines
                    // below would be wrong there (the flicker, and masking the background
                    // down to 0-7). The native packer strips the bit in those modes (and
                    // while iCE colours / CIOLIB_VIDEO_BGBRIGHT are on), so this branch is
                    // never entered on a PETSCII or iCE screen. Do NOT
                    // "restore" the bit in native_get_screen_buffer(); check
                    // viewModel.petsciiMode here instead if this ever needs the value.
                    if (cell & 0x8000) != 0 {
                        bgIndex = bgIndex & 0x07
                        if !viewModel.textBlinkOn {
                            fgIndex = bgIndex
                        }
                    }
                    if fgIndex >= 16 { fgIndex = fgIndex & 0x0F }
                    if bgIndex >= 16 { bgIndex = bgIndex & 0x0F }

                    var fgColor = colorBGRA(fgIndex, palette: customPalette)
                    var bgColor = colorBGRA(bgIndex, palette: customPalette)

                    // True colour (ESC[38;2;R;G;Bm / 48;2): native hands the real 24-bit value for these cells
                    // instead of the nearest of 16. An RGB background is literal, so the blink mask above never
                    // applies to it; blink-off still hides the text by painting it in its own background.
                    if index < fgRGB.count, fgRGB[index] != 0 { fgColor = fgRGB[index] }
                    if index < bgRGB.count, bgRGB[index] != 0 { bgColor = bgRGB[index] }
                    if (cell & 0x8000) != 0 && !viewModel.textBlinkOn {
                        fgColor = bgColor
                    }

                    // Check if this cell is in a transparent-bg region (bg image or tile underlay)
                    let inBgRegion = bgActive && row >= bgR1 && row <= bgR2 && col >= bgC1 && col <= bgC2
                    let inTileRegion = tileActive && row >= tileR1 && row <= tileR2 && col >= tileC1 && col <= tileC2
                    let transparentBg = inBgRegion || inTileRegion
                    // Transparent background: alpha=0 so underlay shows through
                    let effectiveBg: UInt32 = transparentBg ? 0x00000000 : bgColor

                    let glyphOffset = charCode * fontHeight * bytesPerRow
                    let cellStartX = col * fontWidth
                    let cellStartY = row * fontHeight

                    for srcY in 0..<fontHeight {
                        let rowOffset = glyphOffset + srcY * bytesPerRow
                        let rowByte0: UInt8 = rowOffset < fontBitmap.count ?
                            fontBase.load(fromByteOffset: rowOffset, as: UInt8.self) : 0
                        let rowByte1: UInt8 = (bytesPerRow > 1 && rowOffset + 1 < fontBitmap.count) ?
                            fontBase.load(fromByteOffset: rowOffset + 1, as: UInt8.self) : 0

                        let destY = cellStartY + srcY
                        guard destY < currentHeight else { continue }
                        let pixelRowStart = destY * currentWidth
                        guard pixelRowStart + currentWidth <= textPixels.count else { continue }

                        for srcX in 0..<fontWidth {
                            let destX = cellStartX + srcX
                            guard destX < currentWidth else { continue }

                            let isSet: Bool
                            if srcX < 8 {
                                isSet = ((Int(rowByte0) >> (7 - srcX)) & 1) == 1
                            } else {
                                isSet = ((Int(rowByte1) >> (15 - srcX)) & 1) == 1
                            }

                            textPixels[pixelRowStart + destX] = isSet ? fgColor : effectiveBg
                        }
                    }
                }
            }
        }

        // Draw cursor using the BBS-controlled shape (curs_start/curs_end scanlines).
        // Respect the blink flag — steady cursors ignore cursorBlinkOn.
        let cursorActive =
            !viewModel.userHideCursor &&
            viewModel.cursorVisible &&
            viewModel.cursorType != .noCursor &&
            viewModel.scrollbackOffset == 0 &&
            (!viewModel.cursorBlinks || viewModel.cursorBlinkOn)

        if cursorActive {
            let cx = viewModel.cursorX - 1  // ciolib is 1-based
            let cy = viewModel.cursorY - 1
            // Resolve cursor band [startY, endY] within the cell.
            // _NOCURSOR sets curs_start=0xFF (out of range) — skip rendering.
            let rawStart = viewModel.cursorStart
            let rawEnd = viewModel.cursorEnd
            let inRange = rawStart < fontHeight && rawEnd >= 0 && rawStart <= rawEnd
            if inRange, cx >= 0, cx < columns, cy >= 0, cy < (currentHeight / fontHeight) {
                let cellIndex = cy * columns + cx
                let cellAttr: Int
                if cellIndex < viewModel.displayBuffer.count {
                    let cellVal = UInt32(bitPattern: viewModel.displayBuffer[cellIndex])
                    cellAttr = Int((cellVal >> 8) & 0xFF)
                } else {
                    cellAttr = 0x07  // default light gray
                }
                let cursorFgIndex = cellAttr & 0x0F
                let cursorColor = colorBGRA(cursorFgIndex, palette: customPalette)

                let startY = max(0, min(fontHeight - 1, rawStart))
                let endY = max(0, min(fontHeight - 1, rawEnd))
                let cellStartX = cx * fontWidth
                let cellOriginY = cy * fontHeight
                for py in startY...endY {
                    let destY = cellOriginY + py
                    guard destY < currentHeight else { continue }
                    let rowStart = destY * currentWidth
                    for px in 0..<fontWidth {
                        let destX = cellStartX + px
                        guard destX < currentWidth else { continue }
                        guard rowStart + destX < textPixels.count else { continue }
                        textPixels[rowStart + destX] = cursorColor
                    }
                }
            }
        }

        // Text, then the sixel layer over it, into the texture
        composite(x: 0, y: 0, width: currentWidth, height: currentHeight, viewModel: viewModel, texture: texture)
    }

    /// A graphics-only change: re-composite just the sixel layer's changed rectangle (layer pixels map 1:1 onto the
    /// texture) over the kept text layer, and upload only that region.
    private func compositeSixelRect(_ rect: CGRect, viewModel: TerminalViewModel, texture: MTLTexture) {
        guard textPixels.count == currentWidth * currentHeight, pixelBuffer.count == textPixels.count else {
            lastRenderedVersion = -1   // nothing kept to composite over yet: redraw it all next frame
            return
        }
        let x0 = max(0, Int(rect.minX))
        let y0 = max(0, Int(rect.minY))
        let x1 = min(currentWidth, Int(rect.maxX))
        let y1 = min(currentHeight, Int(rect.maxY))
        guard x1 > x0, y1 > y0 else { return }
        composite(x: x0, y: y0, width: x1 - x0, height: y1 - y0, viewModel: viewModel, texture: texture)
    }

    /// Copies the text layer into `pixelBuffer` over the given region, lays the non-transparent sixel pixels on top
    /// and uploads that region.
    private func composite(x: Int, y: Int, width: Int, height: Int, viewModel: TerminalViewModel, texture: MTLTexture) {
        let cw = currentWidth
        guard width > 0, height > 0, textPixels.count == cw * currentHeight, pixelBuffer.count == textPixels.count
        else { return }
        let sw = viewModel.sixelWidth
        let sh = viewModel.sixelHeight
        let sixel = viewModel.hasSixelData && sw > 0 && sh > 0 ? viewModel.sixelPixels : nil

        textPixels.withUnsafeBufferPointer { text in
            pixelBuffer.withUnsafeMutableBufferPointer { out in
                guard let textBase = text.baseAddress, let outBase = out.baseAddress else { return }
                for row in y..<(y + height) {
                    (outBase + row * cw + x).update(from: textBase + row * cw + x, count: width)
                }
                guard let sixel = sixel, sixel.count >= sw * sh else { return }
                sixel.withUnsafeBufferPointer { src in
                    guard let srcBase = src.baseAddress else { return }
                    let rowEnd = min(y + height, sh)
                    let colEnd = min(x + width, sw)
                    guard rowEnd > y, colEnd > x else { return }
                    for row in y..<rowEnd {
                        let srcRow = srcBase + row * sw
                        let dstRow = outBase + row * cw
                        for col in x..<colEnd {
                            let pixel = srcRow[col]
                            if (pixel & 0xFF000000) != 0 {  // non-transparent
                                dstRow[col] = pixel
                            }
                        }
                    }
                }
            }
        }

        let region = MTLRegion(origin: MTLOrigin(x: x, y: y, z: 0),
                               size: MTLSize(width: width, height: height, depth: 1))
        pixelBuffer.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            texture.replace(region: region, mipmapLevel: 0, withBytes: base + (y * cw + x) * 4,
                            bytesPerRow: cw * 4)
        }
    }

    private func colorBGRA(_ index: Int, palette: [Int32]) -> UInt32 {
        if index >= 0 && index < palette.count && !palette.isEmpty {
            return 0xFF000000 | UInt32(bitPattern: palette[index])
        }

        let defaultPalette: [UInt32] = [
            0xFF000000, 0xFF0000AA, 0xFF00AA00, 0xFF00AAAA,
            0xFFAA0000, 0xFFAA00AA, 0xFFAA5500, 0xFFAAAAAA,
            0xFF555555, 0xFF5555FF, 0xFF55FF55, 0xFF55FFFF,
            0xFFFF5555, 0xFFFF55FF, 0xFFFFFF55, 0xFFFFFFFF
        ]

        if index >= 0 && index < defaultPalette.count {
            return defaultPalette[index]
        }
        return 0xFFFFFFFF
    }
}

// MARK: - SwiftUI Wrapper

import SwiftUI

struct TerminalMetalViewRepresentable: NSViewRepresentable {
    @ObservedObject var viewModel: TerminalViewModel
    var onReady: (() -> Void)?

    func makeNSView(context: Context) -> TerminalMetalView {
        let view = TerminalMetalView(frame: .zero, device: nil)
        view.terminalViewModel = viewModel
        view.onReady = onReady
        return view
    }

    func updateNSView(_ nsView: TerminalMetalView, context: Context) {
        nsView.terminalViewModel = viewModel
    }
}
