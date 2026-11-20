import Foundation
import Metal

/// The CRT / scanline post-process shared by the terminal (`TerminalMetalView`), the Quick
/// Connect thumbnails (`CrtThumbnailView`). The command line's own CRT effect is the same maths as
/// a SwiftUI shader (`ScreenEffects.metal`), and shares `isAnimated` from here.
///
/// Windows keeps one `ApplySettings` / `SetOutputGeometry` / `IsAnimated` helper for the terminal,
/// the thumbnails and the console; this is the macOS equivalent. The shader source and the parameter block used
/// to live inline in `TerminalMetalView`; nothing in them changed when they moved here.
enum CrtShader {
    /// Swift mirror of the Metal CrtParams struct. Field order, types and
    /// therefore byte layout must match exactly.
    struct Params {
        var tint: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
        var texelSize: SIMD2<Float> = SIMD2<Float>(1.0 / 640, 1.0 / 400)
        var outputSize: SIMD2<Float> = SIMD2<Float>(1280, 800)
        var enabled: Float = 0
        var time: Float = 0
        var curvature: Float = 0
        var overscan: Float = 0
        var scanlineIntensity: Float = 0
        var scanlineCount: Float = 240
        var beamWidth: Float = 1
        var interlace: Float = 0
        var maskIntensity: Float = 0
        var maskPitch: Float = 3
        var glow: Float = 0
        var bloomThreshold: Float = 0.35
        var vignette: Float = 0
        var brightness: Float = 1
        var aberration: Float = 0
        var flicker: Float = 0
        var tintAmount: Float = 0
        var verticalHold: Float = 0
        var noise: Float = 0
        var scanSweep: Float = 0
    }

