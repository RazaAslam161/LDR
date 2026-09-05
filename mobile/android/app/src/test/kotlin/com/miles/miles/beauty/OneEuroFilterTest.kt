package com.miles.miles.beauty

import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The smoothing maths, tested on the JVM because it is the only part of the beauty pipeline that
 * can be proven without a handset — and because every failure mode here is silent on a device.
 *
 * A NaN from a zero timestamp delta does not throw; it propagates into a shader uniform and the
 * face disappears. Overshoot does not throw; it makes a jaw wobble past its target and back. Each
 * test below is one of those, pinned.
 */
class OneEuroFilterTest {

    private val hz30 = 33_333_333L

    private fun times(n: Int, step: Long = 33_333_333L): List<Long> =
        (0 until n).map { it * step }

    @Test
    fun `first sample passes through untouched`() {
        val f = OneEuroFilter()
        // A filter that ramps from zero would drag the first frame of every face in from the
        // origin — a visible swoop on acquisition.
        assertEquals(5.0, f.filter(5.0, 0L), 1e-9)
    }

    @Test
    fun `a constant signal stays exactly constant`() {
        val f = OneEuroFilter()
        f.filter(10.0, 0L)
        for (t in times(30).drop(1)) {
            assertEquals(10.0, f.filter(10.0, t), 1e-9)
        }
    }

    @Test
    fun `a step converges toward the new value and never overshoots it`() {
        val f = OneEuroFilter(minCutoff = 1.0, beta = 0.007)
        f.filter(0.0, 0L)
        var last = 0.0
        for ((i, t) in times(60).drop(1).withIndex()) {
            val out = f.filter(100.0, t)
            assertTrue("sample $i went backwards: $last -> $out", out >= last - 1e-9)
            assertTrue("sample $i overshot 100: $out", out <= 100.0 + 1e-9)
            last = out
        }
        // 60 frames is two seconds at 30Hz; it must actually get there, not merely trend.
        assertTrue("did not converge, reached $last", last > 90.0)
    }

    @Test
    fun `smoothing attenuates jitter around a still value`() {
        val f = OneEuroFilter(minCutoff = 0.5, beta = 0.007)
        var rawSwing = 0.0
        var outSwing = 0.0
        var prevOut = f.filter(50.0, 0L)
        // Alternating +/-1px noise, which is the real shape of landmark error.
        for ((i, t) in times(40).drop(1).withIndex()) {
            val raw = if (i % 2 == 0) 51.0 else 49.0
            val out = f.filter(raw, t)
            if (i > 10) {
                rawSwing += 2.0
                outSwing += abs(out - prevOut)
            }
            prevOut = out
        }
        assertTrue(
            "smoothing did not reduce jitter: raw=$rawSwing out=$outSwing",
            outSwing < rawSwing * 0.5,
        )
    }

    @Test
    fun `a repeated timestamp cannot produce NaN`() {
        // The bug this exists for: dt == 0 divides by zero, and NaN in a warp uniform is a face
        // that vanishes rather than a face that looks wrong.
        val f = OneEuroFilter()
        f.filter(1.0, 1000L)
        val out = f.filter(2.0, 1000L)
        assertFalse("filter produced NaN on a repeated timestamp", out.isNaN())
        assertEquals(1.0, out, 1e-9)
    }

    @Test
    fun `a backwards timestamp cannot produce NaN`() {
        val f = OneEuroFilter()
        f.filter(1.0, 2000L)
        val out = f.filter(9.0, 1000L)
        assertFalse("filter produced NaN on a backwards timestamp", out.isNaN())
        assertEquals(1.0, out, 1e-9)
    }

    @Test
    fun `reset forgets history so a flip does not lerp across the jump`() {
        val f = OneEuroFilter()
        f.filter(0.0, 0L)
        f.filter(0.0, hz30)
        f.reset()
        // After a camera flip the landmarks are a different face in a different space; the first
        // sample must be taken at face value, not blended with the old lens's.
        assertEquals(80.0, f.filter(80.0, 2 * hz30), 1e-9)
    }

    @Test
    fun `higher beta lags a moving signal less`() {
        val lazy = OneEuroFilter(minCutoff = 0.5, beta = 0.0)
        val eager = OneEuroFilter(minCutoff = 0.5, beta = 5.0)
        var lazyOut = 0.0
        var eagerOut = 0.0
        for ((i, t) in times(30).withIndex()) {
            val ramp = i * 10.0
            lazyOut = lazy.filter(ramp, t)
            eagerOut = eager.filter(ramp, t)
        }
        assertTrue(
            "beta did not reduce lag: lazy=$lazyOut eager=$eagerOut",
            eagerOut > lazyOut,
        )
    }
}

/** The prediction clamp, which is what stops a stalled tracker sliding the mesh off the face. */
class OneEuroPointTest {

    @Test
    fun `prediction is bounded by the horizon`() {
        val p = OneEuroPoint(minCutoff = 1.0, beta = 0.0)
        // Feed a steady rightward drift so velocity is non-zero.
        for (i in 0 until 20) {
            p.filter(i * 10f, 0f, i * 33_333_333L)
        }
        val lastNs = 19 * 33_333_333L
        val (nearX, _) = p.predict(lastNs + 33_000_000L, lastNs)
        // Ten seconds stale: the clamp must stop this, or the mesh ends up in the background.
        val (farX, _) = p.predict(lastNs + 10_000_000_000L, lastNs)
        val (horizonX, _) = p.predict(lastNs + OneEuroPoint.MAX_PREDICT_NS, lastNs)

        assertEquals(
            "prediction past the horizon must equal prediction AT the horizon",
            horizonX.toDouble(),
            farX.toDouble(),
            1e-3,
        )
        assertTrue("a nearer prediction should be closer than the horizon one", nearX <= horizonX)
    }

    @Test
    fun `prediction never runs backwards in time`() {
        val p = OneEuroPoint()
        for (i in 0 until 10) {
            p.filter(i * 5f, i * 5f, i * 33_333_333L)
        }
        val lastNs = 9 * 33_333_333L
        // A render timestamp older than the sample must not extrapolate backwards.
        val (x, _) = p.predict(lastNs - 1_000_000_000L, lastNs)
        assertEquals(p.x.toDouble(), x.toDouble(), 1e-6)
    }

    @Test
    fun `a still point predicts itself`() {
        val p = OneEuroPoint()
        for (i in 0 until 20) {
            p.filter(42f, 7f, i * 33_333_333L)
        }
        val lastNs = 19 * 33_333_333L
        val (x, y) = p.predict(lastNs + OneEuroPoint.MAX_PREDICT_NS, lastNs)
        assertEquals(42.0, x.toDouble(), 1e-3)
        assertEquals(7.0, y.toDouble(), 1e-3)
    }
}
