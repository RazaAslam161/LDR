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
import android.opengl.Matrix
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

/**
 * The GL half of the camera effect: one EGL context, one FBO, five intermediate textures, and
 * the passes that turn the camera's external texture into every output surface CameraX hands us.
 *
 * Per frame, when the effect is enabled:
 *   resolve   OES ──(SurfaceTexture matrix)──▶ texA        full res, the space every pass shares
 *   half      texA ──▶ texH0                                half res
 *   blur ×2   texH0 ⇄ texH1                                 separable Gaussian, twice
 *   mask      texH0 ──▶ texM0, then blur ⇄ texM1            skin × face geometry
 *   composite texA + texH0 + texM0 ──(CameraX matrix)──▶ each output
 *
 * When it is disabled, one pass: OES ──(full matrix)──▶ output, byte-for-byte the pre-fork path.
 *
 * Threading: everything here runs on the GL thread owned by [BeautySurfaceProcessor]. No locks,
 * because there is exactly one thread.
 */
internal class BeautyGlRenderer {

    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var context: EGLContext = EGL14.EGL_NO_CONTEXT
    private var config: EGLConfig? = null
    private var pbuffer: EGLSurface = EGL14.EGL_NO_SURFACE

    /** 2 or 3. ES 3 is asked for first, for its guaranteed fragment-uniform budget. */
    var glVersion = 0
        private set

    /** Whether the composite carries the landmark passes (reshape + makeup) or retouch only. */
    var fullVariant = false
        private set

    var inputTextureId = 0
        private set

    private class Program(val id: Int) {
        val aPosition = GLES20.glGetAttribLocation(id, "aPosition")
        val aTexCoord = GLES20.glGetAttribLocation(id, "aTexCoord")
        val uTexMatrix = GLES20.glGetUniformLocation(id, "uTexMatrix")
        private val locs = HashMap<String, Int>()
        fun loc(name: String): Int = locs.getOrPut(name) { GLES20.glGetUniformLocation(id, name) }
    }

    private var oes: Program? = null
    private var copy: Program? = null
    private var blur: Program? = null
    private var mask: Program? = null
    private var composite: Program? = null

    private var fbo = 0
    private var texA = 0
    private var texH0 = 0
    private var texH1 = 0
    private var texM0 = 0
    private var texM1 = 0
    private var bufW = 0
    private var bufH = 0

    private val identity = FloatArray(16).also { Matrix.setIdentityM(it, 0) }

    // Scratch for uniform uploads, allocated once.
    private val ellipse = FloatArray(5)
    private val eyeBoxes = FloatArray(4 * FaceFrame.EYES)
    private val lips = FloatArray(2 * FaceGeometry.POLY)
    private val lipsIn = FloatArray(2 * FaceGeometry.POLY)
    private val browL = FloatArray(2 * FaceGeometry.BROW)
    private val browR = FloatArray(2 * FaceGeometry.BROW)
    private val cheeks = FloatArray(4 * 2)
    private val ctl = FloatArray(4 * FaceFrame.CONTROLS)
    private val ctlR = FloatArray(FaceFrame.CONTROLS)
    private val eyeCtl = FloatArray(4 * FaceFrame.EYES)

    private val quad: FloatBuffer = floatBuffer(
        floatArrayOf(
            -1f, -1f, 0f, 0f,
            1f, -1f, 1f, 0f,
            -1f, 1f, 0f, 1f,
            1f, 1f, 1f, 1f,
        ),
    )

    class Output(val surface: EGLSurface, val width: Int, val height: Int, val matrix: FloatArray)

