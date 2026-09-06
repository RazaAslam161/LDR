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

    // ── prediction ────────────────────────────────────────────────────────────────────────

    private fun moving(vxPerSec: Float): FaceFrame {
        val pts = FloatArray(2 * FaceGeometry.POINT_COUNT) { 0.5f }
        val vel = FloatArray(2 * FaceGeometry.POINT_COUNT) { if (it % 2 == 0) vxPerSec else 0f }
        return FaceFrame(pts, 1f, 1_000_000_000L, vel)
    }

    @Test
    fun `prediction moves every point by velocity times the lead`() {
        val f = moving(0.2f)
        val p = f.predicted(f.timestampNs + 33_000_000L)
        assertEquals(0.5 + 0.2 * 0.033, p.x(10).toDouble(), 1e-5)
        assertEquals(0.5, p.y(10).toDouble(), 1e-6)
        assertEquals(f.timestampNs + 33_000_000L, p.timestampNs)
    }

    @Test
    fun `prediction is bounded by the horizon so a stalled tracker holds instead of sliding`() {
        val f = moving(1.0f)
        val atHorizon = f.predicted(f.timestampNs + FaceFrame.MAX_PREDICT_NS)
        val farPast = f.predicted(f.timestampNs + 10_000_000_000L)
        assertEquals(atHorizon.x(0).toDouble(), farPast.x(0).toDouble(), 1e-6)
        assertTrue(atHorizon.x(0) < 0.6f)
    }

    @Test
    fun `a render older than the sample, or a frame without velocities, is the frame itself`() {
        val f = moving(1.0f)
        assertTrue(f.predicted(f.timestampNs - 1L) === f)
        assertTrue(f.predicted(f.timestampNs) === f)
        val still = FaceFrame(FloatArray(2 * FaceGeometry.POINT_COUNT), 1f, 0L)
        assertTrue(still.predicted(5_000_000_000L) === still)
    }

    // ── the exact analysis-to-effect mapping ─────────────────────────────────────────────

    @Test
    fun `affine invert and concat round-trip`() {
        val m = floatArrayOf(0.5f, 0f, 10f, 0f, 2f, -4f, 0f, 0f, 1f)
        val inv = Affine.invert(m)!!
        val (x, y) = Affine.map(Affine.concat(inv, m), 123f, 45f)
        assertEquals(123.0, x.toDouble(), 1e-3)
        assertEquals(45.0, y.toDouble(), 1e-3)
        assertTrue(Affine.invert(floatArrayOf(1f, 2f, 0f, 2f, 4f, 0f, 0f, 0f, 1f)) == null)
    }

    @Test
    fun `a 4-3 analysis stream and a 16-9 effect stream meet on the sensor`() {
        // Sensor 4000x3000. Analysis: the full sensor scaled to 640x480 (×0.16). Effect: the
        // centred 16:9 band (rows 375..2625) scaled to 1920x1080 (×0.48). A point at the centre
        // of the analysis frame must land at the centre of the effect frame; a point 1/8 of the
        // analysis height from the top must land ON the effect's top edge.
        val analysis = floatArrayOf(0.16f, 0f, 0f, 0f, 0.16f, 0f, 0f, 0f, 1f)
        val effect = floatArrayOf(0.48f, 0f, 0f, 0f, 0.48f, -375f * 0.48f, 0f, 0f, 1f)
        val toTarget = Affine.concat(effect, Affine.invert(analysis)!!)
        val (cx, cy) = FaceGeometry.uprightToTarget(0.5f, 0.5f, 0, 640, 480, toTarget, 1920, 1080)
        assertEquals(0.5 * (1920.0 / 1080.0), cx.toDouble(), 1e-4)
        assertEquals(0.5, cy.toDouble(), 1e-4)
        val (_, ty) = FaceGeometry.uprightToTarget(0.5f, 0.125f, 0, 640, 480, toTarget, 1920, 1080)
        // y-down 0 at the effect's top edge becomes y-up 1.
        assertEquals(1.0, ty.toDouble(), 1e-4)
    }

    @Test
    fun `identity transforms reduce the target mapping to the plain one`() {
        val id = floatArrayOf(1f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 1f)
        val a = FaceGeometry.uprightToTarget(0.3f, 0.7f, 90, 640, 480, id, 640, 480)
        val b = FaceGeometry.uprightToTexture(0.3f, 0.7f, 90, 640f / 480f)
        assertEquals(b.first.toDouble(), a.first.toDouble(), 1e-5)
        assertEquals(b.second.toDouble(), a.second.toDouble(), 1e-5)
    }
}
