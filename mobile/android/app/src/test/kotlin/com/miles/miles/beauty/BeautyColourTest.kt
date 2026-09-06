package com.miles.miles.beauty

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The conversion from Flutter's 4×5 0..255 colour matrix to the shader's 0..1 form. Get the
 * offset scale wrong and every preset is blown out; get a row wrong and the video is green.
 */
class BeautyColourTest {

    private val identity = listOf(
        1.0, 0.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 0.0, 1.0, 0.0,
    )

    private fun payload(matrix: List<Double>, overlay: Long = 0L, screen: Boolean = false) =
        mapOf("on" to true, "matrix" to matrix, "overlayArgb" to overlay, "overlayScreen" to screen)

    @Test
    fun `identity converts to identity rows and a zero constant`() {
        val c = BeautyColour.fromMap(payload(identity))
        assertNotNull(c)
        assertArrayEquals(floatArrayOf(1f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 1f), c!!.rows, 1e-6f)
        assertArrayEquals(floatArrayOf(0f, 0f, 0f), c.constant, 1e-6f)
        assertEquals(0f, c.overlay[3], 1e-6f)
    }

    @Test
    fun `the fifth column is an offset on 0 to 255 and is scaled down`() {
        val m = identity.toMutableList()
        m[4] = 25.5   // +25.5 on red, in 0..255 units
        val c = BeautyColour.fromMap(payload(m))!!
        assertEquals(0.1f, c.constant[0], 1e-6f)
    }

    @Test
    fun `the alpha column folds into the constant because alpha is one`() {
        val m = identity.toMutableList()
        m[8] = 0.2    // green row, alpha coefficient
        val c = BeautyColour.fromMap(payload(m))!!
        assertEquals(0.2f, c.constant[1], 1e-6f)
    }

    @Test
    fun `a Noir-style desaturation keeps its rows in order`() {
        // Row-major: the R row is the first five, the B row the eleventh to fifteenth.
        val m = listOf(
            0.3, 0.59, 0.11, 0.0, 0.0,
            0.3, 0.59, 0.11, 0.0, 0.0,
            0.3, 0.59, 0.11, 0.0, 0.0,
            0.0, 0.0, 0.0, 1.0, 0.0,
        )
        val c = BeautyColour.fromMap(payload(m))!!
        assertEquals(0.59f, c.rows[1], 1e-6f)
        assertEquals(0.11f, c.rows[8], 1e-6f)
    }

    @Test
    fun `an overlay ARGB decodes with its alpha, including full-alpha values above Int range`() {
        // 0x22FF0044 as Dart sends it: below 2^31, arrives as Int; 0xFF... arrives as Long.
        val c = BeautyColour.fromMap(payload(identity, overlay = 0x22FF0044L, screen = true))!!
        assertEquals(0x22 / 255f, c.overlay[3], 1e-6f)
        assertEquals(1f, c.overlay[0], 1e-6f)
        assertEquals(0x44 / 255f, c.overlay[2], 1e-6f)
        assertTrue(c.overlayScreen)
        val full = BeautyColour.fromMap(payload(identity, overlay = 0xFF00FF00L))!!
        assertEquals(1f, full.overlay[3], 1e-6f)
        assertEquals(1f, full.overlay[1], 1e-6f)
    }

    @Test
    fun `off, a short matrix or a non-number is no grade - never a wrong one`() {
        assertNull(BeautyColour.fromMap(mapOf("on" to false, "matrix" to identity)))
        assertNull(BeautyColour.fromMap(payload(identity.take(19))))
        val bad = identity.toMutableList<Any>()
        bad[7] = "x"
        assertNull(BeautyColour.fromMap(mapOf("on" to true, "matrix" to bad)))
        assertNull(BeautyColour.fromMap(null))
    }
}
