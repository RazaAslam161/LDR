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
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The GL half of the retouch: one FBO, five intermediate textures, and the passes that turn a
 * camera's external texture into every consumer's pixels.
 *
 * Per frame, when the effect is enabled:
 *   resolve   OES ──(SurfaceTexture matrix)──▶ texA        full res, the space every pass shares
 *   half      texA ──▶ texH0                                half res
 *   blur ×2   texH0 ⇄ texH1                                 separable Gaussian, twice
 *   mask      texH0 ──▶ texM0, then blur ⇄ texM1            skin × face geometry
 *   composite texA + texH0 + texM0 ──(consumer matrix)──▶ output
 *
 * Two owners, one code path:
 *  - The camera effect calls [setUp]: this renderer creates its own EGL context on its own
 *    thread and composites into CameraX's output surfaces ([render]).
 *  - The call processor calls [attachToCurrentContext]: WebRTC's capturer thread already has a
 *    context current and the frame's OES texture lives in it, so the passes run there and the
 *    composite lands in a pooled texture ([renderToTexture]) that becomes the outgoing frame.
 *
 * Threading: every method except [releaseOutputTexture] runs on the owning GL thread. No locks,
 * because there is exactly one such thread per instance.
 */
internal class BeautyGlRenderer {

    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var context: EGLContext = EGL14.EGL_NO_CONTEXT
    private var config: EGLConfig? = null
    private var pbuffer: EGLSurface = EGL14.EGL_NO_SURFACE
    private var ownsContext = false

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
    private var guided: Program? = null
    private var composite: Program? = null

    private var fbo = 0
    private var texA = 0
    private var texH0 = 0
    private var texH1 = 0
    private var texM0 = 0
    private var texM1 = 0
    private var texG0 = 0
    private var texG1 = 0
    private var texG2 = 0
    private var texG3 = 0

    /** Guided-filter edge threshold. Below this local variance a region is skin and is
     *  flattened; above it the structure is an edge and survives. Driven by the smooth
     *  slider so "more smoothing" widens what counts as skin rather than just blending
     *  harder toward a blur — which is what made the old path go plastic. */
    private var guidedEps = 0.0016f

    /** |detail| below this is pore and hair texture and is restored; above uBlemishT it is a
     *  blemish and stays removed. Between them it fades. */
    private var poreT = 0.012f
    private var blemishT = 0.055f

    /** Coarse-scale edge threshold. Larger than the fine one: at this radius a cheek
     *  blotch is "flat" and should go, while the nose and jaw are still structure. */
    private var guidedEpsCoarse = 0.006f
    private var bufW = 0
    private var bufH = 0
    private var aspect = 1f

    /**
     * Output textures for the call path; the frame that wraps one frees it on any thread.
     *
     * A fixed array, never a growable list: slots are filled on the capturer thread while
     * [releaseOutputTexture] walks the same collection from whichever thread drops a frame, and a
     * growing ArrayList under a foreign iterator is a ConcurrentModificationException in the
     * first second of the first call. Each slot's [Pooled.busy] is the only shared state.
     */
    private class Pooled(var tex: Int, var w: Int, var h: Int) {
        val busy = AtomicBoolean(false)
    }
    private val pool = arrayOfNulls<Pooled>(POOL_SIZE)

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
    private val savedFbo = IntArray(1)
    private val savedViewport = IntArray(4)

    private val quad: FloatBuffer = floatBuffer(
        floatArrayOf(
            -1f, -1f, 0f, 0f,
            1f, -1f, 1f, 0f,
            -1f, 1f, 0f, 1f,
            1f, 1f, 1f, 1f,
        ),
    )

    class Output(val surface: EGLSurface, val width: Int, val height: Int, val matrix: FloatArray)

    // ── setup ───────────────────────────────────────────────────────────────────────────

