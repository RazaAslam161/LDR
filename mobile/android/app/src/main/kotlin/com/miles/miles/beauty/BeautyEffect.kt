package com.miles.miles.beauty

import android.graphics.SurfaceTexture
import android.opengl.EGLSurface
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import androidx.camera.core.CameraEffect
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
 * That is what makes "what you see is what you get" a property of the graph instead of a promise
 * two implementations have to keep — which is the state today, where the still is re-processed on
 * the CPU in camera_bake.dart and video is not processed at all.
 *
 * DO NOT switch this to `OUTPUT_OPTION_ONE_FOR_EACH_TARGET`. The 4-argument constructor used here
 * keeps CameraEffect's default `ONE_FOR_ALL_TARGETS`, which routes the still through
 * `DefaultSurfaceProcessor` — the only implementation whose `snapshot()` works. Under
 * ONE_FOR_EACH_TARGET the still goes through `SurfaceProcessorWithExecutor`, whose `snapshot()` is
 * an unconditional failed future, and `takePicture()` breaks on every device. A law test
 * (test/unit/camera/beauty_effect_law_test.dart) pins this.
 */
class BeautyEffect private constructor(
    executor: Executor,
    processor: BeautySurfaceProcessor,
) : CameraEffect(
    PREVIEW or VIDEO_CAPTURE or IMAGE_CAPTURE,
    executor,
    processor,
    Consumer { t -> processor.onEffectError(t) },
) {

    private val processor: BeautySurfaceProcessor = processor

    /** Releases the GL thread and context. Safe to call twice. */
    fun release() = processor.release()

    companion object {
        /**
         * Builds an effect, or returns null when this device cannot run it.
         *
         * A null return is not an error path to apologise for — it is the designed fallback. The
         * caller leaves [io.flutter.plugins.camerax.MilesCameraEffectHook] disarmed, CameraX binds
         * through the original varargs call, and the camera behaves exactly as it did before this
         * feature existed.
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
 * Drives the GL thread: takes the camera's input surface, and paints it into each output surface
 * CameraX asks for.
 *
 * Every method that touches GL is posted to [glHandler]; nothing here is synchronised because
 * exactly one thread ever runs it.
 */
internal class BeautySurfaceProcessor : SurfaceProcessor {

    private val glThread = HandlerThread("miles-beauty-gl")
    private lateinit var glHandler: Handler
    private val renderer = BeautyGlRenderer()

    /** Outputs currently attached, keyed by the SurfaceOutput CameraX gave us. */
    private val outputs = mutableMapOf<SurfaceOutput, EGLSurface>()

    private var inputTexture: SurfaceTexture? = null
    private var inputSurface: Surface? = null
    private var inputWidth = 0
    private var inputHeight = 0
    private var released = false

    private val texMatrix = FloatArray(16)
    private val outMatrix = FloatArray(16)

    /** Executor CameraX uses for the effect's callbacks — the GL thread itself. */
    val glExecutor: Executor = Executor { r -> glHandler.post(r) }

    /**
     * Starts the GL thread and builds the context.
     *
     * @return false if GL is unusable on this device, in which case the effect must not be armed.
     */
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
            val size = request.resolution
            inputWidth = size.width
            inputHeight = size.height

            val texture = renderer.newInputSurfaceTexture(inputWidth, inputHeight)
            texture.setOnFrameAvailableListener({ onFrameAvailable(it) }, glHandler)
            val surface = Surface(texture)
            inputTexture = texture
            inputSurface = surface

            request.provideSurface(surface, glExecutor) { _ ->
                // CameraX is done with this surface (camera closed, flipped, or reconfigured).
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
            val eglSurface = renderer.createWindowSurface(surface)
            if (eglSurface == null) {
                // Nothing to draw into. Close it rather than holding a dead entry; CameraX will
                // request a new one if the stream reconfigures.
                output.close()
                return@post
            }
            outputs[output] = eglSurface
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
        texture.getTransformMatrix(texMatrix)
        val timestamp = texture.timestamp

        for ((output, eglSurface) in outputs) {
            // CameraX folds each target's own crop, rotation and mirroring into this matrix, which
            // is why the renderer never does orientation maths itself.
            output.updateTransformMatrix(outMatrix, texMatrix)
            renderer.drawFrame(eglSurface, inputWidth, inputHeight, outMatrix, timestamp)
        }
    }

    private fun detach(output: SurfaceOutput) {
        outputs.remove(output)?.let { renderer.destroyWindowSurface(it) }
        output.close()
    }

    /** CameraX reports an effect-level failure here. */
    fun onEffectError(t: Throwable) {
        Log.e(TAG, "CameraEffect error", t)
    }

    fun release() {
        if (released) return
        released = true
        if (!glThread.isAlive) return
        runOnGlBlocking {
            for ((output, eglSurface) in outputs) {
                renderer.destroyWindowSurface(eglSurface)
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
     * Runs [block] on the GL thread and waits for it.
     *
     * Blocking is correct here and only here: setup and teardown must complete before the caller
     * decides whether to arm the effect, and before the thread dies. The per-frame path never
     * blocks.
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
