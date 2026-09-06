package com.miles.miles.beauty

import java.nio.ByteBuffer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The I420 → NV21 packing that feeds ML Kit from a WebRTC frame. A wrong interleave order or an
 * ignored stride does not throw — it feeds the detector a colour-shifted or sheared image, and
 * the face simply stops being found.
 */
class Nv21Test {

    // A 4x2 frame with PADDED strides (Y stride 6, chroma stride 4 for a chroma width of 2).
    private val y = ByteBuffer.wrap(byteArrayOf(
        1, 2, 3, 4, 99, 99,
        5, 6, 7, 8, 99, 99,
    ))
    private val u = ByteBuffer.wrap(byteArrayOf(10, 11, 99, 99))
    private val v = ByteBuffer.wrap(byteArrayOf(20, 21, 99, 99))

    @Test
    fun `size is 1 and a half bytes per pixel`() {
        assertEquals(12, nv21Size(4, 2))
        assertEquals(640 * 480 * 3 / 2, nv21Size(640, 480))
    }

    @Test
    fun `strides are honoured and the padding never reaches the output`() {
        val out = ByteArray(nv21Size(4, 2))
        packNv21(y, 6, u, 4, v, 4, 4, 2, out)
        // Y plane tightly packed, then V,U interleaved — NV21, not NV12.
        assertArrayEquals(byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8, 20, 10, 21, 11), out)
    }

    @Test
    fun `chroma is V then U - the NV21 order ML Kit expects`() {
        val out = ByteArray(nv21Size(4, 2))
        packNv21(y, 6, u, 4, v, 4, 4, 2, out)
        assertEquals(20.toByte(), out[8])
        assertEquals(10.toByte(), out[9])
    }

    @Test(expected = IllegalArgumentException::class)
    fun `odd dimensions are refused rather than silently truncated`() {
        packNv21(y, 6, u, 4, v, 4, 3, 2, ByteArray(64))
    }

    @Test(expected = IllegalArgumentException::class)
    fun `a short output buffer is refused rather than overrun`() {
        packNv21(y, 6, u, 4, v, 4, 4, 2, ByteArray(11))
    }

    @Test
    fun `the source buffers' positions are left alone`() {
        val out = ByteArray(nv21Size(4, 2))
        packNv21(y, 6, u, 4, v, 4, 4, 2, out)
        // A caller that reads the planes again must not find them consumed.
        assertEquals(0, y.position())
        assertEquals(0, u.position())
        assertEquals(0, v.position())
    }
}
