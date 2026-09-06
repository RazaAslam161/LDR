package com.miles.miles.beauty

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The fade that stops a lost track popping the effect off, shared by both render paths. */
class FacePresenceTest {

    private val frame = 33_333_333L

    private fun face(): FaceFrame = FaceFrame(FloatArray(2 * FaceGeometry.POINT_COUNT), 1f, 0L)

    @Test
    fun `a found face eases in over the fade-in time, not in one frame`() {
        val p = FacePresence()
        val f = face()
        val first = p.update(f, 0L, 0L)
        assertEquals("first frame sets the clock and moves nothing", 0.0, first.toDouble(), 1e-6)
        val second = p.update(f, frame, frame)
        assertTrue("one frame later it has started but not finished: $second", second > 0f && second < 1f)
        var a = second
        var t = frame
        repeat(10) { t += frame; a = p.update(f, t, t) }
        assertEquals(1.0, a.toDouble(), 1e-6)
    }

    @Test
    fun `a lost face fades out and keeps its last geometry while doing so`() {
        val p = FacePresence()
        val f = face()
        var t = 0L
        repeat(10) { p.update(f, t, t); t += frame }
        assertEquals(1.0, p.alpha.toDouble(), 1e-6)
        val a = p.update(null, t - frame, t)
        assertTrue("must be fading, not off: $a", a > 0f && a < 1f)
        assertNotNull("geometry must survive the fade so the warp does not snap", p.lastFace)
        repeat(10) { t += frame; p.update(null, 0L, t) }
        assertEquals(0.0, p.alpha.toDouble(), 1e-6)
    }

    @Test
    fun `a stale face counts as absent even when the tracker still holds one`() {
        val p = FacePresence()
        val f = face()
        var t = 0L
        repeat(10) { p.update(f, t, t); t += frame }
        // The tracker stalled: same face object, lastSeen frozen half a second ago.
        val stale = t - FacePresence.STALE_NS - 1
        val a = p.update(f, stale, t)
        assertTrue("stale must fade out: $a", a < 1f)
    }

    @Test
    fun `a long pause takes one bounded step, not a jump`() {
        val p = FacePresence()
        val f = face()
        p.update(f, 0L, 0L)
        val a = p.update(f, 5_000_000_000L, 5_000_000_000L)
        assertTrue("dt is clamped to 100ms so one frame cannot complete the fade: $a", a < 1f)
    }

    @Test
    fun `idle keeps the clock without moving the fade`() {
        val p = FacePresence()
        val f = face()
        var t = 0L
        repeat(10) { p.update(f, t, t); t += frame }
        val before = p.alpha
        p.idle(t + 3_000_000_000L)
        assertEquals(before.toDouble(), p.alpha.toDouble(), 1e-6)
    }

    @Test
    fun `reset forgets the face and the fade`() {
        val p = FacePresence()
        p.update(face(), 0L, 0L)
        p.update(face(), frame, frame)
        p.reset()
        assertEquals(0.0, p.alpha.toDouble(), 1e-6)
        assertEquals(null, p.lastFace)
    }
}
