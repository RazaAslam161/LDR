package com.miles.miles.beauty

/**
 * Every shader in the pipeline, as ESSL 1.00.
 *
 * 1.00 on purpose: `samplerExternalOES` from ESSL 3.00 needs `GL_OES_EGL_image_external_essl3`,
 * which is common but not universal; 1.00 needs only `GL_OES_EGL_image_external`, which is. An
 * ES 3.0 context compiles 1.00 fine, so the pipeline asks for ES 3 (for its uniform budget) and
 * falls back to ES 2 with the same sources.
 *
 * All face maths runs in the aspect-corrected texture space described on [FaceGeometry].
 * `vTexCoord` arrives in plain texture space; `pa` is its aspect-corrected twin; the warped
 * sample coordinate `qa` is divided back out at the end.
 */
internal object BeautyShaders {

    const val VERTEX = """
attribute vec4 aPosition;
attribute vec4 aTexCoord;
uniform mat4 uTexMatrix;
varying vec2 vTexCoord;
void main() {
    gl_Position = aPosition;
    vTexCoord = (uTexMatrix * aTexCoord).xy;
}
"""

    /** OES sampler pass-through: the untouched original path, and the resolve into texA. */
    const val OES = """
#extension GL_OES_EGL_image_external : require
precision mediump float;
varying vec2 vTexCoord;
uniform samplerExternalOES uTexture;
void main() {
    gl_FragColor = texture2D(uTexture, vTexCoord);
}
"""

    const val COPY = """
precision mediump float;
varying vec2 vTexCoord;
uniform sampler2D uTexture;
void main() {
    gl_FragColor = texture2D(uTexture, vTexCoord);
}
"""

    /** Separable 9-tap Gaussian using five bilinear fetches. Weights sum to 1. */
    const val BLUR = """
precision mediump float;
varying vec2 vTexCoord;
uniform sampler2D uTexture;
uniform vec2 uStep;
void main() {
    vec3 c = texture2D(uTexture, vTexCoord).rgb * 0.2270270270;
    c += texture2D(uTexture, vTexCoord + uStep * 1.3846153846).rgb * 0.3162162162;
    c += texture2D(uTexture, vTexCoord - uStep * 1.3846153846).rgb * 0.3162162162;
    c += texture2D(uTexture, vTexCoord + uStep * 3.2307692308).rgb * 0.0702702703;
    c += texture2D(uTexture, vTexCoord - uStep * 3.2307692308).rgb * 0.0702702703;
    gl_FragColor = vec4(c, 1.0);
}
"""

    private const val SDF = """
float sdPoly20(vec2 v[20], vec2 p) {
    float d = dot(p - v[0], p - v[0]);
    float s = 1.0;
    for (int i = 0; i < 20; i++) {
        int j = (i == 0) ? 19 : i - 1;
        vec2 e = v[j] - v[i];
        vec2 w = p - v[i];
        vec2 b = w - e * clamp(dot(w, e) / dot(e, e), 0.0, 1.0);
        d = min(d, dot(b, b));
        bvec3 c = bvec3(p.y >= v[i].y, p.y < v[j].y, e.x * w.y > e.y * w.x);
        if (all(c) || all(not(c))) s = -s;
    }
    return s * sqrt(d);
}
float sdPoly10(vec2 v[10], vec2 p) {
    float d = dot(p - v[0], p - v[0]);
    float s = 1.0;
    for (int i = 0; i < 10; i++) {
        int j = (i == 0) ? 9 : i - 1;
        vec2 e = v[j] - v[i];
        vec2 w = p - v[i];
        vec2 b = w - e * clamp(dot(w, e) / dot(e, e), 0.0, 1.0);
        d = min(d, dot(b, b));
        bvec3 c = bvec3(p.y >= v[i].y, p.y < v[j].y, e.x * w.y > e.y * w.x);
        if (all(c) || all(not(c))) s = -s;
    }
    return s * sqrt(d);
}
"""

