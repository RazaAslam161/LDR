package com.miles.miles.beauty

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

/**
 * The GL half of the camera effect. Owns one EGL context and draws the camera's external (OES)
 * texture into every output surface CameraX hands us.
 *
 * At this stage it is a deliberate PASS-THROUGH: one draw, transform matrix applied, nothing else.
 * That is the point — it proves the whole `StreamSharing` route (preview + still + video off one
 * processor) works on real hardware before a single line of beauty code exists. The beauty passes
 * land on top of [drawFrame] later.
 *
 * Threading: every method here must run on the GL thread owned by [BeautySurfaceProcessor]. No
 * locking, because there is exactly one thread.
 *
 * Shader language is `#version 100` on purpose. Sampling `samplerExternalOES` from ESSL 3.00 needs
 * `GL_OES_EGL_image_external_essl3`, which is common but NOT guaranteed on every ES 3.0 device;
 * ESSL 1.00 needs only `GL_OES_EGL_image_external`, which is universal. An ES 3.0 context compiles
 * ESSL 1.00 fine, so this costs nothing and removes a device-reach gamble.
 */
internal class BeautyGlRenderer {

    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var context: EGLContext = EGL14.EGL_NO_CONTEXT
    private var config: EGLConfig? = null

    private var program = 0
    private var aPosition = 0
    private var aTexCoord = 0
    private var uTexMatrix = 0
    private var uTexture = 0

    /** The OES texture the camera writes into. */
    var inputTextureId = 0
        private set

    private val quad: FloatBuffer = floatBuffer(
        // x, y, u, v — a full-screen triangle strip.
        floatArrayOf(
            -1f, -1f, 0f, 0f,
            1f, -1f, 1f, 0f,
            -1f, 1f, 0f, 1f,
            1f, 1f, 1f, 1f,
        ),
    )

    /**
     * Creates the EGL context and compiles the program.
     *
     * @return true on success. On failure the caller must NOT arm the effect — the designed
     *   fallback is that the camera binds without it and behaves exactly as it did before.
     */
    fun setUp(): Boolean {
        try {
            display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
            if (display == EGL14.EGL_NO_DISPLAY) return fail("no EGL display")
            val version = IntArray(2)
            if (!EGL14.eglInitialize(display, version, 0, version, 1)) return fail("eglInitialize")

            val attribs = intArrayOf(
                EGL14.EGL_RED_SIZE, 8,
                EGL14.EGL_GREEN_SIZE, 8,
                EGL14.EGL_BLUE_SIZE, 8,
                EGL14.EGL_ALPHA_SIZE, 8,
                EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                // Required for the surface that feeds MediaCodec during recording.
                EGL_RECORDABLE_ANDROID, 1,
                EGL14.EGL_NONE,
            )
            val configs = arrayOfNulls<EGLConfig>(1)
            val numConfigs = IntArray(1)
            if (!EGL14.eglChooseConfig(display, attribs, 0, configs, 0, 1, numConfigs, 0) ||
                numConfigs[0] == 0
            ) {
                return fail("eglChooseConfig")
            }
            config = configs[0]

            context = EGL14.eglCreateContext(
                display,
                config,
                EGL14.EGL_NO_CONTEXT,
                intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE),
                0,
            )
            if (context == EGL14.EGL_NO_CONTEXT) return fail("eglCreateContext")

            // A 1x1 pbuffer so the context can be made current before any output surface exists.
            // Programs and textures are created here and outlive every output.
            val pbuffer = EGL14.eglCreatePbufferSurface(
                display,
                config,
                intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE),
                0,
            )
            if (!EGL14.eglMakeCurrent(display, pbuffer, pbuffer, context)) {
                return fail("eglMakeCurrent(pbuffer)")
            }

