package com.miles.miles.beauty

import kotlin.math.atan2
import kotlin.math.sqrt

/**
 * The one coordinate space, stated once because every pass depends on it.
 *
 * Every intermediate texture the renderer draws is in the SurfaceTexture's own sampling space:
 * what `SurfaceTexture.getTransformMatrix` maps a "traditional 2D OpenGL ES texture coordinate"
 * to. That space is sensor-oriented (no display rotation, no per-output crop or mirror) and, per
 * the GL convention the matrix is documented against, t increases UPWARD. Face geometry lives in
 * that same space, so a mirrored preview and an un-mirrored capture see the same face in the same
 * place with zero code that knows the word "mirror" — the per-output transform is applied once, in
 * the final composite, by sampling through the matrix CameraX supplies.
 *
 * ML Kit needs an UPRIGHT face to find one, so it is fed the frame with its rotation and answers
 * in upright, y-DOWN image pixels. [uprightToTexture] is the only place that undoes both: the
 * rotation, then the vertical flip. It is the only orientation maths in the pipeline.
 *
 * Distances are anisotropic in normalised units unless the texture is square, so every point is
 * stored ASPECT-CORRECTED: (s * aspect, t). Radii, displacements and the shader's own maths are
 * all in that isotropic space; only the final sample coordinate divides x by aspect again.
 */
internal object FaceGeometry {

    /**
     * Maps a point ML Kit reported in the upright frame back into sensor-normalised, y-down space.
     *
     * @param u upright x / uprightWidth, in 0..1
     * @param v upright y / uprightHeight, in 0..1
     * @param rotationDegrees the clockwise rotation CameraX applied to make the frame upright
     *   (`ImageInfo.getRotationDegrees()`), a multiple of 90.
     */
    fun uprightToSensor(u: Float, v: Float, rotationDegrees: Int): Pair<Float, Float> =
        when (((rotationDegrees % 360) + 360) % 360) {
            0 -> Pair(u, v)
            // The sensor image was rotated 90° CW to become upright, so sensor (x, y) landed at
            // upright (H - y, x). Inverse, normalised: s = v, t = 1 - u.
            90 -> Pair(v, 1f - u)
            180 -> Pair(1f - u, 1f - v)
            // 270 CW is 90 CCW: sensor (x, y) landed at upright (y, W - x). Inverse: s = 1 - v, t = u.
            270 -> Pair(1f - v, u)
            else -> throw IllegalArgumentException("rotation must be a multiple of 90, got $rotationDegrees")
        }

    /**
     * The exact mapping for the camera path: an upright ML Kit point from the ANALYSIS buffer to
     * the EFFECT input texture, through CameraX's own sensor-to-buffer transforms.
     *
     * The two streams are different crops of the same sensor — the 4:3 analysis stream sees rows
     * the 16:9 effect stream does not — so normalised coordinates do not carry across. This does:
     * upright → analysis buffer pixels → (inverse analysis transform) sensor → (effect transform)
     * effect buffer pixels → normalised, flipped to y-up, aspect-corrected in the EFFECT aspect.
     *
     * @param toTarget the composed affine, analysis-buffer px → effect-buffer px
     */
    fun uprightToTarget(
        u: Float, v: Float, rotationDegrees: Int,
        srcW: Int, srcH: Int, toTarget: FloatArray, dstW: Int, dstH: Int,
    ): Pair<Float, Float> {
        val (s, t) = uprightToSensor(u, v, rotationDegrees)
        val (ex, ey) = Affine.map(toTarget, s * srcW, t * srcH)
        val aspect = dstW.toFloat() / dstH.toFloat()
        return Pair(ex / dstW * aspect, 1f - ey / dstH)
    }

    /**
     * [uprightToSensor], then the flip into the texture's y-up space, then aspect correction.
     * The call path's mapping, where the analysed buffer IS the rendered buffer.
     */
    fun uprightToTexture(u: Float, v: Float, rotationDegrees: Int, aspect: Float): Pair<Float, Float> {
        val (s, t) = uprightToSensor(u, v, rotationDegrees)
        return Pair(s * aspect, 1f - t)
    }

