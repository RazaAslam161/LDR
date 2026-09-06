package com.miles.miles.beauty

import android.graphics.SurfaceTexture
import android.opengl.EGLSurface
import android.opengl.Matrix
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import androidx.camera.core.CameraEffect
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.SurfaceOutput
import androidx.camera.core.SurfaceProcessor
import androidx.camera.core.SurfaceRequest
import androidx.core.util.Consumer
import java.util.concurrent.Executor

/**
 * The Miles camera effect: one GPU pass between the sensor and every consumer.
 *
 * Targets [CameraEffect.PREVIEW] | [CameraEffect.VIDEO_CAPTURE] | [CameraEffect.IMAGE_CAPTURE]
 * together, so the viewfinder, the saved JPEG and the recorded MP4 are one processor's output.
 * That makes "what you see is what you get" a property of the graph rather than a promise two
 * implementations have to keep — which is the state today, where the still is re-processed on
 * the CPU in camera_bake.dart and video is not processed at all.
 *
 * DO NOT switch this to `OUTPUT_OPTION_ONE_FOR_EACH_TARGET`. The 4-argument constructor keeps
 * CameraEffect's default `ONE_FOR_ALL_TARGETS`, which routes the still through
 * `DefaultSurfaceProcessor` — the only implementation whose `snapshot()` works. Under
 * ONE_FOR_EACH_TARGET the still goes through `SurfaceProcessorWithExecutor`, whose `snapshot()`
 * is an unconditional failed future, and `takePicture()` breaks on every device. A law test
 * (test/unit/camera/beauty_effect_law_test.dart) pins this.
 */
class BeautyEffect private constructor(
    executor: Executor,
    private val processor: BeautySurfaceProcessor,
) : CameraEffect(
    PREVIEW or VIDEO_CAPTURE or IMAGE_CAPTURE,
    executor,
    processor,
    Consumer { t -> processor.onEffectError(t) },
) {
    /** A use case of our own, for a bind that carries no ImageAnalysis to ride. */
    val analysis: ImageAnalysis get() = processor.tracker.analysis

    /** The analyzer itself, so the vendored bind can attach it to the plugin's own ImageAnalysis. */
    val analyzer: ImageAnalysis.Analyzer get() = processor.tracker.analyzer
    val analyzerExecutor: Executor get() = processor.tracker.analyzerExecutor

    /** Takes effect on the next frame; no rebind needed. */
    internal fun setParams(p: BeautyParams) {
        processor.params = p
    }

    /** The camera's colour preset for the composite's last step, or null for none. Next frame. */
    internal fun setColour(c: BeautyColour?) {
        processor.colour = c
    }

    /** Releases the GL thread, the context and the detector. Safe to call twice. */
    fun release() = processor.release()

    companion object {
        /**
         * Builds an effect, or returns null when this device cannot run it.
         *
         * Null is not an error to apologise for — it is the designed fallback. The caller leaves
         * [io.flutter.plugins.camerax.MilesCameraEffectHook] disarmed, CameraX binds through the
         * original varargs call, and the camera behaves exactly as it did before this feature.
         */
        @JvmStatic
        fun createOrNull(): BeautyEffect? {
            val processor = BeautySurfaceProcessor()
            if (!processor.start()) {
                processor.release()
                return null
            }
            return BeautyEffect(processor.glExecutor, processor)
        }
    }
}

/**
 * Drives the GL thread: takes the camera's input surface, paints it into each output surface
 * CameraX asks for, and pulls the newest face from [tracker] for every frame.
 *
 * Every method that touches GL is posted to [glHandler]; nothing here is synchronised because
 * exactly one thread ever runs it. [params] is the one exception — written from the platform
 * thread, read once per frame — and it is a volatile reference to an immutable value.
 */
internal class BeautySurfaceProcessor : SurfaceProcessor {

    private val glThread = HandlerThread("miles-beauty-gl")
    private lateinit var glHandler: Handler
    private val renderer = BeautyGlRenderer()
    val tracker = FaceTracker()

    @Volatile
    var params: BeautyParams = BeautyParams.OFF

    @Volatile
    var colour: BeautyColour? = null

    private class OutputState(val egl: EGLSurface, val width: Int, val height: Int) {
        val glOnly = FloatArray(16)
        val full = FloatArray(16)
    }

    private val outputs = LinkedHashMap<SurfaceOutput, OutputState>()

    private var inputTexture: SurfaceTexture? = null
    private var inputSurface: Surface? = null
    private var inputWidth = 0
    private var inputHeight = 0
    private var released = false

    private val stMatrix = FloatArray(16)
    private val identity = FloatArray(16).also { Matrix.setIdentityM(it, 0) }
    private val renderOutputs = ArrayList<BeautyGlRenderer.Output>(2)

    private val presence = FacePresence()

    /** Executor CameraX uses for the effect's callbacks — the GL thread itself. */
    val glExecutor: Executor = Executor { r -> glHandler.post(r) }

    fun start(): Boolean {
        glThread.start()
        glHandler = Handler(glThread.looper)
        return runOnGlBlocking { renderer.setUp() }
    }

