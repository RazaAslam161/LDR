package com.miles.miles.beauty

/**
 * The numbers the engine receives. Mirrors `BeautySettings.toChannelMap()` in Dart key for key —
 * a law test on the Dart side pins that the two never drift.
 *
 * Everything here is already multiplied by the master amount in Dart; this class holds no policy
 * and applies no clamping beyond what keeps a shader sane.
 */
internal data class BeautyParams(
    val enabled: Boolean,
    val smooth: Float,
    val tone: Float,
    val brighten: Float,
    val detail: Float,
    val jaw: Float,
    val chin: Float,
    val eyes: Float,
    val nose: Float,
    val lipsArgb: Int,
    val lipsAmount: Float,
    val blushArgb: Int,
    val blushAmount: Float,
    val browsArgb: Int,
    val browsAmount: Float,
    val eyeshadowArgb: Int,
    val eyeshadowAmount: Float,
) {
    /** Whether any pass needs landmarks at all; without one the tracker's frames are ignored. */
    val needsFace: Boolean
        get() = jaw != 0f || chin != 0f || eyes != 0f || nose != 0f ||
            lipsAmount > 0f || blushAmount > 0f || browsAmount > 0f || eyeshadowAmount > 0f

    companion object {
        val OFF = BeautyParams(
            enabled = false,
            smooth = 0f, tone = 0f, brighten = 0f, detail = 0.5f,
            jaw = 0f, chin = 0f, eyes = 0f, nose = 0f,
            lipsArgb = 0, lipsAmount = 0f,
            blushArgb = 0, blushAmount = 0f,
            browsArgb = 0, browsAmount = 0f,
            eyeshadowArgb = 0, eyeshadowAmount = 0f,
        )

        /**
         * Decodes the channel payload. Absent or mistyped keys fall back to OFF's value for that
         * key rather than throwing — a payload from a newer Dart build must never crash an older
         * native side, and the reverse.
         */
        fun fromMap(m: Map<*, *>?): BeautyParams {
            if (m == null || m["enabled"] != true) return OFF
            fun f(k: String, fallback: Float, lo: Float = 0f, hi: Float = 1f): Float {
                val v = m[k] as? Number ?: return fallback
                return v.toFloat().coerceIn(lo, hi)
            }
            // Dart ints above 2^31 cross the channel as int64, so a full-alpha ARGB arrives as a
            // Long; toLong().toInt() recovers the signed 32-bit colour exactly.
            fun argb(k: String): Int = (m[k] as? Number)?.toLong()?.toInt() ?: 0
            return BeautyParams(
                enabled = true,
                smooth = f("smooth", 0f),
                tone = f("tone", 0f),
                brighten = f("brighten", 0f),
                detail = f("detail", 0.5f),
                jaw = f("jaw", 0f, -1f, 1f),
                chin = f("chin", 0f, -1f, 1f),
                eyes = f("eyes", 0f, -1f, 1f),
                nose = f("nose", 0f, -1f, 1f),
                lipsArgb = argb("lipsArgb"),
                lipsAmount = f("lipsAmount", 0f),
                blushArgb = argb("blushArgb"),
                blushAmount = f("blushAmount", 0f),
                browsArgb = argb("browsArgb"),
                browsAmount = f("browsAmount", 0f),
                eyeshadowArgb = argb("eyeshadowArgb"),
                eyeshadowAmount = f("eyeshadowAmount", 0f),
            )
        }
    }
}

/** (r, g, b) in 0..1 from a packed ARGB int. */
internal fun argbToRgb(argb: Int): FloatArray = floatArrayOf(
    ((argb shr 16) and 0xFF) / 255f,
    ((argb shr 8) and 0xFF) / 255f,
    (argb and 0xFF) / 255f,
)
