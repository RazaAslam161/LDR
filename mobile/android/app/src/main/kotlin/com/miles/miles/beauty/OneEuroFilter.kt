package com.miles.miles.beauty

import kotlin.math.abs

/**
 * A One-Euro filter, the smoothing that stands between a face mesh and a warp that "boils".
 *
 * WHY THIS AND NOT A FIXED LOW-PASS
 * Landmark regression noise is roughly a pixel per point and independent between frames. A
 * geometry warp differentiates that spatially, so a jaw contour jittering by +/-1px becomes a
 * visible shimmer across the whole cheek — and the eye is specifically tuned to notice a face
 * silhouette moving against a still background. A fixed low-pass heavy enough to kill the
 * shimmer also lags every real head turn, which reads as the face swimming inside the effect.
 *
 * One-Euro adapts: it low-passes hard when the signal is still and lets go when the signal
 * moves, by deriving its cutoff from the smoothed speed. [minCutoff] sets how still it is when
 * the face is still (lower = steadier, more lag); [beta] sets how fast it releases under motion
 * (higher = less lag, more jitter while moving).
 *
 * Reference: Casiez, Roussel & Vogel, "1 Euro Filter" (CHI 2012).
 *
 * Not thread-safe by design: one instance per filtered scalar, all driven from one tracker
 * thread.
 */
internal class OneEuroFilter(
    private val minCutoff: Double = 1.0,
    private val beta: Double = 0.007,
    private val dCutoff: Double = 1.0,
) {
    private var xPrev = 0.0
    private var dxHat = 0.0
    private var xHat = 0.0
    private var tPrevNs = 0L
    private var started = false

    /**
     * Feeds one sample and returns the smoothed value.
     *
     * @param timestampNs the sample's OWN capture time, not the time it finished being computed.
     *   Inference latency varies frame to frame; driving the filter from completion time makes
     *   the smoothing vary with how busy the phone is.
     */
    fun filter(x: Double, timestampNs: Long): Double {
        if (!started) {
            started = true
            xPrev = x
            xHat = x
            dxHat = 0.0
            tPrevNs = timestampNs
            return x
        }

        val dt = (timestampNs - tPrevNs) / 1e9
        // Two samples with the same (or a going-backwards) timestamp would divide by zero and
        // poison every later value with NaN — and NaN in a warp uniform is a face that vanishes,
        // not a face that looks wrong. Hold the last output instead.
        if (dt <= 0.0) return xHat

        tPrevNs = timestampNs

        val dx = (x - xPrev) / dt
        xPrev = x
        dxHat = lowPass(dx, dxHat, alpha(dCutoff, dt))

        val cutoff = minCutoff + beta * abs(dxHat)
        xHat = lowPass(x, xHat, alpha(cutoff, dt))
        return xHat
    }

    /** Forgets all history. Use on a discontinuity — a camera flip, or a different face. */
    fun reset() {
        started = false
        xPrev = 0.0
        xHat = 0.0
        dxHat = 0.0
        tPrevNs = 0L
    }

    /** The filter's own smoothed derivative, in units per second. Free, and used for prediction. */
    fun velocity(): Double = dxHat

    private fun alpha(cutoff: Double, dt: Double): Double {
        val tau = 1.0 / (TWO_PI * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }

    private fun lowPass(x: Double, prev: Double, a: Double): Double = a * x + (1.0 - a) * prev

    private companion object {
        const val TWO_PI = 2.0 * Math.PI
    }
}

/**
 * A 2D point filtered by a pair of [OneEuroFilter]s, which is how landmarks are actually consumed.
 *
 * Filtering x and y independently is correct here: the noise is independent per axis, and a
 * coupled filter would make a horizontal head turn damp vertical detail for no reason.
 */
internal class OneEuroPoint(
    minCutoff: Double = 1.0,
    beta: Double = 0.007,
    dCutoff: Double = 1.0,
) {
    private val fx = OneEuroFilter(minCutoff, beta, dCutoff)
    private val fy = OneEuroFilter(minCutoff, beta, dCutoff)

    var x = 0f
        private set
    var y = 0f
        private set

    fun filter(px: Float, py: Float, timestampNs: Long) {
        x = fx.filter(px.toDouble(), timestampNs).toFloat()
        y = fy.filter(py.toDouble(), timestampNs).toFloat()
    }

    /** Smoothed velocity, units per second. Free, and what [FaceFrame.predicted] extrapolates with. */
    val vx: Float get() = fx.velocity().toFloat()
    val vy: Float get() = fy.velocity().toFloat()

    fun reset() {
        fx.reset()
        fy.reset()
        x = 0f
        y = 0f
    }
}
