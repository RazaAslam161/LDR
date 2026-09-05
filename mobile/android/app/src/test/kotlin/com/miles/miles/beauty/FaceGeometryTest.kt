package com.miles.miles.beauty

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The only orientation maths in the pipeline, and the signs of every reshape control.
 *
 * Get a rotation case wrong and the effect lands on the background instead of the face; get a
 * sign wrong and "slim" widens. Both are silent on a device and obvious here.
 */
class FaceGeometryTest {

    private fun assertPair(expected: Pair<Float, Float>, actual: Pair<Float, Float>, msg: String) {
        assertEquals("$msg (x)", expected.first.toDouble(), actual.first.toDouble(), 1e-6)
        assertEquals("$msg (y)", expected.second.toDouble(), actual.second.toDouble(), 1e-6)
    }

    @Test
    fun `rotation 0 is the identity`() {
        assertPair(Pair(0.25f, 0.75f), FaceGeometry.uprightToSensor(0.25f, 0.75f, 0), "rot 0")
    }

    @Test
    fun `rotation 90 sends the upright top-left corner to the sensor bottom-left`() {
        // Rotating the sensor image 90° CW to make it upright moves the sensor's bottom-left
        // corner to the top-left, so the inverse sends upright top-left back to bottom-left.
        assertPair(Pair(0f, 1f), FaceGeometry.uprightToSensor(0f, 0f, 90), "rot 90 corner")
        assertPair(Pair(0.75f, 0.75f), FaceGeometry.uprightToSensor(0.25f, 0.75f, 90), "rot 90")
    }

    @Test
    fun `rotation 180 mirrors both axes`() {
        assertPair(Pair(0.75f, 0.25f), FaceGeometry.uprightToSensor(0.25f, 0.75f, 180), "rot 180")
    }

    @Test
    fun `rotation 270 sends the upright top-left corner to the sensor top-right`() {
        assertPair(Pair(1f, 0f), FaceGeometry.uprightToSensor(0f, 0f, 270), "rot 270 corner")
        assertPair(Pair(0.25f, 0.25f), FaceGeometry.uprightToSensor(0.25f, 0.75f, 270), "rot 270")
    }

    @Test
    fun `four applications of the 90 mapping are the identity`() {
        var p = Pair(0.1f, 0.6f)
        repeat(4) { p = FaceGeometry.uprightToSensor(p.first, p.second, 90) }
        assertPair(Pair(0.1f, 0.6f), p, "90 x4")
    }

    @Test
    fun `the centre is a fixed point of every rotation`() {
        for (rot in intArrayOf(0, 90, 180, 270)) {
            assertPair(Pair(0.5f, 0.5f), FaceGeometry.uprightToSensor(0.5f, 0.5f, rot), "centre rot $rot")
        }
    }

