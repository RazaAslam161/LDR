package com.miles.miles.beauty

/**
 * Turns the tracker's "a face, or null" into a smooth 0..1 so a lost track DIMS the effect
 * instead of popping it off, and a found one eases in instead of snapping on.
 *
 * Both paths — the camera effect and the call processor — drive one of these from their own
 * frame clock. Not thread-safe; one instance per render thread.
 */
internal class FacePresence {
    /** The last face seen, kept while fading out so the geometry does not vanish mid-fade. */
    var lastFace: FaceFrame? = null
        private set

    var alpha = 0f
        private set

    private var lastFrameNs = 0L
    private var started = false

    fun reset() {
        lastFace = null
        alpha = 0f
        lastFrameNs = 0L
        started = false
    }

    /**
     * Advances the fade for the frame at [ts].
     *
     * @param fresh the tracker's newest face, or null
     * @param lastSeenNs when the tracker last had one; older than [STALE_NS] counts as gone even
     *   if [fresh] is still non-null, so a stalled tracker fades out rather than freezing a face
     *   onto whatever moved into its place.
     */
    fun update(fresh: FaceFrame?, lastSeenNs: Long, ts: Long): Float {
        val present = fresh != null && ts - lastSeenNs < STALE_NS
        if (fresh != null) lastFace = fresh
        // Clamped so the first frame after a long pause takes one step, not a jump. An explicit
        // flag, not a zero sentinel: a first timestamp of 0 is legal, and a sentinel on it froze
        // the fade at zero for the whole second frame — caught by the unit test, not a device.
        val dt = if (!started) 0f else ((ts - lastFrameNs) / 1e9f).coerceIn(0f, 0.1f)
        started = true
        val target = if (present) 1f else 0f
        val rate = if (present) 1f / FADE_IN_S else 1f / FADE_OUT_S
        alpha = if (alpha < target) minOf(target, alpha + dt * rate) else maxOf(target, alpha - dt * rate)
        lastFrameNs = ts
        return alpha
    }

    /** A frame passed with the effect off: keeps the clock honest without moving the fade. */
    fun idle(ts: Long) {
        lastFrameNs = ts
        started = true
    }

    companion object {
        const val STALE_NS = 400_000_000L
        const val FADE_IN_S = 0.12f
        const val FADE_OUT_S = 0.20f
    }
}