    // MediaPipe Face Mesh topology, which ML Kit's face-mesh-detection shares index for index.
    // Only the points a pass reads are named; the other 400-odd are smoothed and never read.
    const val LEFT_FACE_SIDE = 234
    const val RIGHT_FACE_SIDE = 454
    const val CHIN = 152
    const val FOREHEAD = 10
    const val NOSE_LEFT_ALA = 129
    const val NOSE_RIGHT_ALA = 358
    const val LEFT_CHEEK = 50
    const val RIGHT_CHEEK = 280
    val JAW_LEFT = intArrayOf(172, 136, 150)
    val JAW_RIGHT = intArrayOf(397, 365, 379)
    /** outer corner, inner corner, top lid, bottom lid */
    val LEFT_EYE = intArrayOf(33, 133, 159, 145)
    val RIGHT_EYE = intArrayOf(263, 362, 386, 374)
    val LIPS_OUTER = intArrayOf(
        61, 185, 40, 39, 37, 0, 267, 269, 270, 409, 291, 375, 321, 405, 314, 17, 84, 181, 91, 146,
    )
    val LIPS_INNER = intArrayOf(
        78, 191, 80, 81, 82, 13, 312, 311, 310, 415, 308, 324, 318, 402, 317, 14, 87, 178, 88, 95,
    )
    /** Upper edge outer-to-inner, then lower edge back, so the ten close into one polygon. */
    val LEFT_BROW = intArrayOf(70, 63, 105, 66, 107, 55, 65, 52, 53, 46)
    val RIGHT_BROW = intArrayOf(300, 293, 334, 296, 336, 285, 295, 282, 283, 276)

    const val POINT_COUNT = 468
    const val POLY = 20
    const val BROW = 10
}

/**
 * One tracked face, smoothed, in the texture space described on [FaceGeometry], plus everything
 * the shaders derive from it. Immutable: a new one is published per analysis frame and read by the
 * GL thread through a volatile reference, so there is no shared mutable state between the two.
 */
