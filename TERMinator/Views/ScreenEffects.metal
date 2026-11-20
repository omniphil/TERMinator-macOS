//  Screen effects for the home screen and the command line (spec §7).
//
//  Two SwiftUI "stitchable" shader functions, used through `View.screenEffect(...)`
//  (see ScreenEffect.swift):
//
//    * phosphorTint - the monochrome tube (View > Phosphor): every pixel becomes its
//      luminance (0.299 R + 0.587 G + 0.114 B) times the phosphor color, brightness x 1.2.
//      Mirrors the Windows client's CrtShaderEffect.CreateTintOnly, which is the CRT shader
//      with only its tint stage engaged and every other stage neutral.
//
//    * crtScreen - the full CRT post-process for the command line, the same pipeline as the
//      terminal's Metal fragment shader in CrtShader.swift, but sampling the SwiftUI layer
//      instead of a texture. When a phosphor mode is set the caller passes that color with
//      tintAmount 1, which is how Windows combines the two (an element can carry only one
//      effect there).
//
//  Never used on the terminal: that has its own MTKView pipeline.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

[[ stitchable ]] half4 phosphorTint(float2 position, half4 color, half4 tint)
{
    // SwiftUI hands the color over premultiplied; undo that, tint, and put it back.
    float alpha = float(color.a);
    float3 rgb = float3(color.rgb);
    if (alpha > 0.0001) {
        rgb /= alpha;
    }
    float luminance = dot(rgb, float3(0.299, 0.587, 0.114));
    float3 tinted = saturate(luminance * float3(tint.rgb) * 1.2);
    return half4(half3(tinted * alpha), half(alpha));
}