    /// The vertex shader draws one textured quad (`QuadParams` = offset + size in unit
    /// coordinates); the fragment shader is the CRT post-process.
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
    };

    struct QuadParams {
        float2 offset;
        float2 size;
    };

    vertex VertexOut vertexShader(uint vertexID [[vertex_id]],
                                  constant QuadParams &params [[buffer(0)]]) {
        float2 unitPos[4] = {
            float2(0, 0),
            float2(1, 0),
            float2(0, 1),
            float2(1, 1)
        };

        float2 texCoords[4] = {
            float2(0, 1),
            float2(1, 1),
            float2(0, 0),
            float2(1, 0)
        };

        float2 pos = unitPos[vertexID] * params.size + params.offset;
        pos = pos * 2.0 - 1.0;

        VertexOut out;
        out.position = float4(pos, 0, 1);
        out.texCoord = texCoords[vertexID];
        return out;
    }

    // CRT post-process parameters. Field order and types must stay in
    // lockstep with the Swift CrtShader.Params struct.
    struct CrtParams {
        float4 tint;
        float2 texelSize;
        float2 outputSize;
        float enabled;
        float time;
        float curvature;
        float overscan;
        float scanlineIntensity;
        float scanlineCount;
        float beamWidth;
        float interlace;
        float maskIntensity;
        float maskPitch;
        float glow;
        float bloomThreshold;
        float vignette;
        float brightness;
        float aberration;
        float flicker;
        float tintAmount;
        float verticalHold;
        float noise;
        float scanSweep;
    };

    // Barrel-distort the sample position so the picture bows out like a
    // tube face, then divide back down so the source edges land on the
    // screen edges instead of being pushed off it.
    static float2 crtCurve(float2 uv, float amount, float overscan) {
        uv = uv * 2.0 - 1.0;
        float2 off = abs(uv.yx) * float2(0.1666667, 0.25);
        uv += uv * off * off * amount;
        uv /= (1.0 + overscan);
        return uv * 0.5 + 0.5;
    }

    // Cheap value noise — enough for grain, and it costs one sin.
    static float crtHash(float2 p) {
        return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
    }

    fragment float4 fragmentShader(VertexOut in [[stage_in]],
                                   texture2d<float> tex [[texture(0)]],
                                   sampler s [[sampler(0)]],
                                   constant CrtParams &crt [[buffer(0)]]) {
        float2 uv0 = in.texCoord;

        if (crt.enabled < 0.5) {
            return tex.sample(s, saturate(uv0));
        }

        const float PI = 3.14159265;

        // Rolling hum bar: a soft band drifting up the screen that both
        // darkens and slightly pulls the picture, the way a tube with the
        // vertical hold just off does.
        float barPhase = fract(uv0.y - crt.time * 0.12);
        float bar = pow(saturate(sin(barPhase * PI)), 8.0);

        float2 uvIn = uv0;
        uvIn.y += crt.verticalHold * 0.004 * bar;

        float2 uv = crtCurve(uvIn, crt.curvature * 2.0, crt.overscan);

        // Anything the curvature pushed off the tube face shows nothing.
        float2 bounds = step(0.0, uv) * step(uv, float2(1.0));
        float inside = bounds.x * bounds.y;

        float2 cuv = saturate(uv);
        float4 center = tex.sample(s, cuv);
        float alpha = center.a;

        // Chromatic aberration: pull red and blue apart horizontally.
        float ab = crt.aberration * crt.texelSize.x * 4.0;
        float3 col;
        col.r = tex.sample(s, float2(saturate(cuv.x + ab), cuv.y)).r;
        col.g = center.g;
        col.b = tex.sample(s, float2(saturate(cuv.x - ab), cuv.y)).b;

        // Phosphor glow: cheap 8-tap ring blur, thresholded so only
        // genuinely bright pixels bloom rather than the whole picture.
        float2 o = crt.texelSize * 1.5;
        float3 g  = tex.sample(s, cuv + float2( o.x, 0.0)).rgb;
        g += tex.sample(s, cuv + float2(-o.x, 0.0)).rgb;
        g += tex.sample(s, cuv + float2(0.0,  o.y)).rgb;
        g += tex.sample(s, cuv + float2(0.0, -o.y)).rgb;
        g += tex.sample(s, cuv + float2( o.x,  o.y)).rgb;
        g += tex.sample(s, cuv + float2(-o.x,  o.y)).rgb;
        g += tex.sample(s, cuv + float2( o.x, -o.y)).rgb;
        g += tex.sample(s, cuv + float2(-o.x, -o.y)).rgb;
        g *= 0.125;
        g = max(g - crt.bloomThreshold, 0.0) / max(1.0 - crt.bloomThreshold, 0.001);
        col += g * crt.glow;

        // Monochrome phosphor (green/amber/white tubes).
        float lum = dot(col, float3(0.299, 0.587, 0.114));
        col = mix(col, lum * crt.tint.rgb, crt.tintAmount);

        // Raster lines. The beam is a gaussian across the line rather than
        // a plain cosine, so beamWidth goes from a soft wide sweep to a
        // tight bright filament with dark gaps either side.
        float linePos = fract(uv.y * crt.scanlineCount) - 0.5;
        float sigma = max(crt.beamWidth * crt.beamWidth * 0.25, 0.0001);
        float beam = exp(-(linePos * linePos) / sigma);
        col *= mix(1.0, beam, crt.scanlineIntensity);

        // Interlace: dim alternate lines, swapping fields every frame.
        float field = fmod(floor(crt.time * 60.0), 2.0);
        float odd = fmod(floor(uv.y * crt.scanlineCount), 2.0);
        col *= 1.0 - crt.interlace * 0.5 * abs(odd - field);

        // Aperture grille, measured in real output pixels so it stays put
        // when the window is resized.
        float m = fract(uv0.x * crt.outputSize.x / max(crt.maskPitch, 1.0)) * 3.0;
        float3 mask;
        mask.r = saturate(1.0 - abs(m - 0.5));
        mask.g = saturate(1.0 - abs(m - 1.5));
        mask.b = saturate(1.0 - abs(m - 2.5));
        col *= mix(float3(1.0), saturate(mask * 1.5 + 0.25), crt.maskIntensity);

        // Vignette.
        float2 v = uv * (1.0 - uv);
        col *= pow(saturate(v.x * v.y * 16.0), crt.vignette);

        // Rolling bar darkening, then mains-hum flicker.
        col *= 1.0 - crt.verticalHold * 0.30 * bar;
        col *= 1.0 + crt.flicker * 0.08 * sin(crt.time * 47.0);

        col *= crt.brightness;

        // Rolling refresh line sweeping down the tube. Mostly proportional
        // to what is already lit, plus a small additive floor so it stays
        // visible crossing black areas.
        float sweepY = fract(crt.time * 0.30);
        float sd = abs(uv.y - sweepY);
        sd = min(sd, 1.0 - sd);
        float sweep = exp(-(sd * sd) / 0.0004);
        col += (col * 0.8 + 0.05) * sweep * crt.scanSweep;

        // Static / snow, added last so the grain sits on top.
        float grain = crtHash(uv0 * crt.outputSize + crt.time * 60.0) - 0.5;
        col += grain * crt.noise * 0.35;

        // This pipeline blends with .sourceAlpha, i.e. straight (not
        // premultiplied) alpha, so the color is not scaled by alpha here.
        return float4(saturate(col) * inside, alpha * inside);
    }
    """

    /// Builds the render pipeline every CRT user shares: the quad vertex shader, the CRT
    /// fragment shader, BGRA8 output and straight-alpha blending so transparent source
    /// pixels let whatever is underneath show through.
    static func makePipeline(device: MTLDevice) throws -> MTLRenderPipelineState {
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vertexShader")
        descriptor.fragmentFunction = library.makeFunction(name: "fragmentShader")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Converts the shared CRT settings into shader units.
    ///
    /// Scanline and grille pitch are given in real output pixels (`quadWidth` / `quadHeight`
    /// are the drawable pixels the picture covers), so the lines stay crisp whatever the
    /// window size or the display's backing scale factor. Glow and aberration taps work in
    /// texture space, at the source's native resolution. A disabled setting returns a
    /// pass-through block (`enabled` = 0).
    static func params(settings s: CrtSettings,
                       quadWidth: Float, quadHeight: Float,
                       textureW: Float, textureH: Float,
                       time: Float) -> Params {
        var p = Params()
        guard s.enabled else { return p }

        let (r, g, b) = s.tintRGB
        p.tint = SIMD4<Float>(r, g, b, 1)
        p.texelSize = SIMD2<Float>(1.0 / max(textureW, 1), 1.0 / max(textureH, 1))
        p.outputSize = SIMD2<Float>(max(quadWidth, 1), max(quadHeight, 1))
        p.enabled = 1
        p.time = time

        p.curvature = Float(s.curvature)
        p.overscan = Float(s.overscan)
        p.scanlineIntensity = Float(s.scanlineIntensity)
        // One bright band per scanlinePitch drawable pixels: the shader's beam
        // repeats scanlineCount times over the height.
        p.scanlineCount = max(quadHeight, 1) / Float(max(s.scanlinePitch, 1))
        p.beamWidth = Float(max(s.beamWidth, 0.05))
        p.interlace = Float(s.interlace)
        p.maskIntensity = Float(s.maskIntensity)
        p.maskPitch = Float(max(s.maskPitch, 1))
        p.glow = Float(s.glow)
        p.bloomThreshold = Float(s.bloomThreshold)
        p.vignette = Float(s.vignette)
        p.brightness = Float(s.brightness)
        p.aberration = Float(s.aberration)
        p.flicker = Float(s.flicker)
        p.tintAmount = Float(s.tintAmount)
        p.verticalHold = Float(s.verticalHold)
        p.noise = Float(s.noise)
        p.scanSweep = Float(s.scanSweep)
        return p
    }

    /// True when the settings drive any time-based stage (flicker, interlace, rolling bar,
    /// static, sweep), i.e. the picture has to be redrawn on a timer rather than once.
    static func isAnimated(_ s: CrtSettings) -> Bool {
        s.enabled && (s.flicker > 0 || s.interlace > 0 || s.verticalHold > 0 || s.noise > 0 || s.scanSweep > 0)
    }
}
