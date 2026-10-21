// The Light engine's GPU kernels, compiled once at run time. Everything works on linear light in
// extended sRGB primaries (values past 1 are HDR, negatives are colours outside sRGB); tone
// decisions are taken on luminance encoded with the sRGB curve, which is close to how bright
// things look. Brightness changes go back onto the pixel as a ratio of luminance, so hue and
// saturation stay where they were unless an algorithm says otherwise.

enum LightKernels {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

struct Params {
    float exposure, contrast, brightness, highlights, shadows;
    int exposureAlgorithm, highlightsAlgorithm, shadowsAlgorithm;
    /// Linear white: 1 for SDR, the content headroom for HDR.
    float white;
    /// 1 when the result is shown on an SDR scale: it is clamped to white at the end.
    int clampWhite;
    /// 0: linear extended sRGB (float). 1: Display P3, sRGB curve, dithered (8-bit).
    int outputEncoding;
    /// Which local paths ran: bit 0 guided base, bit 1 Laplacian.
    int localPaths;
    /// Laplacian: which sliders it carries (bit 0 highlights, bit 1 shadows).
    int laplacianMask;
    float gamma;      // this sample's level, Laplacian remap
    float gammaStep;  // spacing between samples
    float sigma;      // detail range
    int first;        // first sample: the output is written, not added to
    int top;          // the pyramid's coarsest level: no finer residual to subtract
    float lumaWhite;  // encoded white
    float eps;        // guided filter regularisation
    int radius;       // box radius, guided filter
    /// White balance, a linear sRGB matrix by rows; `whiteBalance` 0 skips it.
    float wb0, wb1, wb2, wb3, wb4, wb5, wb6, wb7, wb8;
    int whiteBalance;
    /// Colour grading: a colour direction for shadows, midtones and highlights, and the balance.
    float gs0, gs1, gs2, gm0, gm1, gm2, gh0, gh1, gh2;
    float balance;
    int grade;
    /// Detail: this level's gains for sharpening, texture and clarity (already weighted), the
    /// picture's noise (encoded luminance), the level, and where edges begin and end.
    float detailS, detailT, detailC;
    float noise;
    int level;
    float edgeLow, edgeHigh;
    /// Noise reduction: how much of the denoised picture, and whether there is one.
    float denoise;
    int hasDenoised;
    /// −1…+1 each.
    float vibrance, saturation;
};

constant float3 lumaWeights = float3(0.2126, 0.7152, 0.0722);

inline float enc(float y) {
    float a = fabs(y);
    float e = a <= 0.0031308 ? a * 12.92 : 1.055 * pow(a, 1.0 / 2.4) - 0.055;
    return copysign(e, y);
}

inline float dec(float e) {
    float a = fabs(e);
    float y = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4);
    return copysign(y, e);
}

inline float3 enc3(float3 c) { return float3(enc(c.r), enc(c.g), enc(c.b)); }
inline float3 dec3(float3 c) { return float3(dec(c.r), dec(c.g), dec(c.b)); }

/// Identity up to a knee, then a smooth shoulder that lands the old white (`X`, > 1) on 1.
/// Continuous in value and slope at the knee; the knee drops from 1 towards 0.5 as X grows.
inline float rolloff(float x, float X) {
    if (X <= 1.0001) return x;
    float k = 1.0 - 0.5 * (1.0 - 1.0 / X);
    if (x <= k) return x;
    float t = min((x - k) / (X - k), 1.0);
    float p = (X - k) / (1.0 - k);
    return k + (1.0 - k) * (1.0 - pow(1.0 - t, p));
}

/// Highlights: −1 pulls the bright end down to show what is in it, +1 lifts it towards white.
/// `l` is encoded luminance on a 0…1 scale.
inline float highlightCurve(float l, float h) {
    if (h == 0.0) return 0.0;
    float s = smoothstep(0.4, 1.0, l);
    float d = h < 0.0 ? h * 0.32 * s : h * 0.6 * s * max(1.0 - l, 0.0);
    return l > 1.0 && h > 0.0 ? 0.0 : d;
}

/// Shadows: +1 opens the dark end, −1 deepens it. Black stays black.
inline float shadowCurve(float l, float s) {
    if (s == 0.0 || l <= 0.0) return 0.0;
    float w = 1.0 - smoothstep(0.0, 0.6, l);
    return (s > 0.0 ? s * 1.6 : s * 0.6) * l * w * w;
}

