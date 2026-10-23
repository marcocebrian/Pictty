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
    /// Linear white: 1 for SDR, the content headroom for HDR.
    float white;
    /// 1 when the result is shown on an SDR scale: it is clamped to white at the end.
    int clampWhite;
    /// 0: linear extended sRGB (float). 1: Display P3, sRGB curve, dithered (8-bit).
    int outputEncoding;
    /// Which local paths ran: bit 1 the Laplacian (highlights), bit 2 detail.
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
    /// The picture's middle brightness after exposure, encoded, 0…1, which brightness works around.
    float key;
    /// How much vibrance this picture's own colourfulness calls for.
    float vibranceScale;
    /// Dehaze, −1…+1, and the light of the haze (linear, 0…1 of white).
    float dehaze;
    float air0, air1, air2;
    /// Highlights lowered: where the curve pulls hardest (the picture's highlights), how hard, and
    /// how fast the pull falls away towards white.
    float hlPeak, hlStrength, hlFall;
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
inline float highlightCurve(float l, float h, float peak, float strength, float fall) {
    if (h == 0.0) return 0.0;
    // What counts as a highlight starts at half of white: from 0.4 it reached into faces and
    // midtones.
    float s = smoothstep(0.5, 1.0, l);
    // Lowered: the most at `peak` (where the picture's highlights are, 0.85 to 0.92) and none at
    // white, which stays white. Between them the curve is steep, and that is what spreads the
    // brightest things (white clouds) back out against the sky instead of greying them; `fall` is
    // how fast the pull fades towards white (as the first power, or the 0.8th for a sky that is
    // nearly blown, whose tones are all up there and need it).
    float pull = smoothstep(0.5, peak, l) * pow(clamp((1.0 - l) / (1.0 - peak), 0.0, 1.0), fall);
    float d = h < 0.0 ? h * strength * pull : h * 0.6 * s * max(1.0 - l, 0.0);
    return l > 1.0 && h > 0.0 ? 0.0 : d;
}

/// Shadows: +1 opens the dark end, −1 deepens it. Black stays black.
inline float shadowCurve(float l, float s) {
    if (s == 0.0 || l <= 0.0) return 0.0;
    float w = 1.0 - smoothstep(0.0, 0.6, l);
    return (s > 0.0 ? s * 1.6 : s * 0.6) * l * w * w;
}

/// Brightness offsets (encoded, on the picture's own scale) at level `b`: highlights, which go
/// through the local Laplacian, and shadows, a curve on each pixel.
inline float highlightOffset(float b, constant Params& p) {
    return highlightCurve(b / p.lumaWhite, p.highlights, p.hlPeak, p.hlStrength, p.hlFall) * p.lumaWhite;
}
inline float shadowOffset(float b, constant Params& p) { return shadowCurve(b / p.lumaWhite, p.shadows) * p.lumaWhite; }

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
///
/// It works by regions: `region` is the colour (Oklab a, b) of the region the pixel belongs to. How
/// muted and how skin-like the region is decides the gain; the region's colour takes all of it and
/// the pixel's own variation around it (texture, and colour noise) a quarter, so neither is
/// amplified.
inline float3 vibranceAndSaturation(float3 c, float vibrance, float saturation, float2 region) {
    float3 o = toOklab(c);
    float3 judged = float3(o.x, region);
    float chroma = length(judged.yz);
    float skin = skinLikeness(judged);
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
    float2 target = o.yz * k;
    if (k > 1.0) target = region * k + (o.yz - region) * (1.0 + 0.25 * (k - 1.0));
    if (k > 1.0 && inP3(c)) {
        // The furthest along the way that stays inside, by bisection, then a soft knee towards it.
        if (!inP3(fromOklab(float3(o.x, target)))) {
            float lo = 0.0, hi = 1.0;
            for (int i = 0; i < 10; i++) {
                float mid = 0.5 * (lo + hi);
                if (inP3(fromOklab(float3(o.x, mix(o.yz, target, mid))))) lo = mid; else hi = mid;
            }
            float knee = 0.7 * lo;
            float t = knee + (lo - knee) * (1.0 - exp(-(1.0 - knee) / max(lo - knee, 1e-4)));
            target = mix(o.yz, target, t);
        }
    } else if (k > 1.0) {
        // Already outside the screen's colours: no further.
        target = o.yz;
    }
    return fromOklab(float3(o.x, target));
}

