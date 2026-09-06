package com.miles.miles.beauty

import java.nio.ByteBuffer

/**
 * Packs three I420 planes into one NV21 buffer, which is the layout ML Kit's
 * `InputImage.fromByteArray` takes.
 *
 * NV21 is the full Y plane followed by interleaved V,U pairs at quarter resolution. Strides are
 * honoured on the way in because WebRTC's I420 buffers are padded; the output is tightly packed.
 * [width] and [height] must be even, which every camera size is.
 */
internal fun packNv21(
    y: ByteBuffer, yStride: Int,
    u: ByteBuffer, uStride: Int,
    v: ByteBuffer, vStride: Int,
    width: Int, height: Int,
    out: ByteArray,
) {
    require(width % 2 == 0 && height % 2 == 0) { "NV21 needs even dimensions, got ${width}x$height" }
    require(out.size >= nv21Size(width, height)) { "out too small: ${out.size} < ${nv21Size(width, height)}" }
    val yy = y.duplicate()
    for (row in 0 until height) {
        yy.position(row * yStride)
        yy.get(out, row * width, width)
    }
    val cw = width / 2
    val ch = height / 2
    var o = width * height
    for (row in 0 until ch) {
        val ub = row * uStride
        val vb = row * vStride
        for (col in 0 until cw) {
            out[o++] = v.get(vb + col)
            out[o++] = u.get(ub + col)
        }
    }
}

internal fun nv21Size(width: Int, height: Int): Int = width * height * 3 / 2
