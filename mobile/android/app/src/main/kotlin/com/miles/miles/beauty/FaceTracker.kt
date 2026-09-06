package com.miles.miles.beauty

import android.graphics.Matrix
import android.util.Log
import android.util.Size
import androidx.camera.core.ExperimentalGetImage
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.facemesh.FaceMesh
import com.google.mlkit.vision.facemesh.FaceMeshDetection
import com.google.mlkit.vision.facemesh.FaceMeshDetectorOptions
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Feeds ML Kit's face mesh and publishes one smoothed [FaceFrame] per result for a render
 * thread to read.
 *
 * Two feeds, one gate. The camera effect hands frames in through [analyzer] — riding the
 * plugin's own ImageAnalysis when the vendored bind finds one, or [analysis] when it does not —
 * and the call processor, which has no use case, asks [tryBegin] and then [analyzeNv21]. Either
 * way inference never queues: a frame that arrives while one is running is dropped, because
 * inference is slower than the camera and a queue only turns into lag.
 *
 * Coordinates: on the camera path the analysed buffer and the rendered buffer are DIFFERENT
 * crops of the sensor, so every point goes through CameraX's own sensor-to-buffer transforms —
 * the analysis frame's ([ImageProxy.getImageInfo]) and the effect input's ([setTarget]). On the
 * call path they are the same buffer and the plain aspect mapping is exact.
 *
 * Threading: the analyzer and every ML Kit callback run on [executor], one thread, so the 468
 * [OneEuroPoint] filters are touched by one thread only. [latest] is the only thing that crosses
 * to a renderer, and it is an immutable snapshot behind a volatile reference.
 */
internal class FaceTracker {

    private val executor = Executors.newSingleThreadExecutor { r -> Thread(r, "miles-beauty-face") }

    // FACE_MESH is the full 468-point mesh; BOUNDING_BOX_ONLY would be useless here.
    private val detector = FaceMeshDetection.getClient(
        FaceMeshDetectorOptions.Builder().setUseCase(FaceMeshDetectorOptions.FACE_MESH).build(),
    )

    private val filters = Array(FaceGeometry.POINT_COUNT) { OneEuroPoint(minCutoff = 1.2, beta = 0.02) }
    private val busy = AtomicBoolean(false)

    /** The newest smoothed face, or null when the last frame had none. */
    @Volatile
    var latest: FaceFrame? = null
        private set

    /** When a face was last seen, so a renderer can fade rather than pop. */
    @Volatile
    var lastSeenNs: Long = 0L
        private set

    /** The buffer the renderer draws into: its sensor-to-buffer transform and its size. */
    private class Target(val sensorToBuffer: FloatArray, val width: Int, val height: Int)

    @Volatile
    private var target: Target? = null

    @Volatile
    private var warnedDegenerate = false

    /**
     * Where the effect's input sits on the sensor, from `SurfaceRequest.TransformationInfo`.
     * Updated by CameraX whenever the crop changes (zoom), so landmarks stay on the face.
     */
    fun setTarget(sensorToBuffer: Matrix, width: Int, height: Int) {
        val v = FloatArray(9)
        sensorToBuffer.getValues(v)
        target = Target(v, width, height)
    }

    fun clearTarget() {
        target = null
    }

    /**
     * The analyzer itself, so the vendored bind can attach it to the plugin's OWN ImageAnalysis
     * instead of adding a second one. Two ImageAnalysis use cases are two YUV streams beside the
     * shared PRIV and the JPEG, and most cameras refuse that combination.
     */
    val analyzer: ImageAnalysis.Analyzer = ImageAnalysis.Analyzer { proxy -> analyze(proxy) }

    val analyzerExecutor: Executor
        get() = executor

    private var analysisOrNull: ImageAnalysis? = null

    /**
     * A use case of our own, for a bind that carries no ImageAnalysis to ride. Built on first
     * use so the call path never creates one.
     */
    val analysis: ImageAnalysis
        get() = analysisOrNull ?: ImageAnalysis.Builder()
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .setResolutionSelector(
                ResolutionSelector.Builder()
                    .setResolutionStrategy(
                        ResolutionStrategy(Size(640, 480), ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER),
                    )
                    .build(),
            )
            .build()
            .also {
                it.setAnalyzer(executor, analyzer)
                analysisOrNull = it
            }

    /** Forgets smoothing history. A new input surface, or a new capturer, is a different face. */
    fun reset() {
        executor.execute {
            for (f in filters) f.reset()
            latest = null
        }
    }

    fun release() {
        analysisOrNull?.clearAnalyzer()
        executor.execute { detector.close() }
        executor.shutdown()
    }

    /**
     * For a caller that supplies its own frames: claims the gate. Returns false while a frame is
     * in flight, and the caller must then skip this frame without converting anything.
     */
    fun tryBegin(): Boolean = busy.compareAndSet(false, true)