    /**
     * Local statistics for a SELF-GUIDED FILTER (He, Sun & Tang) — the edge-preserving
     * smoother that replaced the Gaussian this pipeline used to smooth skin with.
     *
     * WHY NOT A GAUSSIAN. Frequency separation on a Gaussian low-pass blurs ACROSS the nose
     * edge, the lip border and the jaw silhouette, so the "low" layer is contaminated by
     * whatever is on the other side of the edge and the "high" layer carries ringing. Turned
     * up, that is exactly the waxy, haloed, plastic look — the basic tier.
     *
     * A guided filter is a per-pixel linear model of the image on itself:
     *
     *     q = a * Y + b,    a = var / (var + eps),    b = mean * (1 - a)
     *
     * where mean and var are local. Flat skin has var << eps, so a -> 0 and q -> mean: fully
     * smoothed. A real edge has var >> eps, so a -> 1 and q -> Y: untouched. `eps` IS the
     * "skin or edge" decision, and unlike a bilateral filter this produces no gradient
     * reversal — the reason it, not bilateral, is what production retouch pipelines use.
     *
     * PRECISION IS LOAD-BEARING. var = E[Y²] - E[Y]² is a catastrophic cancellation: skin
     * variance is ~1e-4 against means of ~0.25. In mediump (fp16, 10-bit mantissa) the
     * subtraction is destroyed, and storing the two moments in an 8-bit texture destroys it
     * again. So the moments never leave this shader: they are accumulated and differenced in
     * highp REGISTERS, and only (a, b) — both well-conditioned in 0..1 — are written out.
     * That is also why there is no half-float render target here and no extension to depend on.
     *
     * 3x3 taps at 2-texel spacing covers 5x5 half-res pixels; the two box passes that smooth
     * (a, b) afterwards widen the effective support to roughly a blemish.
     */
    const val GUIDED = """
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif
varying vec2 vTexCoord;
uniform sampler2D uTexture;
uniform vec2 uTexel;
uniform float uEps;
const vec3 LUMA = vec3(0.299, 0.587, 0.114);
void main() {
    float s = 0.0;
    float s2 = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 o = vec2(float(x), float(y)) * uTexel * 2.0;
            float Y = dot(texture2D(uTexture, vTexCoord + o).rgb, LUMA);
            s += Y;
            s2 += Y * Y;
        }
    }
    float mean = s / 9.0;
    float vari = max(s2 / 9.0 - mean * mean, 0.0);
    float a = vari / (vari + uEps);
    gl_FragColor = vec4(a, mean * (1.0 - a), 0.0, 1.0);
}
"""

    /**
     * Skin likelihood × face geometry, at half resolution, from the BLURRED half so sensor noise
     * does not speckle the mask. Output in .r.
     *
     * Skin is the classic YCbCr box, softened. With a face the mask is confined to an ellipse on
     * the oval, minus the eyes and lips; without one it degrades to colour-only at half strength,
     * so a lost track dims the effect instead of switching it off.
     */
    const val MASK = """
precision mediump float;
varying vec2 vTexCoord;
uniform sampler2D uTexture;
uniform float uAspect;
uniform float uFaceAlpha;
uniform float uFaceW;
uniform vec4 uEllipse;
uniform float uRoll;
uniform vec4 uEyes[2];
uniform vec2 uLips[20];
const vec3 LUMA = vec3(0.299, 0.587, 0.114);
$SDF
void main() {
    vec3 c = texture2D(uTexture, vTexCoord).rgb;
    float y = dot(c, LUMA);
    float cb = 0.5 + (c.b - y) * 0.564;
    float cr = 0.5 + (c.r - y) * 0.713;
    float mb = smoothstep(0.27, 0.32, cb) * (1.0 - smoothstep(0.49, 0.54, cb));
    float mr = smoothstep(0.50, 0.545, cr) * (1.0 - smoothstep(0.66, 0.71, cr));
    float ly = smoothstep(0.06, 0.18, y) * (1.0 - smoothstep(0.93, 0.99, y));
    float skin = mb * mr * ly;
    float geo = 0.82;
    if (uFaceAlpha > 0.001) {
        vec2 pa = vec2(vTexCoord.x * uAspect, vTexCoord.y);
        vec2 d = pa - uEllipse.xy;
        float cs = cos(uRoll);
        float sn = sin(uRoll);
        vec2 r = vec2(d.x * cs + d.y * sn, -d.x * sn + d.y * cs);
        vec2 n = vec2(r.x / uEllipse.z, r.y / uEllipse.w);
        float ell = 1.0 - smoothstep(0.85, 1.2, length(n));
        float excl = 1.0;
        for (int i = 0; i < 2; i++) {
            vec2 ed = pa - uEyes[i].xy;
            vec2 er = vec2(ed.x * cs + ed.y * sn, -ed.x * sn + ed.y * cs);
            vec2 en = vec2(er.x / uEyes[i].z, er.y / uEyes[i].w);
            excl *= smoothstep(0.8, 1.3, length(en));
        }
        float e = 0.02 * uFaceW;
        excl *= smoothstep(-e, e * 2.0, sdPoly20(uLips, pa));
        geo = mix(0.82, ell * excl, uFaceAlpha);
    }
    gl_FragColor = vec4(vec3(skin * geo), 1.0);
}
"""

