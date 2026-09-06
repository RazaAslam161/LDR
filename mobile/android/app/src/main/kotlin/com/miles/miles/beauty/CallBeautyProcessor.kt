package com.miles.miles.beauty

import android.graphics.Matrix
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.cloudwebrtc.webrtc.video.LocalVideoTrack
import org.webrtc.RendererCommon
import org.webrtc.TextureBufferImpl
import org.webrtc.VideoFrame
import org.webrtc.YuvConverter

/**
 * The retouch on the OUTGOING call video: the same passes as the camera effect, run on WebRTC's
 * capturer thread, on the frame's own texture, in the context that owns it.
 *
 * Registered through the vendored plugin's MilesVideoProcessorHook, which attaches it to every
 * camera track (never screen capture). Each frame in becomes a new frame out, wrapping a pooled
 * texture; the plugin's patched LocalVideoTrack releases that frame after the sink has taken it,
 * and the release returns the texture to the pool.
 *
 * Everything degrades to "the original frame, untouched": a non-texture buffer, a GL attach
 * failure, an exhausted pool. Nothing here throws into the capturer.
 *
 * Threading: [onFrame] runs on the capturer thread, always the same one for a given capturer,
 * with its EGL context current. A camera flip creates a NEW capturer and thread, which is why
 * the renderer is checked against the current context on every frame and re-attached when it
 * has moved. [params] is written from the platform thread and read once per frame.
 */
internal class CallBeautyProcessor : LocalVideoTrack.ExternalVideoFrameProcessing {

    @Volatile
    var params: BeautyParams = BeautyParams.OFF
        set(value) {
            field = value
            logFirstFrame = true
        }

    /** The colour preset the call's look picked, or null. Next frame, no rebind. */
    @Volatile
    var colour: BeautyColour? = null

    // One line per arm saying what the first frame looked like. Every early return in
    // onFrame is silent by design (it runs per frame); this is the one place the log says
    // whether frames arrive at all and whether params were enabled when they did.
    @Volatile
    private var logFirstFrame = true

    @Volatile
    private var released = false

    private val tracker = FaceTracker()
    private val presence = FacePresence()

    private var renderer: BeautyGlRenderer? = null
    private var yuv: YuvConverter? = null
    private var handler: Handler? = null

    private var nv21: ByteArray? = null
    private var lastWarnNs = 0L

    override fun onFrame(frame: VideoFrame): VideoFrame {
        val p = params
        val ts = frame.timestampNs
        if (logFirstFrame) {
            logFirstFrame = false
            Log.i(TAG, "first frame after arm: enabled=${p.enabled} needsFace=${p.needsFace} " +
                "buffer=${frame.buffer.javaClass.simpleName} ${frame.buffer.width}x${frame.buffer.height} " +
                "rot=${frame.rotation} released=$released")
        }
        if (!p.enabled || released) {
            presence.idle(ts)
            return frame
        }
        val buf = frame.buffer as? VideoFrame.TextureBuffer
        if (buf == null || buf.type != VideoFrame.TextureBuffer.Type.OES) {
            warn(ts, "frame is not an OES texture (${frame.buffer.javaClass.simpleName}); passing through")
            presence.idle(ts)
            return frame
        }
        val r = ensureRenderer() ?: run {
            presence.idle(ts)
            return frame
        }
        val w = buf.width
        val h = buf.height

        if (p.needsFace && tracker.tryBegin()) feed(buf, frame.rotation, ts)
        val fa = presence.update(tracker.latest, tracker.lastSeenNs, ts)

        val st = RendererCommon.convertMatrixFromAndroidGraphicsMatrix(buf.transformMatrix)
        val tex = r.renderToTexture(buf.textureId, w, h, st, presence.lastFace?.predicted(ts), fa, p, colour)
        if (tex == null) {
            warn(ts, "output pool exhausted; a consumer is holding frames — passing through")
            return frame
        }
        // Identity transform: the composite already resolved the capturer's matrix, so this
        // texture is upright in the standard texture orientation. Rotation rides along
        // unchanged — the pixels are still in sensor orientation, as every pass expects.
        val out = GuardedTexture(
            TextureBufferImpl(
                w, h, VideoFrame.TextureBuffer.Type.RGB, tex, Matrix(), handler!!, yuv!!,
                Runnable { r.releaseOutputTexture(tex) },
            ),
            handler!!,
        )
        return VideoFrame(out, frame.rotation, ts)
    }