            if (!buildProgram()) return false
            inputTextureId = createOesTexture()
            Log.i(TAG, "GL up: ${GLES20.glGetString(GLES20.GL_VERSION)}")
            return true
        } catch (t: Throwable) {
            return fail("setUp threw: $t")
        }
    }

    /** Wraps [surface] in an EGL window surface. Returns null if the surface is unusable. */
    fun createWindowSurface(surface: Surface): EGLSurface? {
        return try {
            val s = EGL14.eglCreateWindowSurface(
                display,
                config,
                surface,
                intArrayOf(EGL14.EGL_NONE),
                0,
            )
            if (s == EGL14.EGL_NO_SURFACE) {
                Log.e(TAG, "eglCreateWindowSurface failed: ${EGL14.eglGetError()}")
                null
            } else {
                s
            }
        } catch (t: Throwable) {
            Log.e(TAG, "eglCreateWindowSurface threw", t)
            null
        }
    }

    fun destroyWindowSurface(surface: EGLSurface) {
        EGL14.eglDestroySurface(display, surface)
    }

    /**
     * Draws the current camera frame into [target].
     *
     * [texMatrix] is the matrix CameraX produced via `SurfaceOutput.updateTransformMatrix`, NOT the
     * raw `SurfaceTexture` matrix — CameraX folds crop, rotation and mirroring into it per output,
     * which is why this class never does orientation maths of its own.
     *
     * @param presentationTimeNs the frame's own timestamp. Omitting it makes a recorded MP4's
     *   timestamps wrong and playback stutter, so it is passed explicitly rather than defaulted.
     */
    fun drawFrame(
        target: EGLSurface,
        width: Int,
        height: Int,
        texMatrix: FloatArray,
        presentationTimeNs: Long,
    ): Boolean {
        if (!EGL14.eglMakeCurrent(display, target, target, context)) {
            Log.e(TAG, "eglMakeCurrent(output) failed: ${EGL14.eglGetError()}")
            return false
        }
        GLES20.glViewport(0, 0, width, height)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

        GLES20.glUseProgram(program)

        quad.position(0)
        GLES20.glVertexAttribPointer(aPosition, 2, GLES20.GL_FLOAT, false, STRIDE, quad)
        GLES20.glEnableVertexAttribArray(aPosition)
        quad.position(2)
        GLES20.glVertexAttribPointer(aTexCoord, 2, GLES20.GL_FLOAT, false, STRIDE, quad)
        GLES20.glEnableVertexAttribArray(aTexCoord)

        GLES20.glUniformMatrix4fv(uTexMatrix, 1, false, texMatrix, 0)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, inputTextureId)
        GLES20.glUniform1i(uTexture, 0)

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

        GLES20.glDisableVertexAttribArray(aPosition)
        GLES20.glDisableVertexAttribArray(aTexCoord)

        EGLExt.eglPresentationTimeANDROID(display, target, presentationTimeNs)
        return EGL14.eglSwapBuffers(display, target)
    }

    fun release() {
        if (display == EGL14.EGL_NO_DISPLAY) return
        EGL14.eglMakeCurrent(
            display,
            EGL14.EGL_NO_SURFACE,
            EGL14.EGL_NO_SURFACE,
            EGL14.EGL_NO_CONTEXT,
        )
        if (program != 0) GLES20.glDeleteProgram(program)
        if (inputTextureId != 0) GLES20.glDeleteTextures(1, intArrayOf(inputTextureId), 0)
        if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context)
        EGL14.eglTerminate(display)
        display = EGL14.EGL_NO_DISPLAY
        context = EGL14.EGL_NO_CONTEXT
        program = 0
        inputTextureId = 0
    }

    private fun buildProgram(): Boolean {
        val vs = compile(GLES20.GL_VERTEX_SHADER, VERTEX_SHADER)
        val fs = compile(GLES20.GL_FRAGMENT_SHADER, FRAGMENT_SHADER)
        if (vs == 0 || fs == 0) return fail("shader compile")
        program = GLES20.glCreateProgram()
        GLES20.glAttachShader(program, vs)
        GLES20.glAttachShader(program, fs)
        GLES20.glLinkProgram(program)
        val linked = IntArray(1)
        GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, linked, 0)
        if (linked[0] == 0) {
            val log = GLES20.glGetProgramInfoLog(program)
            GLES20.glDeleteProgram(program)
            program = 0
            return fail("link: $log")
        }
        // The shaders are linked into the program; the objects themselves are no longer needed.
        GLES20.glDeleteShader(vs)
        GLES20.glDeleteShader(fs)

        aPosition = GLES20.glGetAttribLocation(program, "aPosition")
        aTexCoord = GLES20.glGetAttribLocation(program, "aTexCoord")
        uTexMatrix = GLES20.glGetUniformLocation(program, "uTexMatrix")
        uTexture = GLES20.glGetUniformLocation(program, "uTexture")
        return true
    }

    private fun compile(type: Int, source: String): Int {
        val id = GLES20.glCreateShader(type)
        GLES20.glShaderSource(id, source)
        GLES20.glCompileShader(id)
        val ok = IntArray(1)
        GLES20.glGetShaderiv(id, GLES20.GL_COMPILE_STATUS, ok, 0)
        if (ok[0] == 0) {
            Log.e(TAG, "shader compile failed: ${GLES20.glGetShaderInfoLog(id)}")
            GLES20.glDeleteShader(id)
            return 0
        }
        return id
    }

    private fun createOesTexture(): Int {
        val ids = IntArray(1)
        GLES20.glGenTextures(1, ids, 0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, ids[0])
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_MIN_FILTER,
            GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_MAG_FILTER,
            GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_WRAP_S,
            GLES20.GL_CLAMP_TO_EDGE,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_WRAP_T,
            GLES20.GL_CLAMP_TO_EDGE,
        )
        return ids[0]
    }

    private fun fail(why: String): Boolean {
        Log.e(TAG, "GL setup failed: $why")
        return false
    }

    private fun floatBuffer(values: FloatArray): FloatBuffer =
        ByteBuffer.allocateDirect(values.size * 4)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
            .apply {
                put(values)
                position(0)
            }

    companion object {
        private const val TAG = "MilesBeautyGl"
        private const val STRIDE = 4 * 4

        /** Not in EGL14; the value is fixed by the Android EGL extension. */
        private const val EGL_RECORDABLE_ANDROID = 0x3142

        private const val VERTEX_SHADER = """
            attribute vec4 aPosition;
            attribute vec4 aTexCoord;
            uniform mat4 uTexMatrix;
            varying vec2 vTexCoord;
            void main() {
                gl_Position = aPosition;
                vTexCoord = (uTexMatrix * aTexCoord).xy;
            }
        """

        private const val FRAGMENT_SHADER = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vTexCoord;
            uniform samplerExternalOES uTexture;
            void main() {
                gl_FragColor = texture2D(uTexture, vTexCoord);
            }
        """
    }
}

/** Convenience for the processor: a [SurfaceTexture] bound to the renderer's OES texture. */
internal fun BeautyGlRenderer.newInputSurfaceTexture(width: Int, height: Int): SurfaceTexture =
    SurfaceTexture(inputTextureId).apply { setDefaultBufferSize(width, height) }