    /**
     * The composite: reshape warp on the sample coordinate, then frequency-separated smoothing,
     * tone, brighten, then procedural makeup. `MILES_FULL` gates everything that needs landmark
     * arrays; without it the same source compiles to a retouch-only shader for GPUs whose
     * fragment-uniform budget cannot hold the polygons.
     */
    const val COMPOSITE = """
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif
varying vec2 vTexCoord;
uniform sampler2D uTexture;
uniform sampler2D uBlur;
uniform sampler2D uMask;
uniform sampler2D uGuide;
uniform sampler2D uGuideCoarse;
uniform float uAspect;
uniform float uPoreT;
uniform float uBlemishT;
uniform float uEvenness;
uniform float uSmooth;
uniform float uTone;
uniform float uBrighten;
uniform float uDetail;
uniform float uFaceAlpha;
uniform float uColorOn;
uniform vec3 uColorR;
uniform vec3 uColorG;
uniform vec3 uColorB;
uniform vec3 uColorV;
uniform vec4 uOverlay;
uniform float uOverlayScreen;
#ifdef MILES_FULL
uniform float uFaceW;
uniform vec2 uFaceCenter;
uniform vec2 uUp;
uniform vec4 uCtl[5];
uniform float uCtlR[5];
uniform vec4 uEyeCtl[2];
uniform vec2 uLips[20];
uniform vec2 uLipsIn[20];
uniform vec2 uBrowL[10];
uniform vec2 uBrowR[10];
uniform vec4 uCheek[2];
uniform vec4 uEyeBox[2];
uniform vec3 uLipColor;
uniform float uLipsAmount;
uniform vec3 uBlushColor;
uniform float uBlushAmount;
uniform vec3 uBrowColor;
uniform float uBrowsAmount;
uniform vec3 uShadowColor;
uniform float uShadowAmount;
$SDF
float gauss(float d2, float r) {
    return exp(-d2 / (2.0 * r * r));
}
#endif
const vec3 LUMA = vec3(0.299, 0.587, 0.114);
void main() {
    vec2 pa = vec2(vTexCoord.x * uAspect, vTexCoord.y);
    vec2 qa = pa;
    float fa = uFaceAlpha;
    bool nearFace = false;
#ifdef MILES_FULL
    if (fa > 0.001) {
        vec2 fd = pa - uFaceCenter;
        float reach = 1.6 * uFaceW;
        nearFace = dot(fd, fd) < reach * reach;
    }
    if (nearFace) {
        vec2 disp = vec2(0.0);
        for (int i = 0; i < 5; i++) {
            vec2 d = pa - uCtl[i].xy;
            disp += gauss(dot(d, d), uCtlR[i]) * uCtl[i].zw;
        }
        qa = pa - disp * fa;
        for (int i = 0; i < 2; i++) {
            vec2 d = qa - uEyeCtl[i].xy;
            float w = gauss(dot(d, d), uEyeCtl[i].z);
            qa = uEyeCtl[i].xy + d * (1.0 - uEyeCtl[i].w * w * fa);
        }
    }
#endif
    vec2 q = vec2(qa.x / uAspect, qa.y);
    vec3 src = texture2D(uTexture, q).rgb;
    vec3 blr = texture2D(uBlur, q).rgb;
    float m = texture2D(uMask, q).r;

    // Edge-preserving smoothing. (a, b) is the guided filter's linear model, already box
    // smoothed; gY is the skin with blemishes flattened and real edges intact.
    vec2 ab = texture2D(uGuide, q).rg;
    vec2 abC = texture2D(uGuideCoarse, q).rg;
    float Y = dot(src, LUMA);
    float gY = ab.x * Y + ab.y;
    float gC = abC.x * Y + abC.y;

    // What the filter removed, put back SELECTIVELY. A flat fraction of the detail layer —
    // what this used to do — restores the blemish it just erased and still flattens pores,
    // which is wrong at both ends. Small deviations are pore and hair texture and are kept;
    // large ones are the blemish and stay gone. This is the difference between skin and
    // airbrush.
    // THREE BANDS, not two. gC is the face with blotches gone; gY keeps blemish-scale
    // structure; Y is everything including pores.
    //   mid  = gY - gC : uneven tone and blotches. Mostly discarded — this is the band a
    //                    single-scale filter had no way to separate, and the reason skin
    //                    still read as uneven however hard it was smoothed.
    //   fine = Y  - gY : pores, fine hair, the grain that makes skin look like skin. Kept
    //                    when small, dropped when large (a large deviation here is a spot).
    float mid = gY - gC;
    float fine = Y - gY;
    float keep = 1.0 - smoothstep(uPoreT, uBlemishT, abs(fine));
    float yOut = gC + mid * uEvenness + fine * keep * uDetail;

    // Luminance-only, so chroma is bit-exact and no colour shifts on the cheek.
    vec3 sm = src + vec3(yOut - Y);
    vec3 c = mix(src, sm, uSmooth * m);

    // Chroma evening, held back at edges. It used to blend toward a Gaussian, which is
    // edge-blind, so redness smoothing bled across the lip and nose borders and left a
    // colour halo. `ab.x` is the guided model's own "this is an edge" term: 1 at an edge,
    // 0 on flat skin, so (1 - ab.x) stops the blend exactly where it used to smear.
    float ya = dot(c, LUMA);
    float yb = dot(blr, LUMA);
    c = vec3(ya) + mix(c - vec3(ya), blr - vec3(yb), uTone * m * 0.9 * (1.0 - ab.x));
    c += vec3(uBrighten * m * 0.22);
#ifdef MILES_FULL
    if (nearFace) {
        float lum = dot(c, LUMA);
        float e = 0.012 * uFaceW;
        vec2 side = vec2(-uUp.y, uUp.x);
        if (uLipsAmount > 0.001) {
            float dO = sdPoly20(uLips, qa);
            float dI = sdPoly20(uLipsIn, qa);
            float aL = (1.0 - smoothstep(-e, e, dO)) * smoothstep(-e, e, dI);
            c = mix(c, uLipColor * (lum * 1.5 + 0.1), aL * uLipsAmount * fa);
        }
        if (uBlushAmount > 0.001) {
            for (int i = 0; i < 2; i++) {
                vec2 d = qa - uCheek[i].xy;
                float x = dot(d, side);
                float y = dot(d, uUp);
                float g = exp(-(x * x) / (2.0 * uCheek[i].z * uCheek[i].z)
                              -(y * y) / (2.0 * uCheek[i].w * uCheek[i].w));
                c = mix(c, uBlushColor * (lum * 1.4 + 0.1), g * uBlushAmount * 0.8 * fa);
            }
        }
        if (uBrowsAmount > 0.001) {
            float dB = min(sdPoly10(uBrowL, qa), sdPoly10(uBrowR, qa));
            float aB = 1.0 - smoothstep(-e, e * 1.5, dB);
            c = mix(c, uBrowColor * (lum * 1.2 + 0.05), aB * uBrowsAmount * 0.9 * fa);
        }
        if (uShadowAmount > 0.001) {
            for (int i = 0; i < 2; i++) {
                vec2 d = qa - uEyeBox[i].xy;
                float ew = uEyeBox[i].z / 0.75;
                float x = dot(d, side);
                float y = dot(d, uUp);
                float sx = 0.75 * ew;
                float sy = 0.35 * ew;
                float g = exp(-(x * x) / (2.0 * sx * sx)) *
                          exp(-((y - 0.45 * ew) * (y - 0.45 * ew)) / (2.0 * sy * sy));
                g *= smoothstep(0.0, 0.25 * ew, y + 0.05 * ew);
                c = mix(c, uShadowColor * (lum * 1.3 + 0.08), g * uShadowAmount * 0.85 * fa);
            }
        }
    }
#endif
    // The camera's colour preset, last, so it grades the retouched face exactly as it grades
    // the background — one grade for the preview, the still and the recording alike.
    if (uColorOn > 0.5) {
        c = clamp(vec3(dot(uColorR, c), dot(uColorG, c), dot(uColorB, c)) + uColorV, 0.0, 1.0);
        if (uOverlay.a > 0.001) {
            vec3 o = uOverlay.rgb;
            vec3 screened = vec3(1.0) - (vec3(1.0) - c) * (vec3(1.0) - o);
            c = mix(c, mix(o, screened, uOverlayScreen), uOverlay.a);
        }
    }
    gl_FragColor = vec4(c, 1.0);
}
"""

    const val FULL_DEFINE = "#define MILES_FULL 1\n"
}