    /**
     * Creates an EGL context of this renderer's own and compiles every program.
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
            ownsContext = true
            pbuffer = EGL14.eglCreatePbufferSurface(
                display, config,
                intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0,
            )
            if (!EGL14.eglMakeCurrent(display, pbuffer, pbuffer, context)) return fail("eglMakeCurrent(pbuffer)")
            return buildResources()
        } catch (t: Throwable) {
            return fail("setUp threw: $t")
        }
    }

    /**
     * Adopts the EGL context current on THIS thread instead of creating one. For the call path:
     * the capturer thread owns a context, the frame's texture lives in it, and a second context
     * could not sample that texture without share-group plumbing nobody needs.
     *
     * Everything built here dies with that context. [isCurrentContext] tells the owner when the
     * thread has moved to a new one — a camera flip re-creates the capturer — and a fresh
     * renderer must be attached.
     */
    fun attachToCurrentContext(): Boolean {
        try {
            display = EGL14.eglGetCurrentDisplay()
            context = EGL14.eglGetCurrentContext()
            if (display == EGL14.EGL_NO_DISPLAY || context == EGL14.EGL_NO_CONTEXT) {
                return fail("no EGL context is current on ${Thread.currentThread().name}")
            }
            ownsContext = false
            // ES 2 has no GL_MAJOR_VERSION; the version string is the portable answer.
            val v = GLES20.glGetString(GLES20.GL_VERSION) ?: ""
            glVersion = if (v.contains("OpenGL ES 3")) 3 else 2
            return buildResources()
        } catch (t: Throwable) {
            return fail("attach threw: $t")
        }
    }

    /** Whether the context this renderer's objects live in is the one current on this thread. */
    fun isCurrentContext(): Boolean =
        context != EGL14.EGL_NO_CONTEXT && context == EGL14.eglGetCurrentContext()

    private fun buildResources(): Boolean {
        oes = build(BeautyShaders.OES) ?: return false
        copy = build(BeautyShaders.COPY) ?: return false
        blur = build(BeautyShaders.BLUR) ?: return false
        mask = build(BeautyShaders.MASK) ?: return fail("mask shader; this GPU cannot hold the polygon uniforms")
        guided = build(BeautyShaders.GUIDED) ?: return fail("guided-filter shader")

        val budget = IntArray(1)
        GLES20.glGetIntegerv(GLES20.GL_MAX_FRAGMENT_UNIFORM_VECTORS, budget, 0)
        // The FULL composite declares ~95 vec4 of uniforms. Below that budget the compile may
        // succeed on one driver and fail on another, so the choice is made on the number rather
        // than on luck.
        composite = if (budget[0] >= 128) build(BeautyShaders.FULL_DEFINE + BeautyShaders.COMPOSITE) else null
        fullVariant = composite != null
        if (composite == null) {
            composite = build(BeautyShaders.COMPOSITE) ?: return fail("composite shader (lite)")
        }
        composite!!.let { p ->
            GLES20.glUseProgram(p.id)
            GLES20.glUniform1i(p.loc("uTexture"), 0)
            GLES20.glUniform1i(p.loc("uBlur"), 1)
            GLES20.glUniform1i(p.loc("uMask"), 2)
            GLES20.glUniform1i(p.loc("uGuide"), 3)
                GLES20.glUniform1i(p.loc("uGuideCoarse"), 4)
        }
        val ids = IntArray(1)
        GLES20.glGenFramebuffers(1, ids, 0)
        fbo = ids[0]
        inputTextureId = createTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES)
        // Fragment highp is what keeps the guided filter honest: var = E[Y2] - E[Y]2 is a
        // catastrophic cancellation and mediump (fp16) cannot hold it. Absent, the filter
        // degrades toward a = 0 everywhere, i.e. the flat look this replaced — no crash, but
        // worth being able to read off a log rather than guess at.
        val hpRange = IntArray(2)
        val hpBits = IntArray(1)
        GLES20.glGetShaderPrecisionFormat(
            GLES20.GL_FRAGMENT_SHADER, GLES20.GL_HIGH_FLOAT, hpRange, 0, hpBits, 0,
        )
        if (hpBits[0] < 16) {
            Log.w(TAG, "fragment highp is ${hpBits[0]}-bit; skin smoothing will be coarse")
        }
        Log.i(
            TAG,
            "GL up: ES$glVersion, ${GLES20.glGetString(GLES20.GL_RENDERER)}, uniform budget ${budget[0]}, " +
                "variant ${if (fullVariant) "full" else "lite"}, highp ${hpBits[0]}-bit, ${if (ownsContext) "own" else "adopted"} context",
        )
        return true
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