    /** Gives the gate back without a frame — the caller began and then could not deliver. */
    fun cancel() {
        busy.set(false)
    }

    /**
     * Runs inference on an NV21 frame after [tryBegin] succeeded. [nv21] is handed over; the
     * caller must not write to it until the next [tryBegin] succeeds. The analysed buffer is the
     * rendered buffer here, so no target transform applies.
     */
    fun analyzeNv21(nv21: ByteArray, width: Int, height: Int, rotation: Int, timestampNs: Long) {
        val upright = rotation % 180 != 0
        runDetector(
            InputImage.fromByteArray(nv21, width, height, rotation, InputImage.IMAGE_FORMAT_NV21),
            if (upright) height else width, if (upright) width else height, rotation,
            width, height, null, timestampNs,
        ) { }
    }

    @androidx.annotation.OptIn(ExperimentalGetImage::class)
    private fun analyze(proxy: ImageProxy) {
        if (!tryBegin()) {
            proxy.close()
            return
        }
        val media = proxy.image
        if (media == null) {
            proxy.close()
            cancel()
            return
        }
        val rotation = proxy.imageInfo.rotationDegrees
        // proxy.width/height are the sensor-orientation buffer; ML Kit answers in the upright
        // frame, whose dimensions swap for 90/270.
        val w = proxy.width
        val h = proxy.height
        val upright = rotation % 180 != 0
        val sensorToBuffer = FloatArray(9).also { proxy.imageInfo.sensorToBufferTransformMatrix.getValues(it) }
        runDetector(
            InputImage.fromMediaImage(media, rotation),
            if (upright) h else w, if (upright) w else h, rotation,
            w, h, sensorToBuffer, proxy.imageInfo.timestamp,
        ) { proxy.close() }
    }

    private fun runDetector(
        image: InputImage, uw: Int, uh: Int, rotation: Int,
        srcW: Int, srcH: Int, srcSensorToBuffer: FloatArray?, ts: Long,
        onDone: () -> Unit,
    ) {
        detector.process(image)
            .addOnSuccessListener(executor) { meshes ->
                publish(meshes, uw, uh, rotation, srcW, srcH, srcSensorToBuffer, ts)
            }
            .addOnFailureListener(executor) { e ->
                Log.e(TAG, "face mesh failed on frame @$ts", e)
                latest = null
            }
            .addOnCompleteListener(executor) {
                onDone()
                busy.set(false)
            }
    }

    private fun publish(
        meshes: List<FaceMesh>, uw: Int, uh: Int, rotation: Int,
        srcW: Int, srcH: Int, srcSensorToBuffer: FloatArray?, ts: Long,
    ) {
        // The largest face is the subject. A second face in frame is not retouched — deliberately:
        // a couple both in a selfie get one processed face and one honest one, and that is the
        // simpler, less surprising failure than two warps fighting over shared pixels.
        val mesh = meshes.maxByOrNull { it.boundingBox.width() * it.boundingBox.height() }
        val pts = mesh?.allPoints
        if (pts == null || pts.size < FaceGeometry.POINT_COUNT) {
            latest = null
            return
        }

        // analysis-buffer px → sensor → effect-buffer px, when both transforms are known.
        val tgt = target
        var toTarget: FloatArray? = null
        if (srcSensorToBuffer != null && tgt != null) {
            val inv = Affine.invert(srcSensorToBuffer)
            if (inv == null) {
                if (!warnedDegenerate) {
                    warnedDegenerate = true
                    Log.e(TAG, "analysis sensorToBuffer transform is singular; landmarks unmapped")
                }
            } else {
                toTarget = Affine.concat(tgt.sensorToBuffer, inv)
            }
        }
        val srcAspect = srcW.toFloat() / srcH.toFloat()
        val outAspect = if (toTarget != null && tgt != null) tgt.width.toFloat() / tgt.height.toFloat() else srcAspect

        val out = FloatArray(2 * FaceGeometry.POINT_COUNT)
        val vel = FloatArray(2 * FaceGeometry.POINT_COUNT)
        for (i in 0 until FaceGeometry.POINT_COUNT) {
            val p = pts[i].position
            val (x, y) = if (toTarget != null && tgt != null) {
                FaceGeometry.uprightToTarget(p.x / uw, p.y / uh, rotation, srcW, srcH, toTarget, tgt.width, tgt.height)
            } else {
                FaceGeometry.uprightToTexture(p.x / uw, p.y / uh, rotation, srcAspect)
            }
            val f = filters[i]
            f.filter(x, y, ts)
            out[2 * i] = f.x
            out[2 * i + 1] = f.y
            vel[2 * i] = f.vx
            vel[2 * i + 1] = f.vy
        }
        latest = FaceFrame(out, outAspect, ts, vel)
        lastSeenNs = ts
    }

    private companion object {
        const val TAG = "MilesBeautyFace"
    }
}