/// Brightness offset (encoded, 0…1 scale) the tone sliders ask for at base level `b`, for the
/// sliders whose algorithm is `algorithm`.
inline float toneOffset(float b, constant Params& p, int algorithm) {
    float lw = p.lumaWhite;
    float n = b / lw, d = 0.0;
    if (p.highlightsAlgorithm == algorithm) d += highlightCurve(n, p.highlights);
    if (p.shadowsAlgorithm == algorithm) d += shadowCurve(n, p.shadows);
    return d * lw;
}

// MARK: - Oklab (Ottosson), for vibrance and saturation

inline float3 toOklab(float3 c) {
    float3 lms = float3(dot(float3(0.4122214708, 0.5363325363, 0.0514459929), c),
                        dot(float3(0.2119034982, 0.6806995451, 0.1073969566), c),
                        dot(float3(0.0883024619, 0.2817188376, 0.6299787005), c));
    lms = sign(lms) * pow(fabs(lms), 1.0 / 3.0);
    return float3(dot(float3(0.2104542553, 0.7936177850, -0.0040720468), lms),
                  dot(float3(1.9779984951, -2.4285922050, 0.4505937099), lms),
                  dot(float3(0.0259040371, 0.7827717662, -0.8086757660), lms));
}

inline float3 fromOklab(float3 o) {
    float3 lms = float3(o.x + 0.3963377774 * o.y + 0.2158037573 * o.z,
                        o.x - 0.1055613458 * o.y - 0.0638541728 * o.z,
                        o.x - 0.0894841775 * o.y - 1.2914855480 * o.z);
    lms = lms * lms * lms;
    return float3(dot(float3(4.0767416621, -3.3077115913, 0.2309699292), lms),
                  dot(float3(-1.2684380046, 2.6097574011, -0.3413193965), lms),
                  dot(float3(-0.0041960863, -0.7034186147, 1.7076147010), lms));
}

/// Inside Display P3, the widest the screen shows, with a hair of slack (`c` on a 0…1 scale).
inline bool inP3(float3 c) {
    const float3x3 toP3 = float3x3(float3(0.8225, 0.0332, 0.0171), float3(0.1774, 0.9669, 0.0724),
                                   float3(0.0000, 0.0000, 0.9108));
    float3 q = toP3 * c;
    return all(q >= -1e-4) && all(q <= 1.0001);
}

/// How much a colour is skin, 0…1: the orange hues from rose to tan (Oklab hue about 20–85°),
/// at the moderate chroma skin has for its lightness, and not in deep shadow.
inline float skinLikeness(float3 o) {
    float c = length(o.yz);
    if (c < 1e-5) return 0.0;
    float h = atan2(o.z, o.y) * 57.29578;
    float dh = (h - 52.0) / 24.0;
    float relative = c / max(o.x, 1e-3);
    return exp(-0.5 * dh * dh) * smoothstep(0.015, 0.045, relative) * (1.0 - smoothstep(0.2, 0.3, relative))
         * smoothstep(0.2, 0.35, o.x);
}

/// Vibrance and saturation on a linear sRGB colour (0…1 scale), in Oklab: lightness and hue stay,
/// chroma is scaled. Vibrance raises a colour by how muted it is and skin barely at all; saturation
/// raises every colour alike and skin by half. Lowered, saturation greys everything evenly and
/// vibrance the most saturated colours first. A raised colour comes softly to rest at the edge of
/// Display P3 instead of clipping there, which would change its hue.
inline float3 vibranceAndSaturation(float3 c, float vibrance, float saturation) {
    float3 o = toOklab(c);
    float chroma = length(o.yz);
    if (chroma < 1e-6) return c;
    float skin = skinLikeness(o);
    // Oklab's chroma reaches about 0.33 in sRGB; past a quarter, a colour is a strong one.
    float strength = clamp(chroma / 0.25, 0.0, 1.0);
    float k = 1.0;
    if (vibrance > 0.0) {
        k *= 1.0 + vibrance * 1.3 * (1.0 - strength) * (1.0 - strength) * (1.0 - 0.85 * skin);
    } else if (vibrance < 0.0) {
        k *= 1.0 + vibrance * (0.35 + 0.65 * strength);
    }
    if (saturation > 0.0) {
        k *= 1.0 + saturation * (1.0 - 0.5 * skin);
    } else if (saturation < 0.0) {
        k *= 1.0 + saturation;
    }
    if (k > 1.0 && inP3(c)) {
        // The furthest chroma that stays inside, by bisection, then a soft knee towards it.
        float lo = 1.0, hi = k;
        if (!inP3(fromOklab(float3(o.x, o.yz * k)))) {
            for (int i = 0; i < 10; i++) {
                float mid = 0.5 * (lo + hi);
                if (inP3(fromOklab(float3(o.x, o.yz * mid)))) lo = mid; else hi = mid;
            }
            float limit = lo, knee = 1.0 + 0.7 * (limit - 1.0);
            if (k > knee) k = knee + (limit - knee) * (1.0 - exp(-(k - knee) / max(limit - knee, 1e-4)));
        }
    } else if (k > 1.0) {
        // Already outside the screen's colours: no further.
        k = 1.0;
    }
    return fromOklab(float3(o.x, o.yz * k));
}

