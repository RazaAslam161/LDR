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
    float geo = 0.5;
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
            vec2 en = vec2(ed.x / uEyes[i].z, ed.y / uEyes[i].w);
            excl *= smoothstep(0.8, 1.3, length(en));
        }
        float e = 0.02 * uFaceW;
        excl *= smoothstep(-e, e * 2.0, sdPoly20(uLips, pa));
        geo = mix(0.5, ell * excl, uFaceAlpha);
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
uniform float uAspect;
uniform float uSmooth;
uniform float uTone;
uniform float uBrighten;
uniform float uDetail;
uniform float uFaceAlpha;
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
    vec3 a = texture2D(uTexture, q).rgb;
    vec3 b = texture2D(uBlur, q).rgb;
    float m = texture2D(uMask, q).r;
    vec3 hi = a - b;
    vec3 sm = b + hi * (0.35 * uDetail);
    vec3 c = mix(a, sm, uSmooth * m);
    float ya = dot(c, LUMA);
    float yb = dot(b, LUMA);
    c = vec3(ya) + mix(c - vec3(ya), b - vec3(yb), uTone * m * 0.8);
    c += vec3(uBrighten * m * 0.10);
#ifdef MILES_FULL
    if (nearFace) {
        float lum = dot(c, LUMA);
        float e = 0.012 * uFaceW;
        vec2 side = vec2(-uUp.y, uUp.x);
        if (uLipsAmount > 0.001) {
            float dO = sdPoly20(uLips, qa);
            float dI = sdPoly20(uLipsIn, qa);
            float aL = (1.0 - smoothstep(-e, e, dO)) * smoothstep(-e, e, dI);
            c = mix(c, uLipColor * (lum * 1.5 + 0.1), aL * uLipsAmount * 0.85 * fa);
        }
        if (uBlushAmount > 0.001) {
            for (int i = 0; i < 2; i++) {
                vec2 d = qa - uCheek[i].xy;
                float x = dot(d, side);
                float y = dot(d, uUp);
                float g = exp(-(x * x) / (2.0 * uCheek[i].z * uCheek[i].z)
                              -(y * y) / (2.0 * uCheek[i].w * uCheek[i].w));
                c = mix(c, uBlushColor * (lum * 1.4 + 0.1), g * uBlushAmount * 0.5 * fa);
            }
        }
        if (uBrowsAmount > 0.001) {
            float dB = min(sdPoly10(uBrowL, qa), sdPoly10(uBrowR, qa));
            float aB = 1.0 - smoothstep(-e, e * 1.5, dB);
            c = mix(c, uBrowColor * (lum * 1.2 + 0.05), aB * uBrowsAmount * 0.7 * fa);
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
                c = mix(c, uShadowColor * (lum * 1.3 + 0.08), g * uShadowAmount * 0.6 * fa);
            }
        }
    }
#endif
    gl_FragColor = vec4(c, 1.0);
}
"""

    const val FULL_DEFINE = "#define MILES_FULL 1\n"
}
