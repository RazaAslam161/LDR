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

/** The velocity a point exposes, which [FaceFrame.predicted] extrapolates with. */
class OneEuroPointTest {

    @Test
    fun `a still point reports zero velocity`() {
        val p = OneEuroPoint()
        for (i in 0 until 20) p.filter(42f, 7f, i * 33_333_333L)
        assertEquals(0.0, p.vx.toDouble(), 1e-6)
        assertEquals(0.0, p.vy.toDouble(), 1e-6)
    }

    @Test
    fun `a steady drift reports its direction and roughly its speed`() {
        val p = OneEuroPoint(minCutoff = 1.0, beta = 0.0)
        // 10 units per 33ms frame = 300 units per second, along x only.
        for (i in 0 until 30) p.filter(i * 10f, 0f, i * 33_333_333L)
        assertTrue("vx should be positive, got ${p.vx}", p.vx > 0f)
        assertTrue("vx should approach 300/s, got ${p.vx}", p.vx > 150f && p.vx < 350f)
        assertEquals(0.0, p.vy.toDouble(), 1e-6)
    }

    @Test
    fun `reset zeroes velocity so a flip does not carry the old lens's motion`() {
        val p = OneEuroPoint()
        for (i in 0 until 10) p.filter(i * 10f, 0f, i * 33_333_333L)
        p.reset()
        assertEquals(0.0, p.vx.toDouble(), 1e-6)
    }
}