    /**
     * Brings EGL up and compiles every program.
     *
     * @return false when this device cannot run the effect. The caller must then leave the hook
     *   disarmed, and the camera binds exactly as it did before this feature existed.
     */
    fun setUp(): Boolean {
        try {
            display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
            if (display == EGL14.EGL_NO_DISPLAY) return fail("no EGL display")
            val version = IntArray(2)
            if (!EGL14.eglInitialize(display, version, 0, version, 1)) return fail("eglInitialize")

            if (!createContext(3) && !createContext(2)) return fail("no ES 3 or ES 2 context")

            pbuffer = EGL14.eglCreatePbufferSurface(
                display, config,
                intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0,
            )
            if (!EGL14.eglMakeCurrent(display, pbuffer, pbuffer, context)) return fail("eglMakeCurrent(pbuffer)")

            oes = build(BeautyShaders.OES) ?: return false
            copy = build(BeautyShaders.COPY) ?: return false
            blur = build(BeautyShaders.BLUR) ?: return false
            mask = build(BeautyShaders.MASK) ?: return fail("mask shader; this GPU cannot hold the polygon uniforms")

            val budget = IntArray(1)
            GLES20.glGetIntegerv(GLES20.GL_MAX_FRAGMENT_UNIFORM_VECTORS, budget, 0)
            // The FULL composite declares ~95 vec4 of uniforms. Below that budget the compile
            // may succeed on one driver and fail on another, so the choice is made on the number
            // rather than on luck.
            composite = if (budget[0] >= 128) build(BeautyShaders.FULL_DEFINE + BeautyShaders.COMPOSITE) else null
            fullVariant = composite != null
            if (composite == null) {
                composite = build(BeautyShaders.COMPOSITE) ?: return fail("composite shader (lite)")
            }
            for (p in listOf(composite!!)) {
                GLES20.glUseProgram(p.id)
                GLES20.glUniform1i(p.loc("uTexture"), 0)
                GLES20.glUniform1i(p.loc("uBlur"), 1)
                GLES20.glUniform1i(p.loc("uMask"), 2)
            }

            val ids = IntArray(1)
            GLES20.glGenFramebuffers(1, ids, 0)
            fbo = ids[0]
            inputTextureId = createTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES)
            Log.i(TAG, "GL up: ES$glVersion, ${GLES20.glGetString(GLES20.GL_RENDERER)}, " +
                "uniform budget ${budget[0]}, variant ${if (fullVariant) "full" else "lite"}")
            return true
        } catch (t: Throwable) {
            return fail("setUp threw: $t")
        }
    }

    private fun createContext(es: Int): Boolean {
        val renderable = if (es == 3) EGLExt.EGL_OPENGL_ES3_BIT_KHR else EGL14.EGL_OPENGL_ES2_BIT
        val attribs = intArrayOf(
            EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, renderable,
            // The surface that feeds MediaCodec during a recording needs this.
            EGL_RECORDABLE_ANDROID, 1,
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val n = IntArray(1)
        if (!EGL14.eglChooseConfig(display, attribs, 0, configs, 0, 1, n, 0) || n[0] == 0) return false
        val ctx = EGL14.eglCreateContext(
            display, configs[0], EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, es, EGL14.EGL_NONE), 0,
        )
        if (ctx == EGL14.EGL_NO_CONTEXT) return false
        config = configs[0]
        context = ctx
        glVersion = es
        return true
    }

    fun createWindowSurface(surface: Surface): EGLSurface? {
        return try {
            val s = EGL14.eglCreateWindowSurface(display, config, surface, intArrayOf(EGL14.EGL_NONE), 0)
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

    fun newInputSurfaceTexture(width: Int, height: Int): SurfaceTexture =
        SurfaceTexture(inputTextureId).apply { setDefaultBufferSize(width, height) }

    /** The pre-fork path: OES straight to the output through CameraX's full matrix. */
    fun drawPassThrough(target: Output, fullMatrix: FloatArray, presentationTimeNs: Long): Boolean {
        if (!EGL14.eglMakeCurrent(display, target.surface, target.surface, context)) {
            Log.e(TAG, "eglMakeCurrent(output) failed: ${EGL14.eglGetError()}")
            return false
        }
        GLES20.glViewport(0, 0, target.width, target.height)
        val p = oes!!
        GLES20.glUseProgram(p.id)
        bind(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, inputTextureId, 0)
        drawQuad(p, fullMatrix)
        EGLExt.eglPresentationTimeANDROID(display, target.surface, presentationTimeNs)
        return EGL14.eglSwapBuffers(display, target.surface)
    }

    /**
     * The whole pipeline for one frame.
     *
     * @param stMatrix the raw SurfaceTexture matrix — resolves the OES texture into texA's space.
     * @param face the geometry to use, which is the LAST face seen even while fading out.
     * @param faceAlpha 0..1 presence, so a lost track dims instead of popping.
     */
    fun render(
        inputW: Int,
        inputH: Int,
        stMatrix: FloatArray,
        face: FaceFrame?,
        faceAlpha: Float,
        p: BeautyParams,
        outputs: List<Output>,
        presentationTimeNs: Long,
    ): Boolean {
        if (!EGL14.eglMakeCurrent(display, pbuffer, pbuffer, context)) {
            Log.e(TAG, "eglMakeCurrent(pbuffer) failed: ${EGL14.eglGetError()}")
            return false
        }
        ensureBuffers(inputW, inputH)
        val hw = maxOf(1, inputW / 2)
        val hh = maxOf(1, inputH / 2)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo)

        // resolve
        attach(texA)
        GLES20.glViewport(0, 0, inputW, inputH)
        GLES20.glUseProgram(oes!!.id)
        bind(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, inputTextureId, 0)
        drawQuad(oes!!, stMatrix)

        // half
        attach(texH0)
        GLES20.glViewport(0, 0, hw, hh)
        GLES20.glUseProgram(copy!!.id)
        bind(GLES20.GL_TEXTURE_2D, texA, 0)
        drawQuad(copy!!, identity)

        // blur, twice
        val b = blur!!
        GLES20.glUseProgram(b.id)
        repeat(2) {
            attach(texH1)
            bind(GLES20.GL_TEXTURE_2D, texH0, 0)
            GLES20.glUniform2f(b.loc("uStep"), 1f / hw, 0f)
            drawQuad(b, identity)
            attach(texH0)
            bind(GLES20.GL_TEXTURE_2D, texH1, 0)
            GLES20.glUniform2f(b.loc("uStep"), 0f, 1f / hh)
            drawQuad(b, identity)
        }

        // mask
        val m = mask!!
        attach(texM0)
        GLES20.glUseProgram(m.id)
        bind(GLES20.GL_TEXTURE_2D, texH0, 0)
        val aspect = inputW.toFloat() / inputH.toFloat()
        GLES20.glUniform1f(m.loc("uAspect"), aspect)
        val fa = if (face == null) 0f else faceAlpha
        GLES20.glUniform1f(m.loc("uFaceAlpha"), fa)
        if (face != null) {
            face.skinEllipse(ellipse)
            face.eyeBoxes(eyeBoxes)
            face.gather(FaceGeometry.LIPS_OUTER, lips)
            GLES20.glUniform1f(m.loc("uFaceW"), face.faceWidth)
            GLES20.glUniform4f(m.loc("uEllipse"), ellipse[0], ellipse[1], ellipse[2], ellipse[3])
            GLES20.glUniform1f(m.loc("uRoll"), ellipse[4])
            GLES20.glUniform4fv(m.loc("uEyes"), FaceFrame.EYES, eyeBoxes, 0)
            GLES20.glUniform2fv(m.loc("uLips"), FaceGeometry.POLY, lips, 0)
        }
        drawQuad(m, identity)
        GLES20.glUseProgram(b.id)
        attach(texM1)
        bind(GLES20.GL_TEXTURE_2D, texM0, 0)
        GLES20.glUniform2f(b.loc("uStep"), 1f / hw, 0f)
        drawQuad(b, identity)
        attach(texM0)
        bind(GLES20.GL_TEXTURE_2D, texM1, 0)
        GLES20.glUniform2f(b.loc("uStep"), 0f, 1f / hh)
        drawQuad(b, identity)

        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)

        // composite, once per output
        val c = composite!!
        var ok = true
        for (o in outputs) {
            if (!EGL14.eglMakeCurrent(display, o.surface, o.surface, context)) {
                Log.e(TAG, "eglMakeCurrent(output) failed: ${EGL14.eglGetError()}")
                ok = false
                continue
            }
            GLES20.glViewport(0, 0, o.width, o.height)
            GLES20.glUseProgram(c.id)
            bind(GLES20.GL_TEXTURE_2D, texA, 0)
            bind(GLES20.GL_TEXTURE_2D, texH0, 1)
            bind(GLES20.GL_TEXTURE_2D, texM0, 2)
            GLES20.glUniform1f(c.loc("uAspect"), aspect)
            GLES20.glUniform1f(c.loc("uSmooth"), p.smooth)
            GLES20.glUniform1f(c.loc("uTone"), p.tone)
            GLES20.glUniform1f(c.loc("uBrighten"), p.brighten)
            GLES20.glUniform1f(c.loc("uDetail"), p.detail)
            GLES20.glUniform1f(c.loc("uFaceAlpha"), fa)
            if (fullVariant && face != null) uploadFace(c, face, p)
            drawQuad(c, o.matrix)
            EGLExt.eglPresentationTimeANDROID(display, o.surface, presentationTimeNs)
            if (!EGL14.eglSwapBuffers(display, o.surface)) ok = false
        }
        return ok
    }

    private fun uploadFace(c: Program, face: FaceFrame, p: BeautyParams) {
        face.warpControls(p, ctl, ctlR, eyeCtl)
        face.gather(FaceGeometry.LIPS_OUTER, lips)
        face.gather(FaceGeometry.LIPS_INNER, lipsIn)
        face.gather(FaceGeometry.LEFT_BROW, browL)
        face.gather(FaceGeometry.RIGHT_BROW, browR)
        face.cheeks(cheeks)
        face.eyeBoxes(eyeBoxes)
        GLES20.glUniform1f(c.loc("uFaceW"), face.faceWidth)
        GLES20.glUniform2f(c.loc("uFaceCenter"), face.centerX, face.centerY)
        GLES20.glUniform2f(c.loc("uUp"), face.upX, face.upY)
        GLES20.glUniform4fv(c.loc("uCtl"), FaceFrame.CONTROLS, ctl, 0)
        GLES20.glUniform1fv(c.loc("uCtlR"), FaceFrame.CONTROLS, ctlR, 0)
        GLES20.glUniform4fv(c.loc("uEyeCtl"), FaceFrame.EYES, eyeCtl, 0)
        GLES20.glUniform2fv(c.loc("uLips"), FaceGeometry.POLY, lips, 0)
        GLES20.glUniform2fv(c.loc("uLipsIn"), FaceGeometry.POLY, lipsIn, 0)
        GLES20.glUniform2fv(c.loc("uBrowL"), FaceGeometry.BROW, browL, 0)
        GLES20.glUniform2fv(c.loc("uBrowR"), FaceGeometry.BROW, browR, 0)
        GLES20.glUniform4fv(c.loc("uCheek"), 2, cheeks, 0)
        GLES20.glUniform4fv(c.loc("uEyeBox"), FaceFrame.EYES, eyeBoxes, 0)
        color(c, "uLipColor", p.lipsArgb)
        GLES20.glUniform1f(c.loc("uLipsAmount"), p.lipsAmount)
        color(c, "uBlushColor", p.blushArgb)
        GLES20.glUniform1f(c.loc("uBlushAmount"), p.blushAmount)
        color(c, "uBrowColor", p.browsArgb)
        GLES20.glUniform1f(c.loc("uBrowsAmount"), p.browsAmount)
        color(c, "uShadowColor", p.eyeshadowArgb)
        GLES20.glUniform1f(c.loc("uShadowAmount"), p.eyeshadowAmount)
    }

    private fun color(c: Program, name: String, argb: Int) {
        val rgb = argbToRgb(argb)
        GLES20.glUniform3f(c.loc(name), rgb[0], rgb[1], rgb[2])
    }

    fun release() {
        if (display == EGL14.EGL_NO_DISPLAY) return
        EGL14.eglMakeCurrent(display, pbuffer, pbuffer, context)
        for (p in listOf(oes, copy, blur, mask, composite)) p?.let { GLES20.glDeleteProgram(it.id) }
        val tex = intArrayOf(inputTextureId, texA, texH0, texH1, texM0, texM1)
        GLES20.glDeleteTextures(tex.size, tex, 0)
        if (fbo != 0) GLES20.glDeleteFramebuffers(1, intArrayOf(fbo), 0)
        EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
        if (pbuffer != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, pbuffer)
        if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context)
        EGL14.eglTerminate(display)
        display = EGL14.EGL_NO_DISPLAY
        context = EGL14.EGL_NO_CONTEXT
        pbuffer = EGL14.EGL_NO_SURFACE
        oes = null; copy = null; blur = null; mask = null; composite = null
        inputTextureId = 0; texA = 0; texH0 = 0; texH1 = 0; texM0 = 0; texM1 = 0; fbo = 0
        bufW = 0; bufH = 0
    }

    // ── internals ────────────────────────────────────────────────────────────────────────

    private fun ensureBuffers(w: Int, h: Int) {
        if (w == bufW && h == bufH) return
        val old = intArrayOf(texA, texH0, texH1, texM0, texM1)
        if (texA != 0) GLES20.glDeleteTextures(old.size, old, 0)
        val hw = maxOf(1, w / 2)
        val hh = maxOf(1, h / 2)
        texA = createTexture(GLES20.GL_TEXTURE_2D, w, h)
        texH0 = createTexture(GLES20.GL_TEXTURE_2D, hw, hh)
        texH1 = createTexture(GLES20.GL_TEXTURE_2D, hw, hh)
        texM0 = createTexture(GLES20.GL_TEXTURE_2D, hw, hh)
        texM1 = createTexture(GLES20.GL_TEXTURE_2D, hw, hh)
        bufW = w
        bufH = h
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo)
        attach(texA)
        val status = GLES20.glCheckFramebufferStatus(GLES20.GL_FRAMEBUFFER)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        if (status != GLES20.GL_FRAMEBUFFER_COMPLETE) {
            Log.e(TAG, "FBO incomplete for ${w}x$h: 0x${Integer.toHexString(status)}")
        }
    }

    private fun attach(tex: Int) {
        GLES20.glFramebufferTexture2D(
            GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0, GLES20.GL_TEXTURE_2D, tex, 0,
        )
    }

    private fun bind(target: Int, tex: Int, unit: Int) {
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0 + unit)
        GLES20.glBindTexture(target, tex)
    }

    private fun drawQuad(p: Program, texMatrix: FloatArray) {
        quad.position(0)
        GLES20.glVertexAttribPointer(p.aPosition, 2, GLES20.GL_FLOAT, false, STRIDE, quad)
        GLES20.glEnableVertexAttribArray(p.aPosition)
        quad.position(2)
        GLES20.glVertexAttribPointer(p.aTexCoord, 2, GLES20.GL_FLOAT, false, STRIDE, quad)
        GLES20.glEnableVertexAttribArray(p.aTexCoord)
        GLES20.glUniformMatrix4fv(p.uTexMatrix, 1, false, texMatrix, 0)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glDisableVertexAttribArray(p.aPosition)
        GLES20.glDisableVertexAttribArray(p.aTexCoord)
    }

    private fun build(fragment: String): Program? {
        val vs = compile(GLES20.GL_VERTEX_SHADER, BeautyShaders.VERTEX)
        val fs = compile(GLES20.GL_FRAGMENT_SHADER, fragment)
        if (vs == 0 || fs == 0) return null
        val id = GLES20.glCreateProgram()
        GLES20.glAttachShader(id, vs)
        GLES20.glAttachShader(id, fs)
        GLES20.glLinkProgram(id)
        GLES20.glDeleteShader(vs)
        GLES20.glDeleteShader(fs)
        val linked = IntArray(1)
        GLES20.glGetProgramiv(id, GLES20.GL_LINK_STATUS, linked, 0)
        if (linked[0] == 0) {
            Log.e(TAG, "link failed: ${GLES20.glGetProgramInfoLog(id)}")
            GLES20.glDeleteProgram(id)
            return null
        }
        return Program(id)
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

    private fun createTexture(target: Int, w: Int = 0, h: Int = 0): Int {
        val ids = IntArray(1)
        GLES20.glGenTextures(1, ids, 0)
        GLES20.glBindTexture(target, ids[0])
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        if (target == GLES20.GL_TEXTURE_2D) {
            GLES20.glTexImage2D(
                GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, w, h, 0,
                GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null,
            )
        }
        return ids[0]
    }

    private fun fail(why: String): Boolean {
        Log.e(TAG, "GL setup failed: $why")
        return false
    }

    private fun floatBuffer(values: FloatArray): FloatBuffer =
        ByteBuffer.allocateDirect(values.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
            .apply { put(values); position(0) }

    companion object {
        private const val TAG = "MilesBeautyGl"
        private const val STRIDE = 4 * 4

        /** Not in EGL14; the value is fixed by the Android EGL extension. */
        private const val EGL_RECORDABLE_ANDROID = 0x3142
    }
}