// MARK: - Colour by regions: Oklab a and b, each through a guided filter guided by itself

/// On a quarter-size grid: the Oklab a and b of each cell's mean colour, packed for the box means
/// as (a, a², b, b²).
kernel void colourMoments(texture2d<float, access::read> lit [[texture(0)]],
                          texture2d<float, access::write> moments [[texture(1)]],
                          constant Params& p [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= moments.get_width() || gid.y >= moments.get_height()) return;
    int2 size = int2(lit.get_width(), lit.get_height());
    float3 rgb = 0.0;
    for (int j = 0; j < 4; j++) {
        for (int i = 0; i < 4; i++) {
            rgb += lit.read(uint2(min(int(gid.x) * 4 + i, size.x - 1), min(int(gid.y) * 4 + j, size.y - 1))).rgb;
        }
    }
    float2 ab = toOklab(max(rgb / 16.0, 0.0) / p.white).yz;
    moments.write(float4(ab.x, ab.x * ab.x, ab.y, ab.y * ab.y), gid);
}

/// The guided filter's linear models for a and b from their box means: (αa, βa, αb, βb).
kernel void colourCoefficients(texture2d<float, access::read> moments [[texture(0)]],
                               texture2d<float, access::write> dst [[texture(1)]],
                               constant Params& p [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float4 m = moments.read(gid);
    float va = max(m.y - m.x * m.x, 0.0), vb = max(m.w - m.z * m.z, 0.0);
    float aa = va / (va + p.eps), ab = vb / (vb + p.eps);
    dst.write(float4(aa, m.x - aa * m.x, ab, m.z - ab * m.z), gid);
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
    // Noise reduction first, before anything else is done: the denoised picture mixed in, its
    // brightness by the amount and its colour twice as fast, since colour noise is never wanted.
    if (p.hasDenoised && p.denoise > 0.0) {
        float3 change = denoised.read(gid).rgb - c.rgb;
        float y = dot(change, lumaWeights);
        c.rgb += y * p.denoise + (change - y) * min(1.0, 2.0 * p.denoise);
    }
    float3 rgb = c.a > 0.0 ? c.rgb / c.a : float3(0.0);
    // White balance first: the light the picture was taken under, adapted to the display's.
    if (p.whiteBalance) {
        rgb = float3(dot(float3(p.wb0, p.wb1, p.wb2), rgb), dot(float3(p.wb3, p.wb4, p.wb5), rgb),
                     dot(float3(p.wb6, p.wb7, p.wb8), rgb));
    }
    // Exposure lowered multiplies the light; raised, it is its own pass by regions, after this one.
    if (p.exposure < 0.0) rgb *= exp2(p.exposure);
    lit.write(float4(rgb, c.a), gid);
    luma.write(float4(enc(dot(rgb, lumaWeights))), gid);
}

// MARK: - Raised exposure

/// How lit a region already is, 0…1: none below 3 % of white, all from half of white, evenly in
/// log brightness between.
inline float litShare(float base) {
    return clamp(log(max(base, 1e-5) / 0.03) / log(0.5 / 0.03), 0.0, 1.0);
}

/// Raised exposure, half a camera's and half by regions: a dark region takes all the stops and a
/// lit one half of them (in between, by how lit it is, on an edge-aware map of the brightness), so
/// the levels stretch upwards as a camera's would while the darks open more. Each pixel's detail
/// rides on its region. With Highlights lowered, a region the exposure would push into white keeps
/// its light from the picture as it came instead (fully at −1, as the square of the slider): its
/// tones are still there for Highlights to work on, and the edge-aware map blends it into the
/// rest. What would pass white rolls off into it on a shoulder of the luminance,
/// and fades towards white as it is compressed, as film does: a bright colour held at full
/// strength up to white reads as more saturated, not as more light.
kernel void localExposure(texture2d<float, access::read> lit [[texture(0)]],
                          texture2d<float, access::read> luma [[texture(1)]],
                          texture2d<float, access::sample> guided [[texture(2)]],
                          texture2d<float, access::write> litOut [[texture(3)]],
                          texture2d<float, access::write> lumaOut [[texture(4)]],
                          constant Params& p [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    uint2 size = uint2(litOut.get_width(), litOut.get_height());
    if (gid.x >= size.x || gid.y >= size.y) return;
    float4 c = lit.read(gid);
    float l = luma.read(gid).r;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 ab = guided.sample(s, (float2(gid) + 0.5) / float2(size)).xy;
    float base = max(dec(clamp(ab.x * l + ab.y, 0.0, p.lumaWhite)) / p.white, 1e-5);
    float stops = p.exposure * (1.0 - 0.5 * litShare(base));
    if (p.highlights < 0.0 && stops > 0.0) {
        // Where the region would land past 0.6 of white (where the shoulder bites), it is
        // compressed into the rest of the way to white instead, and never below where it was. Both
        // rise with the region, so a brighter region always stays brighter: scaling the stops by
        // how far a region was pushed turned a slightly brighter one darker than its neighbour.
        float landed = base * exp2(stops);
        float knee = landed < 0.6 ? landed : 0.6 + 0.4 * (1.0 - exp(-0.5 * (landed - 0.6) / 0.4));
        float kept = mix(landed, max(base, knee), p.highlights * p.highlights);
        stops = log2(max(kept, base) / base);
    }
    float gain = exp2(stops);
    float3 rgb = c.rgb * gain;
    float y = dot(rgb, lumaWeights) / p.white;
    if (y > 0.0) {
        float y1 = rolloff(y, gain);
        rgb *= y1 / y;
        float3 grey = float3(y1 * p.white);
        rgb = mix(rgb, grey, clamp(1.0 - y1 / y, 0.0, 1.0));
        // Still past white in a channel (a saturated colour near white): towards grey, keeping the
        // luminance, until it fits.
        float m = max(rgb.r, max(rgb.g, rgb.b));
        if (m > p.white) rgb = mix(grey, rgb, (p.white - grey.r) / max(m - grey.r, 1e-6));
    }
    litOut.write(float4(rgb, c.a), gid);
    lumaOut.write(float4(enc(dot(rgb, lumaWeights))), gid);
}

// MARK: - Tone curves

/// Contrast's S-curve on brightness `l` (encoded, 0…1) around `pivot`: a sigmoid that holds 0 and 1
/// in place, mixed in by `k` > 0; below 0, its inverse flattens instead.
inline float contrastCurve(float l, float k, float pivot) {
    const float steep = 8.0;
    float lo = sigmoid(-steep * pivot), hi = sigmoid(steep * (1.0 - pivot));
    if (k > 0.0) return mix(l, (sigmoid(steep * (l - pivot)) - lo) / (hi - lo), k);
    float u = clamp(l * (hi - lo) + lo, 1e-6, 1.0 - 1e-6);
    return mix(l, pivot + log(u / (1.0 - u)) / steep, -k);
}

/// Brightness by regions on `l` (encoded, 0…1): a lift that is greatest at the picture's own
/// middle brightness `key` and nothing at black and white, gentle enough never to reverse order.
inline float brightnessCurve(float l, float b, float key) {
    float e = log(0.5) / log(clamp(key, 0.05, 0.95));
    float m = pow(clamp(l, 0.0, 1.0), e);
    // Raising a midtone lift to the power that puts the key at 0.5, and back.
    float m1 = clamp(m + b * 0.44 * m * (1.0 - m), 0.0, 1.0);
    return pow(m1, 1.0 / e);
}

/// Raises the light by regions: each pixel takes the gain its region (the guided filter's smooth,
/// edge-aware base) is given, so the detail within a region rides along unchanged. A region darker
/// than 3 % of white takes all the stops; from there to half of white, they fade out evenly in
/// log brightness, so what is already lit (a face under a lamp) keeps its light and white stays
/// white. The fade is gentle enough that a brighter region always stays brighter, up to +4 stops.
/// A raised pixel near white rolls off into it on a shoulder, keeping its colour.
// MARK: - Dehaze: the veil the dark channel shows (after He, Sun and Tang 2009), refined by a guided filter
//
// Haze lifts every dark in a region towards the haze's light. The lift is read from the dark
// channel, as a region's mean rather than its darkest point: in a city or a forest a shadow is
// always near, and the darkest point says there is no haze where the eye plainly sees a veil.
// Smooth, untextured regions (the sky, a bank of fog, a wall) carry nothing to reveal: taking
// "haze" out of them only darkens the sky and stretches its gradient into bands, so they are
// left alone.

/// Per quarter-size cell: the darkest channel of its pixels, each channel over the haze's own
/// (r), and the cell's mean encoded brightness, the guide (g).
kernel void hazeDark(texture2d<float, access::read> lit [[texture(0)]],
                     texture2d<float, access::read> luma [[texture(1)]],
                     texture2d<float, access::write> dst [[texture(2)]],
                     constant Params& p [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    int2 size = int2(lit.get_width(), lit.get_height());
    float3 air = float3(p.air0, p.air1, p.air2) * p.white;
    float dark = 1e9, I = 0.0;
    for (int j = 0; j < 4; j++) {
        for (int i = 0; i < 4; i++) {
            uint2 q = uint2(min(int(gid.x) * 4 + i, size.x - 1), min(int(gid.y) * 4 + j, size.y - 1));
            float3 c = max(lit.read(q).rgb, 0.0) / air;
            dark = min(dark, min(c.r, min(c.g, c.b)));
            I += luma.read(q).r;
        }
    }
    dst.write(float4(clamp(dark, 0.0, 1.0), I / 16.0, 0.0, 0.0), gid);
}

/// Packs (I, I², D, 0) for the local texture: the guide I and the dark channel D.
kernel void hazeLocal(texture2d<float, access::read> src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float2 v = src.read(gid).rg;
    dst.write(float4(v.g, v.g * v.g, v.r, 0.0), gid);
}

/// The veil to take out: the dark channel, but none where the region is smooth (its brightness
/// varies by less than about 1 % of white around it; haze itself flattens texture, so the line is
/// drawn low) and none where it is as bright as the haze's light or nearly: a scene under haze is
/// always darker than the haze, a sky and its clouds are not (in the test pictures a city, however
/// far, sits below 0.35 of the haze's luminance and skies above 0.5).
kernel void hazeMask(texture2d<float, access::read> src [[texture(0)]],
                     texture2d<float, access::read> local [[texture(1)]],
                     texture2d<float, access::write> dst [[texture(2)]],
                     constant Params& p [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float2 v = src.read(gid).rg;
    float4 m = local.read(gid);
    float sd = sqrt(max(m.y - m.x * m.x, 0.0));
    float hazeLight = dot(float3(p.air0, p.air1, p.air2), lumaWeights) * p.white;
    float sky = smoothstep(0.4, 0.6, dec(m.x) / max(hazeLight, 1e-4));
    dst.write(float4(v.r * smoothstep(0.004, 0.015, sd) * (1.0 - sky), v.g, m.x, 0.0), gid);
}

/// Packs (I, I², D, I·D) for the box means: the guide I and the veil D.
kernel void hazeMoments(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float2 v = src.read(gid).rg;
    float D = v.r, I = v.g;
    dst.write(float4(I, I * I, D, I * D), gid);
}

/// The guided filter's model of the dark channel from the brightness, D = a·I + b.
kernel void hazeCoefficients(texture2d<float, access::read> moments [[texture(0)]],
                             texture2d<float, access::write> dst [[texture(1)]],
                             constant Params& p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float4 m = moments.read(gid);
    float variance = max(m.y - m.x * m.x, 0.0);
    float a = (m.w - m.x * m.z) / (variance + p.eps);
    dst.write(float4(a, m.z - a * m.x, 0.0, 0.0), gid);
}

/// Takes the haze out: the scene's light J = (I − A)/t + A, with the transmission t = 1 − ω·D
/// (ω up to 0.9, so a little haze always stays and distance still reads) and never below 0.4:
/// contrast at most 2.5 times, which keeps far, hazy noise and an 8-bit gradient from being blown
/// up. What would fall below black rolls off into it instead of clipping. The model alone is too
/// much of two things: it raises colour as much as contrast, and it sinks a whole region towards
/// black as it pivots on the haze's light. The luminance takes the haze out fully, the colour
/// half; and half of each region's darkening, in stops, is given back. Lowered, haze is added:
/// the picture fades towards the haze's light, more where it is already hazier.
kernel void dehaze(texture2d<float, access::read> lit [[texture(0)]],
                   texture2d<float, access::read> luma [[texture(1)]],
                   texture2d<float, access::sample> model [[texture(2)]],
                   texture2d<float, access::write> litOut [[texture(3)]],
                   texture2d<float, access::write> lumaOut [[texture(4)]],
                   texture2d<float, access::sample> regions [[texture(5)]],
                   constant Params& p [[buffer(0)]],
                   uint2 gid [[thread_position_in_grid]]) {
    uint2 size = uint2(litOut.get_width(), litOut.get_height());
    if (gid.x >= size.x || gid.y >= size.y) return;
    float4 c = lit.read(gid);
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 ab = model.sample(s, (float2(gid) + 0.5) / float2(size)).xy;
    float D = clamp(ab.x * luma.read(gid).r + ab.y, 0.0, 1.0);
    float3 air = float3(p.air0, p.air1, p.air2) * p.white;
    float3 rgb = c.rgb;
    if (p.dehaze > 0.0) {
        float t = max(1.0 - 0.9 * p.dehaze * D, 0.4);
        float3 J = (rgb - air) / t + air;
        const float toe = 0.02 * p.white;
        J = select(J, toe * exp((J - toe) / toe), J < toe);
        float y0 = dot(rgb, lumaWeights), y1 = dot(J, lumaWeights);
        J = mix(rgb * (y1 / max(y0, 1e-6)), J, 0.5);
        // The region's mean luminance, and where the model takes it.
        float before = dec(regions.sample(s, (float2(gid) + 0.5) / float2(size)).b);
        float after = (before - dot(air, lumaWeights) * (1.0 - t)) / t;
        rgb = J * sqrt(clamp(before / max(after, 1e-6), 1.0, 4.0));
    } else {
        float h = -p.dehaze * 0.7 * (0.3 + 0.7 * D);
        rgb = mix(rgb, air, h);
    }
    litOut.write(float4(rgb, c.a), gid);
    lumaOut.write(float4(enc(dot(rgb, lumaWeights))), gid);
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
/// riding on the curve's value at γ; far from it (an edge) it follows the curve itself, which is
/// what stops halos.
kernel void remap(texture2d<float, access::read> luma [[texture(0)]],
                  texture2d<float, access::write> dst [[texture(1)]],
                  constant Params& p [[buffer(0)]],
                  uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float i = luma.read(gid).r;
    float g = p.gamma;
    float tg = g + highlightOffset(g, p);
    float ti = i + highlightOffset(i, p);
    // Grain, up to about three times the picture's noise, is compressed as the curve is there and
    // as much as the level itself was lowered, so a pulled-down highlight does not show its noise
    // more than before for its brightness. Only ever compressed.
    float d = i - g, h = 0.01 * p.lumaWhite;
    float slope = 1.0 + (highlightOffset(g + h, p) - highlightOffset(g - h, p)) / (2.0 * h);
    float lowered = g > h ? tg / g : 1.0;
    float n = p.noise * p.lumaWhite;
    // Larger detail is kept whole where the curve is flatter than 1 (the lower highlights keep their
    // contrast) and follows the curve where it is steeper, near white: a cloud's top goes back up
    // to white with it instead of staying where its region was pulled to, and a smooth gradient
    // there lands on the curve between the samples instead of in steps. Grain a little larger than
    // the measured noise is not stretched with it (up to 6 times the noise, fully from 10).
    float secant = fabs(d) > 1e-4 ? (ti - tg) / d : slope;
    float detail = 1.0 + max(secant - 1.0, 0.0) * smoothstep(6.0 * n, 10.0 * n + 1e-4, fabs(d));
    float keep = mix(clamp(min(slope, lowered), 0.25, 1.0), detail, smoothstep(3.0 * n, 6.0 * n + 1e-4, fabs(d)));
    float near = tg + d * keep;
    float far = smoothstep(p.sigma, 2.0 * p.sigma, fabs(d));
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

// MARK: - Highlights: the change, on the local Laplacian's reduced copy

/// The change the local Laplacian made, with the detail of bright regions drawn out against their
/// edge-aware mean (`regions`, the guided filter's model), packed with the brightness as (change,
/// brightness) for the guided upsampling.
kernel void highlightChange(texture2d<float, access::read> luma [[texture(0)]],
                            texture2d<float, access::read> rebuilt [[texture(1)]],
                            texture2d<float, access::sample> regions [[texture(2)]],
                            texture2d<float, access::write> dst [[texture(3)]],
                            constant Params& p [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    uint2 size = uint2(dst.get_width(), dst.get_height());
    if (gid.x >= size.x || gid.y >= size.y) return;
    float l0 = luma.read(gid).r, l1 = rebuilt.read(gid).r, lw = p.lumaWhite;
    if (p.highlights < 0.0) {
        // Highlights pulled down show what is in them: the detail of a bright region (clouds in a
        // pale sky, and the faint texture inside a white cloud), measured against its edge-aware
        // mean, drawn out up to 2.1 times at −1. Not the noise or a single 8-bit step of a smooth
        // sky (0.4 % of white), which would show as grain and contour lines, nor a strong edge (a
        // building against the sky), which would halo. It recovers: nothing comes out brighter than
        // it went in.
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 ab = regions.sample(s, (float2(gid) + 0.5) / float2(size)).xy;
        float b0 = clamp(ab.x * l0 + ab.y, 0.0, lw);
        float dd = (l0 - b0) / lw, n = p.noise;
        float w = smoothstep(0.55, 0.85, b0 / lw) * smoothstep(max(4.0 * n, 0.003), max(8.0 * n, 0.01), fabs(dd))
                * (1.0 - smoothstep(0.1, 0.25, fabs(dd)));
        float revealed = l1 + 1.1 * -p.highlights * w * dd * lw;
        l1 = dd > 0.0 ? min(revealed, max(l1, l0)) : revealed;
    }
    dst.write(float4(l1 - l0, l0, 0.0, 0.0), gid);
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
                   texture2d<float, access::sample> laplacian [[texture(2)]],
                   texture2d<float, access::write> out [[texture(3)]],
                   texture2d<float, access::read> detailFine [[texture(4)]],
                   texture2d<float, access::read> detailCoarse [[texture(5)]],
                   texture2d<float, access::sample> regions [[texture(6)]],
                   texture2d<float, access::sample> colourRegions [[texture(7)]],
                   texture2d<float, access::sample> smoothLuma [[texture(8)]],
                   constant Params& p [[buffer(0)]],
                   uint2 gid [[thread_position_in_grid]]) {
    uint2 size = uint2(out.get_width(), out.get_height());
    if (gid.x >= size.x || gid.y >= size.y) return;
    float4 c = lit.read(gid);
    float3 rgb = c.rgb;
    float lw = p.lumaWhite, W = p.white;

    // Shadows, a curve on each pixel; highlights, the local Laplacian's.
    float l0 = luma.read(gid).r;
    float l1 = l0 + shadowOffset(l0, p);
    // Highlights: the change the local Laplacian made on its reduced copy, as a local linear model
    // of the brightness, evaluated here at full size.
    float highlightChange = 0.0;
    if (p.localPaths & 2) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 ab = laplacian.sample(s, (float2(gid) + 0.5) / float2(size)).xy;
        // Where the model stretches (near white, where the curve is steep), taken on the pixel's own
        // brightness it would stretch the original's 8-bit steps and its compression's blocks into
        // bands. There it is taken on the brightness with those evened out: the pixel moved towards a
        // blur of a few pixels around it, by no more than 0.8 % of white (two 8-bit levels), so real
        // edges and texture, larger than that, stay where they are and the original's finest steps
        // pass at their own size. Where it compresses, the grain comes down with its region.
        float around = smoothLuma.sample(s, (float2(gid) + 0.5) / float2(size)).r;
        float even = l0 + clamp(around - l0, -0.008 * p.lumaWhite, 0.008 * p.lumaWhite);
        highlightChange = ab.x * (ab.x > 0.0 ? even : l0) + ab.y;
        l1 += highlightChange;
    }
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
    if ((p.localPaths & 2) && p.highlights < 0.0 && l0 > 0.0) {
        // A highlight brought down keeps its colour, as a sky does under a darker light: its
        // chroma rises a little with how much it was darkened, so the sky does not go grey. Only
        // what has a colour: a white cloud, nearly neutral, would only take on the sky's tint and
        // look less white. Never skin: a lit face would turn orange. At most a fifth more.
        float darkened = dec(l0) / max(dec(l0 + highlightChange), 1e-6);
        if (darkened > 1.0) {
            float3 o = toOklab(max(rgb, 0.0) / W);
            float coloured = smoothstep(0.005, 0.03, length(o.yz) / max(o.x, 1e-3));
            float s = min(0.4 * (darkened - 1.0), 0.2) * coloured * (1.0 - skinLikeness(o));
            rgb = vibranceAndSaturation(max(rgb, 0.0) / W, 0.0, s, o.yz) * W;
        }
    }

    // Contrast: an S-curve on each pixel's brightness around mid-grey, holding black and white in
    // place, keeping colours.
    float k = p.contrast;
    if (k != 0.0) {
        float y = dot(rgb, lumaWeights);
        float l = enc(y / W);
        if (l > 0.0 && l < 1.0) rgb = withLuminance(rgb, y, dec(clamp(contrastCurve(l, k, 0.4613), 0.0, 1.0)) * W);
    }

    // Brightness by regions: the curve moves the region's brightness (the guided filter's base,
    // where the tone sliders and contrast have taken it), and the pixel follows as a ratio, so its
    // texture keeps its own contrast. A raised pixel near white rolls off into it.
    if (p.brightness != 0.0) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 ab = regions.sample(s, (float2(gid) + 0.5) / float2(size)).xy;
        float b0 = clamp(ab.x * l0 + ab.y, 0.0, lw);
        float b = clamp(b0 + shadowOffset(b0, p) + highlightOffset(b0, p), 0.0, lw) / lw;
        if (k != 0.0 && b > 0.0 && b < 1.0) b = clamp(contrastCurve(b, k, 0.4613), 0.0, 1.0);
        float b1 = brightnessCurve(b, p.brightness, p.key);
        float gain = dec(b1 * lw) / max(dec(b * lw), 1e-6);
        rgb *= gain;
        float m = max(rgb.r, max(rgb.g, rgb.b));
        if (gain > 1.0 && m > 0.0) rgb *= W * rolloff(m / W, gain) / m;
    }

    // Vibrance and saturation, by regions. The region's colour was measured on the picture as it
    // came in; Oklab's a and b scale with lightness, so it follows the pixel's lightness since.
    if (p.vibrance != 0.0 || p.saturation != 0.0) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        float4 m = colourRegions.sample(s, (float2(gid) + 0.5) / float2(size));
        float3 was = toOklab(max(c.rgb, 0.0) / W);
        float now = toOklab(max(rgb, 0.0) / W).x;
        float2 region = float2(m.x * was.y + m.y, m.z * was.z + m.w) * (was.x > 1e-4 ? now / was.x : 1.0);
        rgb = vibranceAndSaturation(rgb / W, p.vibrance * p.vibranceScale, p.saturation, region) * W;
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