    override fun onInputSurface(request: SurfaceRequest) {
        glHandler.post {
            if (released) {
                request.willNotProvideSurface()
                return@post
            }
            inputWidth = request.resolution.width
            inputHeight = request.resolution.height
            // Where this input sits on the sensor. The analysis stream is a different crop of the
            // same sensor, and composing the two transforms is the only exact way to put its
            // landmarks on this texture. CameraX re-sends it when the crop changes (zoom).
            request.setTransformationInfoListener(glExecutor) { info ->
                tracker.setTarget(info.sensorToBufferTransform, inputWidth, inputHeight)
            }
            // A new input surface is a new bind — a flip, a resume — and therefore a different
            // face in a different space. Smoothing history from the old one must not bleed in.
            tracker.reset()
            presence.reset()

            val texture = renderer.newInputSurfaceTexture(inputWidth, inputHeight)
            texture.setOnFrameAvailableListener({ onFrameAvailable(it) }, glHandler)
            val surface = Surface(texture)
            inputTexture = texture
            inputSurface = surface
            request.provideSurface(surface, glExecutor) { _ ->
                texture.setOnFrameAvailableListener(null)
                surface.release()
                texture.release()
                if (inputSurface === surface) {
                    inputSurface = null
                    inputTexture = null
                }
            }
        }
    }

    override fun onOutputSurface(output: SurfaceOutput) {
        glHandler.post {
            if (released) {
                output.close()
                return@post
            }
            val surface = output.getSurface(glExecutor) { event ->
                if (event.eventCode == SurfaceOutput.Event.EVENT_REQUEST_CLOSE) {
                    glHandler.post { detach(output) }
                }
            }
            val egl = renderer.createWindowSurface(surface)
            if (egl == null) {
                output.close()
                return@post
            }
            outputs[output] = OutputState(egl, output.size.width, output.size.height)
        }
    }

    private fun onFrameAvailable(texture: SurfaceTexture) {
        if (released) return
        try {
            texture.updateTexImage()
        } catch (t: Throwable) {
            Log.e(TAG, "updateTexImage failed", t)
            return
        }
        if (outputs.isEmpty()) return
        texture.getTransformMatrix(stMatrix)
        val ts = texture.timestamp
        val p = params

        if (!p.enabled) {
            for ((output, state) in outputs) {
                output.updateTransformMatrix(state.full, stMatrix)
                renderer.drawPassThrough(
                    BeautyGlRenderer.Output(state.egl, state.width, state.height, state.full),
                    state.full,
                    ts,
                )
            }
            presence.idle(ts)
            return
        }

        val fa = presence.update(tracker.latest, tracker.lastSeenNs, ts)

        renderOutputs.clear()
        for ((output, state) in outputs) {
            // Passing identity yields CameraX's own crop/rotate/mirror alone; the SurfaceTexture
            // half of the transform was already applied by the resolve pass.
            output.updateTransformMatrix(state.glOnly, identity)
            renderOutputs.add(BeautyGlRenderer.Output(state.egl, state.width, state.height, state.glOnly))
        }
        renderer.render(inputWidth, inputHeight, stMatrix, presence.lastFace?.predicted(ts), fa, p, renderOutputs, ts, colour)
    }

    private fun detach(output: SurfaceOutput) {
        outputs.remove(output)?.let { renderer.destroyWindowSurface(it.egl) }
        output.close()
    }

    fun onEffectError(t: Throwable) {
        Log.e(TAG, "CameraEffect error", t)
    }

    fun release() {
        if (released) return
        released = true
        tracker.release()
        if (!glThread.isAlive) return
        runOnGlBlocking {
            for ((output, state) in outputs) {
                renderer.destroyWindowSurface(state.egl)
                output.close()
            }
            outputs.clear()
            inputTexture?.setOnFrameAvailableListener(null)
            renderer.release()
            true
        }
        glThread.quitSafely()
    }

    /**
     * Runs [block] on the GL thread and waits. Correct here and only here: setup and teardown
     * must complete before the caller decides anything. The per-frame path never blocks.
     */
    private fun runOnGlBlocking(block: () -> Boolean): Boolean {
        var result = false
        val done = Object()
        var finished = false
        glHandler.post {
            result = try {
                block()
            } catch (t: Throwable) {
                Log.e(TAG, "GL work threw", t)
                false
            }
            synchronized(done) {
                finished = true
                done.notifyAll()
            }
        }
        synchronized(done) {
            val deadline = System.currentTimeMillis() + GL_TIMEOUT_MS
            while (!finished) {
                val remaining = deadline - System.currentTimeMillis()
                if (remaining <= 0) {
                    Log.e(TAG, "GL work timed out after ${GL_TIMEOUT_MS}ms")
                    return false
                }
                try {
                    done.wait(remaining)
                } catch (e: InterruptedException) {
                    Thread.currentThread().interrupt()
                    return false
                }
            }
        }
        return result
    }

    private companion object {
        const val TAG = "MilesBeautyGl"
        const val GL_TIMEOUT_MS = 4000L
    }
}
