package com.miles.miles.beauty

/**
 * The colour grade the composite applies as its LAST step: one of the camera's eleven presets,
 * handed over so the preview, the still and the recorded video are one grade instead of three.
 *
 * The wire shape is Flutter's `ColorFilter.matrix` — 4×5, row-major, on 0..255 colours with the
 * fifth column an offset in that range — plus the preset's optional overlay. It is converted
 * here, once, into what a 0..1 shader wants: three row vectors, a per-row constant, and an
 * overlay as RGBA. Alpha is always 1 in a camera frame, so the alpha coefficient folds straight
 * into the constant.
 */
internal class BeautyColour(
    /** Row vectors for R, G, B: nine floats, row-major. */
    val rows: FloatArray,
    /** Per-row constant: alpha coefficient + offset / 255. */
    val constant: FloatArray,
    val overlay: FloatArray,
    val overlayScreen: Boolean,
) {
    companion object {
        /**
         * Decodes the `colour` channel payload. Anything malformed is null — "no grade" — rather
         * than a wrong grade, because a wrong matrix is a green face on video nobody can undo.
         */
        fun fromMap(m: Map<*, *>?): BeautyColour? {
            if (m == null || m["on"] != true) return null
            val raw = m["matrix"] as? List<*> ?: return null
            if (raw.size != 20) return null
            val f = FloatArray(20)
            for (i in 0 until 20) {
                f[i] = (raw[i] as? Number)?.toFloat() ?: return null
            }
            val rows = floatArrayOf(
                f[0], f[1], f[2],
                f[5], f[6], f[7],
                f[10], f[11], f[12],
            )
            val constant = floatArrayOf(
                f[3] + f[4] / 255f,
                f[8] + f[9] / 255f,
                f[13] + f[14] / 255f,
            )
            val argb = (m["overlayArgb"] as? Number)?.toLong()?.toInt() ?: 0
            val overlay = floatArrayOf(
                ((argb shr 16) and 0xFF) / 255f,
                ((argb shr 8) and 0xFF) / 255f,
                (argb and 0xFF) / 255f,
                ((argb ushr 24) and 0xFF) / 255f,
            )
            return BeautyColour(rows, constant, overlay, m["overlayScreen"] == true)
        }
    }
}