[[ stitchable ]] half4 crtScreen(float2 position,
                                 SwiftUI::Layer layer,
                                 float2 size,
                                 float2 outputSize,
                                 half4 tint,
                                 float time,
                                 float curvature,
                                 float overscan,
                                 float scanlineIntensity,
                                 float scanlineCount,
                                 float beamWidth,
                                 float interlace,
                                 float maskIntensity,
                                 float maskPitch,
                                 float glow,
                                 float bloomThreshold,
                                 float vignette,
                                 float brightness,
                                 float aberration,
                                 float flicker,
                                 float tintAmount,
                                 float verticalHold,
                                 float noise,
                                 float scanSweep)
{
    const float PI = 3.14159265;

    float2 extent = max(size, float2(1.0));
    float2 uv0 = position / extent;

    // Rolling hum bar: a soft band drifting up the screen that both darkens and slightly
    // pulls the picture, the way a tube with the vertical hold just off does.
    float barPhase = fract(uv0.y - time * 0.12);
    float bar = pow(saturate(sin(barPhase * PI)), 8.0);

    float2 uvIn = uv0;
    uvIn.y += verticalHold * 0.004 * bar;

    // Barrel-distort the sample position so the picture bows out like a tube face, then
    // divide back down so the source edges land on the screen edges.
    float2 uv = uvIn * 2.0 - 1.0;
    float2 curve = abs(uv.yx) * float2(0.1666667, 0.25);
    uv += uv * curve * curve * (curvature * 2.0);
    uv /= (1.0 + overscan);
    uv = uv * 0.5 + 0.5;

    // Anything the curvature pushed off the tube face shows nothing.
    float2 within = step(float2(0.0), uv) * step(uv, float2(1.0));
    float inside = within.x * within.y;

    float2 cuv = saturate(uv);
    float2 texel = 1.0 / max(outputSize, float2(1.0));

    half4 centerSample = layer.sample(cuv * extent);
    float alpha = float(centerSample.a);
    float unpremultiply = alpha > 0.0001 ? 1.0 / alpha : 1.0;
    float3 center = float3(centerSample.rgb) * unpremultiply;

    // Chromatic aberration: pull red and blue apart horizontally.
    float ab = aberration * texel.x * 4.0;
    float3 col;
    col.r = float(layer.sample(float2(saturate(cuv.x + ab), cuv.y) * extent).r) * unpremultiply;
    col.g = center.g;
    col.b = float(layer.sample(float2(saturate(cuv.x - ab), cuv.y) * extent).b) * unpremultiply;

    // Phosphor glow: cheap 8-tap ring blur, thresholded so only genuinely bright pixels bloom.
    float2 o = texel * 1.5;
    float3 g = float3(layer.sample(saturate(cuv + float2( o.x, 0.0)) * extent).rgb);
    g += float3(layer.sample(saturate(cuv + float2(-o.x, 0.0)) * extent).rgb);
    g += float3(layer.sample(saturate(cuv + float2(0.0,  o.y)) * extent).rgb);
    g += float3(layer.sample(saturate(cuv + float2(0.0, -o.y)) * extent).rgb);
    g += float3(layer.sample(saturate(cuv + float2( o.x,  o.y)) * extent).rgb);
    g += float3(layer.sample(saturate(cuv + float2(-o.x,  o.y)) * extent).rgb);
    g += float3(layer.sample(saturate(cuv + float2( o.x, -o.y)) * extent).rgb);
    g += float3(layer.sample(saturate(cuv + float2(-o.x, -o.y)) * extent).rgb);
    g *= 0.125 * unpremultiply;
    g = max(g - bloomThreshold, 0.0) / max(1.0 - bloomThreshold, 0.001);
    col += g * glow;

    // Monochrome phosphor (green/amber/white tubes).
    float luminance = dot(col, float3(0.299, 0.587, 0.114));
    col = mix(col, luminance * float3(tint.rgb), tintAmount);

    // Raster lines. The beam is a gaussian across the line rather than a plain cosine.
    float linePos = fract(uv.y * scanlineCount) - 0.5;
    float sigma = max(beamWidth * beamWidth * 0.25, 0.0001);
    float beam = exp(-(linePos * linePos) / sigma);
    col *= mix(1.0, beam, scanlineIntensity);

    // Interlace: dim alternate lines, swapping fields every frame.
    float field = fmod(floor(time * 60.0), 2.0);
    float odd = fmod(floor(uv.y * scanlineCount), 2.0);
    col *= 1.0 - interlace * 0.5 * abs(odd - field);

    // Aperture grille, measured in real output pixels so it stays put on a resize.
    float m = fract(uv0.x * outputSize.x / max(maskPitch, 1.0)) * 3.0;
    float3 mask;
    mask.r = saturate(1.0 - abs(m - 0.5));
    mask.g = saturate(1.0 - abs(m - 1.5));
    mask.b = saturate(1.0 - abs(m - 2.5));
    col *= mix(float3(1.0), saturate(mask * 1.5 + 0.25), maskIntensity);

    // Vignette.
    float2 v = uv * (1.0 - uv);
    col *= pow(saturate(v.x * v.y * 16.0), vignette);

    // Rolling bar darkening, then mains-hum flicker.
    col *= 1.0 - verticalHold * 0.30 * bar;
    col *= 1.0 + flicker * 0.08 * sin(time * 47.0);

    col *= brightness;

    // Rolling refresh line sweeping down the tube.
    float sweepY = fract(time * 0.30);
    float sd = abs(uv.y - sweepY);
    sd = min(sd, 1.0 - sd);
    float sweep = exp(-(sd * sd) / 0.0004);
    col += (col * 0.8 + 0.05) * sweep * scanSweep;

    // Static / snow, added last so the grain sits on top.
    float grain = fract(sin(dot(uv0 * outputSize + time * 60.0, float2(12.9898, 78.233))) * 43758.5453) - 0.5;
    col += grain * noise * 0.35;

    col = saturate(col) * inside;
    float outAlpha = alpha * inside;
    return half4(half3(col * outAlpha), half(outAlpha));
}