    /**
     * Hands a small copy of the frame to the tracker. toI420 on a texture is a GPU readback, and
     * reading 720p on every frame is the difference between a warm phone and a hot one, so the
     * frame is scaled to ~VGA first and only when the tracker is actually free.
     */
    private fun feed(buf: VideoFrame.TextureBuffer, rotation: Int, ts: Long) {
        val w = buf.width
        val h = buf.height
        val scale = ANALYSIS_LONG_EDGE.toFloat() / maxOf(w, h)
        val sw = if (scale >= 1f) w else ((w * scale).toInt() and 1.inv())
        val sh = if (scale >= 1f) h else ((h * scale).toInt() and 1.inv())
        val small = buf.cropAndScale(0, 0, w, h, sw, sh)
        val i420 = try {
            small.toI420()
        } finally {
            small.release()
        }
        if (i420 == null) {
            tracker.cancel()
            return
        }
        try {
            val size = nv21Size(sw, sh)
            val bytes = nv21?.takeIf { it.size == size } ?: ByteArray(size).also { nv21 = it }
            packNv21(
                i420.dataY, i420.strideY, i420.dataU, i420.strideU, i420.dataV, i420.strideV,
                sw, sh, bytes,
            )
            tracker.analyzeNv21(bytes, sw, sh, rotation, ts)
        } catch (t: Throwable) {
            Log.e(TAG, "packing frame for the tracker failed", t)
            tracker.cancel()
        } finally {
            i420.release()
        }
    }

    private fun ensureRenderer(): BeautyGlRenderer? {
        renderer?.let { if (it.isCurrentContext()) return it }
        // First frame, or a new capturer thread with a new context after a flip or a new call.
        // The old renderer's objects live in WebRTC's share group, not in the dead context, and
        // this thread's new context is in that group — so release() deletes them here. The
        // converter holds GL objects of its own and must go the same way.
        renderer?.release()
        renderer = null
        yuv?.release()
        yuv = null
        val r = BeautyGlRenderer()
        if (!r.attachToCurrentContext()) {
            warn(System.nanoTime(), "GL attach failed on ${Thread.currentThread().name}; calls unretouched")
            return null
        }
        renderer = r
        yuv = YuvConverter()
        handler = Handler(Looper.myLooper() ?: Looper.getMainLooper())
        presence.reset()
        tracker.reset()
        return r
    }

    /** Detached from every track by the hook before this is called. */
    fun release() {
        released = true
        tracker.release()
    }

    /** Once per second at most: a per-frame log line would be its own performance problem. */
    private fun warn(nowNs: Long, msg: String) {
        if (nowNs - lastWarnNs < 1_000_000_000L) return
        lastWarnNs = nowNs
        Log.w(TAG, msg)
    }

    private companion object {
        const val TAG = "MilesBeautyCall"
        const val ANALYSIS_LONG_EDGE = 640
    }
}

/**
 * A texture buffer whose `toI420` cannot hang the encoder.
 *
 * `TextureBufferImpl.toI420` hops to the capturer's looper and waits without bound. A frame from
 * here can still be sitting in the encoder queue after that looper has quit — the capturer is
 * torn down on hang-up and on every flip — and then the encoder thread waits forever and
 * `pc.dispose()` ANRs behind it. Bounded here, and null on timeout or a dead looper: null is the
 * documented "conversion failed" answer, and the native encoder drops that one frame.
 * `cropAndScale` wraps its result so a scaled copy carries the same guard.
 */
private class GuardedTexture(
    private val inner: VideoFrame.TextureBuffer,
    private val looperHandler: Handler,
) : VideoFrame.TextureBuffer by inner {

    override fun toI420(): VideoFrame.I420Buffer? {
        if (looperHandler.looper.thread === Thread.currentThread()) return inner.toI420()
        var result: VideoFrame.I420Buffer? = null
        val done = java.util.concurrent.CountDownLatch(1)
        inner.retain()
        val posted = looperHandler.post {
            try {
                result = inner.toI420()
            } finally {
                inner.release()
                done.countDown()
            }
        }
        if (!posted) {
            inner.release()
            Log.w("MilesBeautyCall", "toI420 refused: capturer looper is gone; frame dropped")
            return null
        }
        if (!done.await(TO_I420_TIMEOUT_MS, java.util.concurrent.TimeUnit.MILLISECONDS)) {
            Log.w("MilesBeautyCall", "toI420 timed out after ${TO_I420_TIMEOUT_MS}ms; frame dropped")
            return null
        }
        return result
    }

    override fun cropAndScale(cx: Int, cy: Int, cw: Int, ch: Int, sw: Int, sh: Int): VideoFrame.Buffer {
        val scaled = inner.cropAndScale(cx, cy, cw, ch, sw, sh)
        return if (scaled is VideoFrame.TextureBuffer) GuardedTexture(scaled, looperHandler) else scaled
    }

    private companion object {
        const val TO_I420_TIMEOUT_MS = 500L
    }
}