internal class FaceFrame(
    /** [FaceGeometry.POINT_COUNT] × (x, y), interleaved, aspect-corrected. */
    val points: FloatArray,
    val aspect: Float,
    val timestampNs: Long,
    /** Same layout, units per second, from the smoothing filters. Null for a synthetic frame. */
    val velocities: FloatArray? = null,
) {
    init {
        require(points.size == 2 * FaceGeometry.POINT_COUNT) { "expected 936 floats, got ${points.size}" }
        require(velocities == null || velocities.size == points.size) { "velocities must match points" }
    }

    /**
     * Where this face is expected to be at [atNs], from the filters' own smoothed velocities.
     *
     * Inference runs slower than rendering, so without this the mesh trails the face by up to a
     * whole inference period on every turn of the head. The clamp is NOT optional: with a stalled
     * tracker, unbounded extrapolation slides the mesh off the face and into the background
     * within a few hundred milliseconds, which is the ugliest failure this pipeline can produce.
     * Past the horizon the mesh simply holds, which reads as "paused" rather than "broken".
     */
    fun predicted(atNs: Long, horizonNs: Long = MAX_PREDICT_NS): FaceFrame {
        val vel = velocities ?: return this
        if (atNs <= timestampNs) return this
        val ahead = minOf(atNs - timestampNs, horizonNs) / 1e9f
        val out = FloatArray(points.size)
        for (i in points.indices) out[i] = points[i] + vel[i] * ahead
        return FaceFrame(out, aspect, atNs, vel)
    }

    fun x(i: Int) = points[2 * i]
    fun y(i: Int) = points[2 * i + 1]

    /** Cheekbone to cheekbone. The unit every radius and displacement is sized in. */
    val faceWidth: Float = dist(FaceGeometry.LEFT_FACE_SIDE, FaceGeometry.RIGHT_FACE_SIDE)
    val faceHeight: Float = dist(FaceGeometry.FOREHEAD, FaceGeometry.CHIN)
    val centerX: Float = (x(FaceGeometry.LEFT_FACE_SIDE) + x(FaceGeometry.RIGHT_FACE_SIDE)) / 2f
    val centerY: Float = (y(FaceGeometry.LEFT_FACE_SIDE) + y(FaceGeometry.RIGHT_FACE_SIDE)) / 2f

    /**
     * Unit vector from chin to forehead. "Up" for the FACE, which is what eyeshadow placement and
     * blush orientation need, and which is not the texture's +t axis because the texture is in
     * sensor orientation.
     */
    val upX: Float
    val upY: Float

    /** Rotation of the eye line, radians, for the skin-mask ellipse. */
    val roll: Float

    init {
        val dx = x(FaceGeometry.FOREHEAD) - x(FaceGeometry.CHIN)
        val dy = y(FaceGeometry.FOREHEAD) - y(FaceGeometry.CHIN)
        val len = sqrt(dx * dx + dy * dy).coerceAtLeast(1e-6f)
        upX = dx / len
        upY = dy / len
        val l = mean(FaceGeometry.LEFT_EYE)
        val r = mean(FaceGeometry.RIGHT_EYE)
        roll = atan2(r.second - l.second, r.first - l.first)
    }

    fun mean(idx: IntArray): Pair<Float, Float> {
        var sx = 0f
        var sy = 0f
        for (i in idx) {
            sx += x(i)
            sy += y(i)
        }
        return Pair(sx / idx.size, sy / idx.size)
    }

    fun dist(a: Int, b: Int): Float {
        val dx = x(a) - x(b)
        val dy = y(a) - y(b)
        return sqrt(dx * dx + dy * dy)
    }

    /** Copies the (x, y) of each index in [idx] into [out] from [offset], for a uniform upload. */
    fun gather(idx: IntArray, out: FloatArray, offset: Int = 0) {
        for ((k, i) in idx.withIndex()) {
            out[offset + 2 * k] = x(i)
            out[offset + 2 * k + 1] = y(i)
        }
    }

    /** Centre, semi-axes, roll — the ellipse the skin mask is confined to. */
    fun skinEllipse(out: FloatArray) {
        out[0] = centerX
        out[1] = centerY
        out[2] = faceWidth * 0.58f
        out[3] = faceHeight * 0.62f
        out[4] = roll
    }

    /** Per eye: centre x, centre y, half-width, half-height — for mask exclusion and eyeshadow. */
    fun eyeBoxes(out: FloatArray) {
        var o = 0
        for (idx in arrayOf(FaceGeometry.LEFT_EYE, FaceGeometry.RIGHT_EYE)) {
            val c = mean(idx)
            val w = dist(idx[0], idx[1])
            out[o++] = c.first
            out[o++] = c.second
            out[o++] = w * 0.75f
            out[o++] = w * 0.5f
        }
    }

    /** Per cheek: centre x, centre y, radius along the eye line, radius along "up". */
    fun cheeks(out: FloatArray) {
        val fw = faceWidth
        var o = 0
        for (i in intArrayOf(FaceGeometry.LEFT_CHEEK, FaceGeometry.RIGHT_CHEEK)) {
            out[o++] = x(i)
            out[o++] = y(i)
            out[o++] = fw * 0.20f
            out[o++] = fw * 0.13f
        }
    }

    /**
     * The reshape controls, laid out for the shader's RBF warp: five translation controls as
     * (cx, cy, dx, dy) + radius, then two eye controls as (cx, cy, radius, scale). Every value is
     * already multiplied by the signed slider in [p], so the shader holds no policy.
     *
     * Signs, so a reviewer can check them without a device: a positive jaw slider moves each jaw
     * point TOWARD the other; a positive nose slider moves each ala toward the other; a positive
     * chin slider lengthens (moves the chin AWAY from the forehead); a positive eyes slider
     * enlarges.
     */
    fun warpControls(p: BeautyParams, ctl: FloatArray, radii: FloatArray, eyes: FloatArray) {
        val fw = faceWidth
        val fh = faceHeight
        // Perpendicular to "up": along the eye line. Its sign is arbitrary, which is why each
        // pair below orients it from its own left point to its own right point.
        val sideX = -upY
        val sideY = upX
        var c = 0
        var r = 0
        fun ctl(cx: Float, cy: Float, dx: Float, dy: Float, radius: Float) {
            ctl[c++] = cx; ctl[c++] = cy; ctl[c++] = dx; ctl[c++] = dy
            radii[r++] = radius
        }
        fun toward(fromX: Float, fromY: Float, toX: Float, toY: Float): Float =
            if ((toX - fromX) * sideX + (toY - fromY) * sideY >= 0f) 1f else -1f

        val jl = mean(FaceGeometry.JAW_LEFT)
        val jr = mean(FaceGeometry.JAW_RIGHT)
        val jawAmt = p.jaw * 0.045f * fw
        val js = toward(jl.first, jl.second, jr.first, jr.second)
        ctl(jl.first, jl.second, js * sideX * jawAmt, js * sideY * jawAmt, 0.22f * fw)
        ctl(jr.first, jr.second, -js * sideX * jawAmt, -js * sideY * jawAmt, 0.22f * fw)

        val chinAmt = -p.chin * 0.035f * fh
        ctl(x(FaceGeometry.CHIN), y(FaceGeometry.CHIN), upX * chinAmt, upY * chinAmt, 0.16f * fh)

        val nl = FaceGeometry.NOSE_LEFT_ALA
        val nr = FaceGeometry.NOSE_RIGHT_ALA
        val noseAmt = p.nose * 0.35f * dist(nl, nr)
        val ns = toward(x(nl), y(nl), x(nr), y(nr))
        ctl(x(nl), y(nl), ns * sideX * noseAmt, ns * sideY * noseAmt, 0.9f * dist(nl, nr))
        ctl(x(nr), y(nr), -ns * sideX * noseAmt, -ns * sideY * noseAmt, 0.9f * dist(nl, nr))

        var e = 0
        for (idx in arrayOf(FaceGeometry.LEFT_EYE, FaceGeometry.RIGHT_EYE)) {
            val centre = mean(idx)
            eyes[e++] = centre.first
            eyes[e++] = centre.second
            eyes[e++] = dist(idx[0], idx[1]) * 0.95f
            eyes[e++] = p.eyes * 0.18f
        }
    }

    companion object {
        const val CONTROLS = 5
        const val EYES = 2

        /** Two frames at 30fps: the most a mesh may be extrapolated before it holds. */
        const val MAX_PREDICT_NS = 66_000_000L
    }
}