inline float sigmoid(float x) { return 1.0 / (1.0 + exp(-x)); }

/// Moves a pixel's luminance from `y0` to `y1`, keeping its colour.
inline float3 withLuminance(float3 rgb, float y0, float y1) {
    if (fabs(y0) > 1e-6) return rgb * (y1 / y0);
    return rgb + (y1 - y0);
}

// MARK: - Exposure, and the luminance the tone sliders read

kernel void prepare(texture2d<float, access::read> src [[texture(0)]],
                    texture2d<float, access::write> lit [[texture(1)]],
                    texture2d<float, access::write> luma [[texture(2)]],
                    texture2d<float, access::read> denoised [[texture(3)]],
                    constant Params& p [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= src.get_width() || gid.y >= src.get_height()) return;
    float4 c = src.read(gid);
    // Noise reduction first: the denoised picture mixed in, before anything else is done.
    if (p.hasDenoised && p.denoise > 0.0) c = mix(c, denoised.read(gid), p.denoise);
    float3 rgb = c.a > 0.0 ? c.rgb / c.a : float3(0.0);
    // White balance first: the light the picture was taken under, adapted to the display's.
    if (p.whiteBalance) {
        rgb = float3(dot(float3(p.wb0, p.wb1, p.wb2), rgb), dot(float3(p.wb3, p.wb4, p.wb5), rgb),
                     dot(float3(p.wb6, p.wb7, p.wb8), rgb));
    }
    // Exposure multiplies the light. Raised, what passes white either clips (1), or the brightest
    // channel rolls off into white keeping each colour's hue and saturation (2), or each channel
    // rolls off on its own, so the brightest colours drift to white as on film (3).
    float g = exp2(p.exposure);
    rgb *= g;
    if (p.exposure > 0.0 && p.exposureAlgorithm == 2) {
        float m = max(rgb.r, max(rgb.g, rgb.b));
        if (m > 0.0) rgb *= p.white * rolloff(m / p.white, g) / m;
    } else if (p.exposure > 0.0 && p.exposureAlgorithm == 3) {
        rgb = float3(rolloff(rgb.r / p.white, g), rolloff(rgb.g / p.white, g), rolloff(rgb.b / p.white, g)) * p.white;
    }
    lit.write(float4(rgb, c.a), gid);
    luma.write(float4(enc(dot(rgb, lumaWeights))), gid);
}

// MARK: - Pyramids

/// Halves a single-channel image with the 5-tap binomial filter, edges extended.
kernel void downsample(texture2d<float, access::read> src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    const float w[5] = {1.0, 4.0, 6.0, 4.0, 1.0};
    int2 size = int2(src.get_width(), src.get_height());
    int2 c = int2(gid) * 2;
    float sum = 0.0;
    for (int j = -2; j <= 2; j++) {
        int y = clamp(c.y + j, 0, size.y - 1);
        float row = 0.0;
        for (int i = -2; i <= 2; i++) {
            int x = clamp(c.x + i, 0, size.x - 1);
            row += w[i + 2] * src.read(uint2(x, y)).r;
        }
        sum += w[j + 2] * row;
    }
    dst.write(float4(sum / 256.0), gid);
}

/// The coarser level at a finer pixel: bilinear, centres aligned.
inline float upsampled(texture2d<float, access::sample> coarse, uint2 gid, uint2 fineSize) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(fineSize);
    return coarse.sample(s, uv).r;
}