    @Test
    fun `negative and over-360 rotations normalise`() {
        assertPair(
            FaceGeometry.uprightToSensor(0.2f, 0.9f, 270),
            FaceGeometry.uprightToSensor(0.2f, 0.9f, -90),
            "-90 == 270",
        )
        assertPair(
            FaceGeometry.uprightToSensor(0.2f, 0.9f, 90),
            FaceGeometry.uprightToSensor(0.2f, 0.9f, 450),
            "450 == 90",
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun `a rotation that is not a multiple of 90 is refused, not rounded`() {
        FaceGeometry.uprightToSensor(0.5f, 0.5f, 45)
    }

    @Test
    fun `texture space flips t and scales s by aspect`() {
        // Landmarks arrive y-down; the texture's sampling space is y-up.
        val (s, t) = FaceGeometry.uprightToTexture(0.25f, 0.75f, 0, 2f)
        assertEquals(0.5, s.toDouble(), 1e-6)
        assertEquals(0.25, t.toDouble(), 1e-6)
    }

    // ── a synthetic face, upright in texture space, for the derived geometry ─────────────

    private fun face(aspect: Float = 1f): FaceFrame {
        val pts = FloatArray(2 * FaceGeometry.POINT_COUNT)
        fun set(i: Int, x: Float, y: Float) {
            pts[2 * i] = x
            pts[2 * i + 1] = y
        }
        // Face 0.4 wide, centred at (0.5, 0.5); forehead above chin in a y-UP space.
        set(FaceGeometry.LEFT_FACE_SIDE, 0.3f, 0.5f)
        set(FaceGeometry.RIGHT_FACE_SIDE, 0.7f, 0.5f)
        set(FaceGeometry.FOREHEAD, 0.5f, 0.78f)
        set(FaceGeometry.CHIN, 0.5f, 0.22f)
        for (i in FaceGeometry.JAW_LEFT) set(i, 0.36f, 0.32f)
        for (i in FaceGeometry.JAW_RIGHT) set(i, 0.64f, 0.32f)
        set(FaceGeometry.NOSE_LEFT_ALA, 0.46f, 0.48f)
        set(FaceGeometry.NOSE_RIGHT_ALA, 0.54f, 0.48f)
        // Eyes: outer, inner, top, bottom.
        set(33, 0.36f, 0.58f); set(133, 0.44f, 0.58f); set(159, 0.40f, 0.60f); set(145, 0.40f, 0.56f)
        set(263, 0.64f, 0.58f); set(362, 0.56f, 0.58f); set(386, 0.60f, 0.60f); set(374, 0.60f, 0.56f)
        return FaceFrame(pts, aspect, 0L)
    }

    @Test
    fun `face width and up vector come out of the named landmarks`() {
        val f = face()
        assertEquals(0.4, f.faceWidth.toDouble(), 1e-6)
        assertEquals(0.0, f.upX.toDouble(), 1e-6)
        assertEquals(1.0, f.upY.toDouble(), 1e-6)
        assertEquals(0.0, f.roll.toDouble(), 1e-6)
    }

    private fun controls(p: BeautyParams): Triple<FloatArray, FloatArray, FloatArray> {
        val ctl = FloatArray(4 * FaceFrame.CONTROLS)
        val radii = FloatArray(FaceFrame.CONTROLS)
        val eyes = FloatArray(4 * FaceFrame.EYES)
        face().warpControls(p, ctl, radii, eyes)
        return Triple(ctl, radii, eyes)
    }

    @Test
    fun `all sliders at zero produce zero displacement everywhere`() {
        val (ctl, _, eyes) = controls(BeautyParams.OFF)
        for (i in 0 until FaceFrame.CONTROLS) {
            assertEquals("dx $i", 0.0, ctl[4 * i + 2].toDouble(), 1e-9)
            assertEquals("dy $i", 0.0, ctl[4 * i + 3].toDouble(), 1e-9)
        }
        assertEquals(0.0, eyes[3].toDouble(), 1e-9)
        assertEquals(0.0, eyes[7].toDouble(), 1e-9)
    }

    @Test
    fun `positive jaw moves each jaw point toward the other`() {
        val (ctl, _, _) = controls(BeautyParams.OFF.copy(jaw = 1f))
        val lx = ctl[0]; val rx = ctl[4]
        val ldx = ctl[2]; val rdx = ctl[6]
        assertTrue("left jaw must move right", (rx - lx) * ldx > 0f)
        assertTrue("right jaw must move left", (lx - rx) * rdx > 0f)
        assertEquals(0.045 * 0.4, Math.abs(ldx.toDouble()), 1e-6)
    }

    @Test
    fun `negative jaw widens`() {
        val (ctl, _, _) = controls(BeautyParams.OFF.copy(jaw = -1f))
        assertTrue("left jaw must move left", (ctl[4] - ctl[0]) * ctl[2] < 0f)
    }

    @Test
    fun `positive chin lengthens, away from the forehead`() {
        val (ctl, _, _) = controls(BeautyParams.OFF.copy(chin = 1f))
        val f = face()
        val dot = ctl[10] * f.upX + ctl[11] * f.upY
        assertTrue("chin must move against up", dot < 0f)
    }

    @Test
    fun `positive nose brings the alae together`() {
        val (ctl, _, _) = controls(BeautyParams.OFF.copy(nose = 1f))
        val lx = ctl[12]; val rx = ctl[16]
        assertTrue("left ala must move right", (rx - lx) * ctl[14] > 0f)
        assertTrue("right ala must move left", (lx - rx) * ctl[18] > 0f)
    }

    @Test
    fun `positive eyes enlarges and the radius tracks the eye width`() {
        val (_, _, eyes) = controls(BeautyParams.OFF.copy(eyes = 0.5f))
        assertEquals(0.5 * 0.18, eyes[3].toDouble(), 1e-6)
        assertEquals(0.08 * 0.95, eyes[2].toDouble(), 1e-6)
    }

    @Test
    fun `aspect correction is isotropic - a wider texture does not stretch the face`() {
        // Points are stored pre-multiplied by aspect, so faceWidth is already isotropic; the
        // renderer only divides x back out at the sample.
        val f = face(aspect = 1.5f)
        assertEquals(0.4, f.faceWidth.toDouble(), 1e-6)
    }
}