    // ── camera path ─────────────────────────────────────────────────────────────────────

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
     * The whole pipeline for one camera frame, composited into every CameraX output.
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
        colour: BeautyColour? = null,
    ): Boolean {
        if (!EGL14.eglMakeCurrent(display, pbuffer, pbuffer, context)) {
            Log.e(TAG, "eglMakeCurrent(pbuffer) failed: ${EGL14.eglGetError()}")
            return false
        }
        // eps is what "more smoothing" should widen: the band of local variance counted as
        // skin rather than edge. Cross-fading harder toward a blur instead is precisely how
        // the old path went plastic. Both engines set it here, so camera and call agree.
        guidedEps = 0.0008f + p.smooth * 0.0040f
        guidedEpsCoarse = 0.0030f + p.smooth * 0.0120f
        val fa = runPasses(inputTextureId, inputW, inputH, stMatrix, face, faceAlpha)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        var ok = true
        for (o in outputs) {
            if (!EGL14.eglMakeCurrent(display, o.surface, o.surface, context)) {
                Log.e(TAG, "eglMakeCurrent(output) failed: ${EGL14.eglGetError()}")
                ok = false
                continue
            }
            GLES20.glViewport(0, 0, o.width, o.height)
            drawComposite(o.matrix, face, fa, p, colour)
            EGLExt.eglPresentationTimeANDROID(display, o.surface, presentationTimeNs)
            if (!EGL14.eglSwapBuffers(display, o.surface)) ok = false
        }
        return ok
    }

    // ── call path ───────────────────────────────────────────────────────────────────────

    /**
     * The whole pipeline for one WebRTC frame, composited into a pooled texture in the caller's
     * own context. No surface is made current and none is swapped; the caller's framebuffer
     * binding and viewport are put back afterwards.
     *
     * @param inputOes the frame's OES texture id
     * @return the output texture id, or null when every pooled texture is still held by a frame
     *   downstream — the caller passes the original frame through, unprocessed, rather than
     *   stalling the capturer.
     */
    fun renderToTexture(
        inputOes: Int,
        w: Int,
        h: Int,
        stMatrix: FloatArray,
        face: FaceFrame?,
        faceAlpha: Float,
        p: BeautyParams,
        colour: BeautyColour? = null,
    ): Int? {
        val out = acquireOutput(w, h) ?: return null
        GLES20.glGetIntegerv(GLES20.GL_FRAMEBUFFER_BINDING, savedFbo, 0)
        GLES20.glGetIntegerv(GLES20.GL_VIEWPORT, savedViewport, 0)
        // eps is what "more smoothing" should widen: the band of local variance counted as
        // skin rather than edge. Cross-fading harder toward a blur instead is precisely how
        // the old path went plastic. Both engines set it here, so camera and call agree.
        guidedEps = 0.0008f + p.smooth * 0.0040f
        guidedEpsCoarse = 0.0030f + p.smooth * 0.0120f
        val fa = runPasses(inputOes, w, h, stMatrix, face, faceAlpha)
        attach(out.tex)
        GLES20.glViewport(0, 0, w, h)
        drawComposite(identity, face, fa, p, colour)
        // The encoder and the self-view sample this texture from OTHER contexts in WebRTC's share
        // group, and the GL spec guarantees they see a complete image only after the producer
        // finishes. glFinish, not glFlush: the consumers use no sync objects, so completion is the
        // only guarantee that holds. Without it the first frames after each toggle are black or
        // torn, on exactly the hardware that pipelines deepest.
        GLES20.glFinish()
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, savedFbo[0])
        GLES20.glViewport(savedViewport[0], savedViewport[1], savedViewport[2], savedViewport[3])
        return out.tex
    }

    /** Frees a texture from [renderToTexture]. Called from whatever thread releases the frame. */
    fun releaseOutputTexture(tex: Int) {
        for (e in pool) if (e != null && e.tex == tex) e.busy.set(false)
    }

    private fun acquireOutput(w: Int, h: Int): Pooled? {
        for (i in pool.indices) {
            val e = pool[i]
            if (e == null) {
                val fresh = Pooled(createTexture(GLES20.GL_TEXTURE_2D, w, h), w, h)
                fresh.busy.set(true)
                pool[i] = fresh
                return fresh
            }
            if (e.busy.compareAndSet(false, true)) {
                if (e.w != w || e.h != h) {
                    GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, e.tex)
                    GLES20.glTexImage2D(
                        GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, w, h, 0,
                        GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null,
                    )
                    e.w = w
                    e.h = h
                }
                return e
            }
        }
        return null
    }

    // ── the passes ──────────────────────────────────────────────────────────────────────

    /** resolve → half → blur → mask → mask blur. Leaves the FBO bound. Returns the alpha used. */
    private fun runPasses(inputOes: Int, inputW: Int, inputH: Int, stMatrix: FloatArray, face: FaceFrame?, faceAlpha: Float): Float {
        ensureBuffers(inputW, inputH)
        val hw = maxOf(1, inputW / 2)
        val hh = maxOf(1, inputH / 2)
        val qw = maxOf(1, inputW / 4)
        val qh = maxOf(1, inputH / 4)
        aspect = inputW.toFloat() / inputH.toFloat()
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo)

        attach(texA)
        GLES20.glViewport(0, 0, inputW, inputH)
        GLES20.glUseProgram(oes!!.id)
        bind(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, inputOes, 0)
        drawQuad(oes!!, stMatrix)

        attach(texH0)
        GLES20.glViewport(0, 0, hw, hh)
        GLES20.glUseProgram(copy!!.id)
        bind(GLES20.GL_TEXTURE_2D, texA, 0)
        drawQuad(copy!!, identity)

        // Guided-filter coefficients, measured on the SHARP half — before the blur below
        // overwrites texH0 — because local variance is the whole signal and a smeared input
        // has none.
        val g = guided!!
        attach(texG0)
        GLES20.glUseProgram(g.id)
        bind(GLES20.GL_TEXTURE_2D, texH0, 0)
        GLES20.glUniform2f(g.loc("uTexel"), 1f / hw, 1f / hh)
        GLES20.glUniform1f(g.loc("uEps"), guidedEps)
        drawQuad(g, identity)

        val b = blur!!
        GLES20.glUseProgram(b.id)

        // Box-smooth (a, b): the guided filter's own averaging step, and what widens the
        // support from a 5x5 patch to roughly a blemish. The existing blur does it — a and b
        // ride the r and g channels.
        attach(texG1)
        bind(GLES20.GL_TEXTURE_2D, texG0, 0)
        GLES20.glUniform2f(b.loc("uStep"), 1f / hw, 0f)
        drawQuad(b, identity)
        attach(texG0)
        bind(GLES20.GL_TEXTURE_2D, texG1, 0)
        GLES20.glUniform2f(b.loc("uStep"), 0f, 1f / hh)
        drawQuad(b, identity)

        // ── the COARSE scale ────────────────────────────────────────────────────────────
        // A second guided model at quarter res with wider taps and a larger eps. At this
        // radius a cheek blotch reads as flat and is removed, while the nose, jaw and
        // hairline are still structure and survive. One scale could never do both: the
        // radius that evens a blotch also erases the pores, and the radius that keeps pores
        // cannot see a blotch at all.
        GLES20.glUseProgram(g.id)
        attach(texG2)
        GLES20.glViewport(0, 0, qw, qh)
        bind(GLES20.GL_TEXTURE_2D, texH0, 0)
        GLES20.glUniform2f(g.loc("uTexel"), 1f / qw, 1f / qh)
        GLES20.glUniform1f(g.loc("uEps"), guidedEpsCoarse)
        drawQuad(g, identity)

        GLES20.glUseProgram(b.id)
        attach(texG3)
        bind(GLES20.GL_TEXTURE_2D, texG2, 0)
        GLES20.glUniform2f(b.loc("uStep"), 1f / qw, 0f)
        drawQuad(b, identity)
        attach(texG2)
        bind(GLES20.GL_TEXTURE_2D, texG3, 0)
        GLES20.glUniform2f(b.loc("uStep"), 0f, 1f / qh)
        drawQuad(b, identity)

        // Back to half res for the mask work below.
        GLES20.glViewport(0, 0, hw, hh)
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

        val m = mask!!
        attach(texM0)
        GLES20.glUseProgram(m.id)
        bind(GLES20.GL_TEXTURE_2D, texH0, 0)
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
        return fa
    }

    private fun drawComposite(matrix: FloatArray, face: FaceFrame?, fa: Float, p: BeautyParams, colour: BeautyColour?) {
        val c = composite!!
        GLES20.glUseProgram(c.id)
        bind(GLES20.GL_TEXTURE_2D, texA, 0)
        bind(GLES20.GL_TEXTURE_2D, texH0, 1)
        bind(GLES20.GL_TEXTURE_2D, texM0, 2)
        bind(GLES20.GL_TEXTURE_2D, texG0, 3)
        bind(GLES20.GL_TEXTURE_2D, texG2, 4)
        GLES20.glUniform1f(c.loc("uAspect"), aspect)
        GLES20.glUniform1f(c.loc("uSmooth"), p.smooth)
        GLES20.glUniform1f(c.loc("uTone"), p.tone)
        GLES20.glUniform1f(c.loc("uBrighten"), p.brighten)
        GLES20.glUniform1f(c.loc("uDetail"), p.detail)
        GLES20.glUniform1f(c.loc("uPoreT"), poreT)
        GLES20.glUniform1f(c.loc("uBlemishT"), blemishT)
        // How much of the blotch band survives. 1.0 would put the uneven tone straight back;
        // 0.0 flattens it completely and reads as a mask. Stronger looks keep less of it.
        GLES20.glUniform1f(c.loc("uEvenness"), 0.45f - 0.30f * p.smooth)
        GLES20.glUniform1f(c.loc("uFaceAlpha"), fa)
        if (fullVariant && face != null) uploadFace(c, face, p)
        if (colour == null) {
            GLES20.glUniform1f(c.loc("uColorOn"), 0f)
        } else {
            GLES20.glUniform1f(c.loc("uColorOn"), 1f)
            GLES20.glUniform3fv(c.loc("uColorR"), 1, colour.rows, 0)
            GLES20.glUniform3fv(c.loc("uColorG"), 1, colour.rows, 3)
            GLES20.glUniform3fv(c.loc("uColorB"), 1, colour.rows, 6)
            GLES20.glUniform3fv(c.loc("uColorV"), 1, colour.constant, 0)
            GLES20.glUniform4fv(c.loc("uOverlay"), 1, colour.overlay, 0)
            GLES20.glUniform1f(c.loc("uOverlayScreen"), if (colour.overlayScreen) 1f else 0f)
        }
        drawQuad(c, matrix)
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

    // ── teardown ────────────────────────────────────────────────────────────────────────

    /**
     * Frees everything. For an owned context, tears EGL down too.
     *
     * For an adopted one the objects belong to WebRTC's SHARE GROUP, not to the context they
     * were made in: a capturer's context dies with its SurfaceTextureHelper, but the root context
     * outlives every call, and so do these until deleted. Any context of the group can delete
     * them, so the requirement is that SOME context is current on this thread — which is the
     * case on the capturer thread that replaces this renderer after a flip or a new call. With
     * no context current (the platform thread at shutdown) they are dropped by reference only,
     * once per process, which is the bounded leak this design accepts.
     */
    fun release() {
        val live = if (ownsContext) {
            display != EGL14.EGL_NO_DISPLAY && EGL14.eglMakeCurrent(display, pbuffer, pbuffer, context)
        } else {
            EGL14.eglGetCurrentContext() != EGL14.EGL_NO_CONTEXT
        }
        if (live) {
            for (p in listOf(oes, copy, blur, mask, guided, composite)) p?.let { GLES20.glDeleteProgram(it.id) }
            val tex = intArrayOf(inputTextureId, texA, texH0, texH1, texM0, texM1, texG0, texG1, texG2, texG3) + pool.filterNotNull().map { it.tex }.toIntArray()
            GLES20.glDeleteTextures(tex.size, tex, 0)
            if (fbo != 0) GLES20.glDeleteFramebuffers(1, intArrayOf(fbo), 0)
        }
        if (ownsContext && display != EGL14.EGL_NO_DISPLAY) {
            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            if (pbuffer != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, pbuffer)
            if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context)
            EGL14.eglTerminate(display)
        }
        display = EGL14.EGL_NO_DISPLAY
        context = EGL14.EGL_NO_CONTEXT
        pbuffer = EGL14.EGL_NO_SURFACE
        ownsContext = false
        oes = null; copy = null; blur = null; mask = null; guided = null; composite = null
        inputTextureId = 0; texA = 0; texH0 = 0; texH1 = 0; texM0 = 0; texM1 = 0; texG0 = 0; texG1 = 0; texG2 = 0; texG3 = 0; fbo = 0
        bufW = 0; bufH = 0
        pool.fill(null)
    }

    // ── internals ────────────────────────────────────────────────────────────────────────

    private fun ensureBuffers(w: Int, h: Int) {
        if (w == bufW && h == bufH) return
        val old = intArrayOf(texA, texH0, texH1, texM0, texM1, texG0, texG1, texG2, texG3)
        if (texA != 0) GLES20.glDeleteTextures(old.size, old, 0)
        val hw = maxOf(1, w / 2)
        val hh = maxOf(1, h / 2)
        val qw = maxOf(1, w / 4)
        val qh = maxOf(1, h / 4)
        texA = createTexture(GLES20.GL_TEXTURE_2D, w, h)
        texH0 = createTexture(GLES20.GL_TEXTURE_2D, hw, hh)
        texH1 = createTexture(GLES20.GL_TEXTURE_2D, hw, hh)
        texM0 = createTexture(GLES20.GL_TEXTURE_2D, hw, hh)
        texM1 = createTexture(GLES20.GL_TEXTURE_2D, hw, hh)
        texG0 = createTexture(GLES20.GL_TEXTURE_2D, hw, hh)
        texG1 = createTexture(GLES20.GL_TEXTURE_2D, hw, hh)
        // Quarter res for the coarse scale: a wider support for a quarter of the fill, and the
        // coefficients are smooth by construction so there is nothing to lose by it.
        texG2 = createTexture(GLES20.GL_TEXTURE_2D, qw, qh)
        texG3 = createTexture(GLES20.GL_TEXTURE_2D, qw, qh)
        bufW = w
        bufH = h
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo)
        attach(texA)
        val status = GLES20.glCheckFramebufferStatus(GLES20.GL_FRAMEBUFFER)
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

        /**
         * Three output textures for the call path: one being drawn, one held by the encoder, one
         * held by the local preview. A fourth would only hide a consumer that stopped releasing.
         */
        /**
         * How many outgoing frames may be in flight at once. The encoder queue plus the self-view
         * plus the adaptation stage can hold four or five between them when the encoder lags, and
         * an exhausted pool passes the RAW frame through — a visible flicker to the far end. Six
         * 720p RGBA textures is ~22MB of GPU memory, which is the cheaper failure.
         */
        private const val POOL_SIZE = 6
    }
}