/**
 * 2D affine maths on `android.graphics.Matrix.getValues` layout — [a, b, c, d, e, f, 0, 0, 1],
 * x' = a·x + b·y + c, y' = d·x + e·y + f. Kept as plain floats so it is unit-testable on the JVM,
 * where the framework Matrix is a stub.
 */
internal object Affine {
    fun map(m: FloatArray, x: Float, y: Float): Pair<Float, Float> =
        Pair(m[0] * x + m[1] * y + m[2], m[3] * x + m[4] * y + m[5])

    /** Null for a singular matrix — a degenerate transform is refused, never guessed through. */
    fun invert(m: FloatArray): FloatArray? {
        val det = m[0] * m[4] - m[1] * m[3]
        if (det == 0f || det.isNaN()) return null
        return floatArrayOf(
            m[4] / det, -m[1] / det, (m[1] * m[5] - m[2] * m[4]) / det,
            -m[3] / det, m[0] / det, (m[2] * m[3] - m[0] * m[5]) / det,
            0f, 0f, 1f,
        )
    }

    /** `second ∘ first`: applies [first], then [second]. */
    fun concat(second: FloatArray, first: FloatArray): FloatArray = floatArrayOf(
        second[0] * first[0] + second[1] * first[3],
        second[0] * first[1] + second[1] * first[4],
        second[0] * first[2] + second[1] * first[5] + second[2],
        second[3] * first[0] + second[4] * first[3],
        second[3] * first[1] + second[4] * first[4],
        second[3] * first[2] + second[4] * first[5] + second[5],
        0f, 0f, 1f,
    )
}