/// The Laplacian remap for one sample level γ: near γ (closer than σ) the pixel keeps its detail
/// at full strength riding on the curve's value at γ; far from it (an edge) it follows the curve
/// itself, which is what stops halos.
kernel void remap(texture2d<float, access::read> luma [[texture(0)]],
                  texture2d<float, access::write> dst [[texture(1)]],
                  constant Params& p [[buffer(0)]],
                  uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float i = luma.read(gid).r;
    float g = p.gamma;
    float tg = g + toneOffset(g, p, 3);
    float ti = i + toneOffset(i, p, 3);
    float near = tg + (i - g);
    float far = smoothstep(p.sigma, 2.0 * p.sigma, fabs(i - g));
    dst.write(float4(mix(near, ti, far)), gid);
}

/// Adds sample γ's share of one output level: its remapped image's Laplacian coefficient there,
/// weighted by how close the input's own Gaussian level is to γ.
kernel void accumulate(texture2d<float, access::read> level [[texture(0)]],
                       texture2d<float, access::sample> coarser [[texture(1)]],
                       texture2d<float, access::read> guide [[texture(2)]],
                       texture2d<float, access::read_write> out [[texture(3)]],
                       constant Params& p [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    uint2 size = uint2(out.get_width(), out.get_height());
    if (gid.x >= size.x || gid.y >= size.y) return;
    float coefficient = level.read(gid).r - (p.top ? 0.0 : upsampled(coarser, gid, size));
    float g = clamp(guide.read(gid).r, 0.0, p.lumaWhite);
    float weight = max(0.0, 1.0 - fabs(g - p.gamma) / p.gammaStep);
    float before = p.first ? 0.0 : out.read(gid).r;
    out.write(float4(before + weight * coefficient), gid);
}

/// Puts a level back together: its coefficients plus the coarser level, already rebuilt.
kernel void collapse(texture2d<float, access::read_write> level [[texture(0)]],
                     texture2d<float, access::sample> coarser [[texture(1)]],
                     uint2 gid [[thread_position_in_grid]]) {
    uint2 size = uint2(level.get_width(), level.get_height());
    if (gid.x >= size.x || gid.y >= size.y) return;
    level.write(float4(level.read(gid).r + upsampled(coarser, gid, size)), gid);
}

// MARK: - Detail

/// One level of detail: this level's band of the luminance (the level minus the coarser one),
/// boosted by what the sliders ask for, but only where it is detail. A band no larger than the
/// picture's noise at this scale is grain and is left alone; a band as large as an edge is left
/// alone too, which is what keeps halos away; the deepest shadows, where noise lives, get less.
/// Negative texture and clarity soften instead, without guards. Writes the change only.
kernel void detailBand(texture2d<float, access::read> level [[texture(0)]],
                       texture2d<float, access::sample> coarser [[texture(1)]],
                       texture2d<float, access::write> out [[texture(2)]],
                       constant Params& p [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    uint2 size = uint2(out.get_width(), out.get_height());
    if (gid.x >= size.x || gid.y >= size.y) return;
    if (p.top) { out.write(float4(0.0), gid); return; }
    float up = upsampled(coarser, gid, size);
    float c = level.read(gid).r - up;
    float base = clamp(up / p.lumaWhite, 0.0, 1.0);
    float a = fabs(c) / p.lumaWhite;
    float sigma = p.noise * pow(0.55, float(p.level));
    // From two to four times the noise: Gaussian grain rarely reaches past twice its own spread,
    // so what is boosted is almost all picture.
    float aboveNoise = smoothstep(2.0 * sigma, 4.0 * sigma + 1e-4, a);
    float notEdge = 1.0 - smoothstep(p.edgeLow, p.edgeHigh, a);
    float lit = smoothstep(0.02, 0.12, base);
    float midtones = 1.0 - (2.0 * base - 1.0) * (2.0 * base - 1.0);
    float boost = (max(p.detailS, 0.0) + max(p.detailT, 0.0)) * aboveNoise * notEdge * lit
                + max(p.detailC, 0.0) * midtones * aboveNoise * notEdge;
    float soften = max(min(p.detailT, 0.0) + min(p.detailC, 0.0) * midtones, -1.0);
    out.write(float4((boost + soften) * c), gid);
}

// MARK: - Guided filter (He, Sun and Tang), on a reduced copy of the luminance

/// Packs (I, I²) for the box means.
kernel void guidedMoments(texture2d<float, access::read> src [[texture(0)]],
                          texture2d<float, access::write> dst [[texture(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float i = src.read(gid).r;
    dst.write(float4(i, i * i, 0.0, 0.0), gid);
}

kernel void boxHorizontal(texture2d<float, access::read> src [[texture(0)]],
                          texture2d<float, access::write> dst [[texture(1)]],
                          constant Params& p [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    int w = src.get_width();
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float4 sum = 0.0;
    for (int i = -p.radius; i <= p.radius; i++) sum += src.read(uint2(clamp(int(gid.x) + i, 0, w - 1), gid.y));
    dst.write(sum / float(2 * p.radius + 1), gid);
}

kernel void boxVertical(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant Params& p [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    int h = src.get_height();
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float4 sum = 0.0;
    for (int i = -p.radius; i <= p.radius; i++) sum += src.read(uint2(gid.x, clamp(int(gid.y) + i, 0, h - 1)));
    dst.write(sum / float(2 * p.radius + 1), gid);
}

/// The local linear model q = a·I + b from the box means of I and I².
kernel void guidedCoefficients(texture2d<float, access::read> moments [[texture(0)]],
                               texture2d<float, access::write> dst [[texture(1)]],
                               constant Params& p [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float4 m = moments.read(gid);
    float variance = max(m.y - m.x * m.x, 0.0);
    float a = variance / (variance + p.eps);
    dst.write(float4(a, m.x - a * m.x, 0.0, 0.0), gid);
}

// MARK: - Everything else, and the output

kernel void finish(texture2d<float, access::read> lit [[texture(0)]],
                   texture2d<float, access::read> luma [[texture(1)]],
                   texture2d<float, access::sample> guided [[texture(2)]],
                   texture2d<float, access::read> laplacian [[texture(3)]],
                   texture2d<float, access::write> out [[texture(4)]],
                   texture2d<float, access::read> detailFine [[texture(5)]],
                   texture2d<float, access::read> detailCoarse [[texture(6)]],
                   constant Params& p [[buffer(0)]],
                   uint2 gid [[thread_position_in_grid]]) {
    uint2 size = uint2(out.get_width(), out.get_height());
    if (gid.x >= size.x || gid.y >= size.y) return;
    float4 c = lit.read(gid);
    float3 rgb = c.rgb;
    float lw = p.lumaWhite, W = p.white;

    // Highlights and shadows: each slider's offset from its own algorithm, added up.
    float l0 = luma.read(gid).r;
    float l1 = l0 + toneOffset(l0, p, 1);
    if (p.localPaths & 1) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 ab = guided.sample(s, (float2(gid) + 0.5) / float2(size)).xy;
        float base = ab.x * l0 + ab.y;
        l1 += toneOffset(base, p, 2);
    }
    if (p.localPaths & 2) l1 += laplacian.read(gid).r - l0;
    if (p.localPaths & 4) {
        // Fine detail (sharpening, texture) never takes a pixel past its neighbours, plus a hair:
        // no overshoot, no ringing halo. Clarity works at a larger scale and is edge-stopped instead.
        float lo = l0, hi = l0;
        for (int j = -1; j <= 1; j++) {
            for (int i = -1; i <= 1; i++) {
                uint2 q = uint2(clamp(int(gid.x) + i, 0, int(size.x) - 1), clamp(int(gid.y) + j, 0, int(size.y) - 1));
                float v = luma.read(q).r;
                lo = min(lo, v); hi = max(hi, v);
            }
        }
        float hair = 0.015 * lw;
        float fine = clamp(detailFine.read(gid).r, lo - l0 - hair, hi - l0 + hair);
        l1 += fine + detailCoarse.read(gid).r;
    }
    if (l1 != l0) rgb = withLuminance(rgb, dec(l0), dec(l1));

    // Contrast: an S-curve on brightness that holds black and white in place, keeping colours.
    float k = p.contrast;
    if (k != 0.0) {
        float y = dot(rgb, lumaWeights);
        float l = enc(y / W);
        if (l > 0.0 && l < 1.0) {
            const float pivot = 0.4613, steep = 8.0;
            float lo = sigmoid(-steep * pivot), hi = sigmoid(steep * (1.0 - pivot));
            float l1;
            if (k > 0.0) {
                l1 = mix(l, (sigmoid(steep * (l - pivot)) - lo) / (hi - lo), k);
            } else {
                float u = clamp(l * (hi - lo) + lo, 1e-6, 1.0 - 1e-6);
                l1 = mix(l, pivot + log(u / (1.0 - u)) / steep, -k);
            }
            rgb = withLuminance(rgb, y, dec(clamp(l1, 0.0, 1.0)) * W);
        }
    }

    // Brightness: lightness raised in CIELAB; the colour coordinates stay where they are.
    float b = p.brightness;
    if (b != 0.0) {
        const float3x3 toXYZ = float3x3(float3(0.4124, 0.2126, 0.0193), float3(0.3576, 0.7152, 0.1192),
                                        float3(0.1805, 0.0722, 0.9505));
        const float3x3 toRGB = float3x3(float3(3.2406, -0.9689, 0.0557), float3(-1.5372, 1.8758, -0.2040),
                                        float3(-0.4986, 0.0415, 1.0570));
        const float3 white = float3(0.95047, 1.0, 1.08883);
        float3 xyz = toXYZ * (rgb / W) / white;
        float3 f = select(xyz * 7.787 + 16.0 / 116.0, pow(max(xyz, 0.0), 1.0 / 3.0), xyz > 0.008856);
        float L = 116.0 * f.y - 16.0, A = 500.0 * (f.x - f.y), B = 200.0 * (f.y - f.z);
        if (L > 0.0 && L < 100.0) {
            L = clamp(L + b * 0.8 * L * (100.0 - L) / 100.0, 0.0, 100.0);
            float fy = (L + 16.0) / 116.0;
            float3 f1 = float3(fy + A / 500.0, fy, fy - B / 200.0);
            float3 xyz1 = select((f1 - 16.0 / 116.0) / 7.787, f1 * f1 * f1, f1 > 0.206893) * white;
            rgb = toRGB * xyz1 * W;
        }
    }

    // Vibrance and saturation.
    if (p.vibrance != 0.0 || p.saturation != 0.0) {
        rgb = vibranceAndSaturation(rgb / W, p.vibrance, p.saturation) * W;
    }

    // Colour grading: each pixel takes the colours of the ranges it belongs to, by its brightness
    // (shadows (1−t)², midtones 2t(1−t), highlights t², with t pushed by the balance), in
    // proportion to its own light, and keeps its luminance.
    if (p.grade) {
        float y = dot(rgb, lumaWeights);
        if (y > 0.0) {
            float t = pow(clamp(enc(y / W), 0.0, 1.0), exp2(-p.balance));
            float3 shift = (1.0 - t) * (1.0 - t) * float3(p.gs0, p.gs1, p.gs2)
                         + 2.0 * t * (1.0 - t) * float3(p.gm0, p.gm1, p.gm2)
                         + t * t * float3(p.gh0, p.gh1, p.gh2);
            float3 graded = rgb + y * shift;
            float y1 = dot(graded, lumaWeights);
            if (y1 > 0.0) rgb = graded * (y / y1);
        }
    }

    // Out: premultiplied, in the encoding the texture asks for.
    const float3x3 toP3 = float3x3(float3(0.8225, 0.0332, 0.0171), float3(0.1774, 0.9669, 0.0724),
                                   float3(0.0000, 0.0000, 0.9108));
    const float3x3 fromP3 = float3x3(float3(1.2249, -0.0420, -0.0196), float3(-0.2247, 1.0419, -0.0786),
                                     float3(0.0, 0.0, 1.0982));
    if (p.outputEncoding == 1) {
        float3 p3 = clamp(toP3 * rgb, 0.0, 1.0);
        float3 e = enc3(p3);
        // Triangular dither, one 8-bit step wide, so smooth skies stay smooth.
        float n1 = fract(sin(dot(float2(gid), float2(12.9898, 78.233))) * 43758.5453);
        float n2 = fract(sin(dot(float2(gid), float2(39.3468, 11.135))) * 24634.6345);
        e = clamp(e + (n1 + n2 - 1.0) / 255.0, 0.0, 1.0);
        out.write(float4(e * c.a, c.a), gid);
    } else {
        if (p.clampWhite) rgb = fromP3 * clamp(toP3 * rgb, 0.0, 1.0);
        out.write(float4(rgb * c.a, c.a), gid);
    }
}
"""#
}
