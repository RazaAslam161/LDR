package com.miles.miles.beauty

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
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Feeds ML Kit's face mesh from an [ImageAnalysis] stream and publishes one smoothed [FaceFrame]
 * per result for the GL thread to read.
 *
 * Threading: the analyzer and every ML Kit callback run on [executor], a single thread, so the
 * 468 [OneEuroPoint] filters are touched by one thread only. [latest] is the only thing that
 * crosses to the renderer, and it is an immutable snapshot behind a volatile reference.
 *
 * Backpressure is the whole design: KEEP_ONLY_LATEST plus a [busy] gate means a frame that
 * arrives while inference is running is closed immediately, unprocessed. Inference is slower
 * than the camera, so without that gate frames queue, latency climbs, and the mesh lags the face
 * by more every second the app is open.
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

    /** When a face was last seen, so the renderer can fade rather than pop. */
    @Volatile
    var lastSeenNs: Long = 0L
        private set

    /**
     * The use case the vendored bind attaches beside preview/capture/video. Small on purpose:
     * ML Kit's mesh is accurate at VGA and the cost is the inference, not the pixels.
     */
    val analysis: ImageAnalysis = ImageAnalysis.Builder()
        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
        .setResolutionSelector(
            ResolutionSelector.Builder()
                .setResolutionStrategy(
                    ResolutionStrategy(Size(640, 480), ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER),
                )
                .build(),
        )
        .build()
        .also { it.setAnalyzer(executor) { proxy -> analyze(proxy) } }

    /** Forgets smoothing history. Called on every new input surface — a flip is a different face. */
    fun reset() {
        executor.execute {
            for (f in filters) f.reset()
            latest = null
        }
    }

    fun release() {
        analysis.clearAnalyzer()
        executor.execute { detector.close() }
        executor.shutdown()
    }

    @androidx.annotation.OptIn(ExperimentalGetImage::class)
    private fun analyze(proxy: ImageProxy) {
        if (!busy.compareAndSet(false, true)) {
            proxy.close()
            return
        }
        val media = proxy.image
        if (media == null) {
            proxy.close()
            busy.set(false)
            return
        }
        val rotation = proxy.imageInfo.rotationDegrees
        val timestamp = proxy.imageInfo.timestamp
        // proxy.width/height are the sensor-orientation buffer; ML Kit answers in the upright
        // frame, whose dimensions swap for 90/270.
        val w = proxy.width
        val h = proxy.height
        val upright = rotation % 180 != 0
        val uw = if (upright) h else w
        val uh = if (upright) w else h
        val aspect = w.toFloat() / h.toFloat()

        detector.process(InputImage.fromMediaImage(media, rotation))
            .addOnSuccessListener(executor) { meshes -> publish(meshes, uw, uh, rotation, aspect, timestamp) }
            .addOnFailureListener(executor) { e ->
                Log.e(TAG, "face mesh failed on frame @$timestamp", e)
                latest = null
            }
            .addOnCompleteListener(executor) {
                proxy.close()
                busy.set(false)
            }
    }

    private fun publish(meshes: List<FaceMesh>, uw: Int, uh: Int, rotation: Int, aspect: Float, ts: Long) {
        // The largest face is the subject. A second face in frame is not retouched — deliberately:
        // a couple both in a selfie get one processed face and one honest one, and that is the
        // simpler, less surprising failure than two warps fighting over shared pixels.
        val mesh = meshes.maxByOrNull { it.boundingBox.width() * it.boundingBox.height() }
        val pts = mesh?.allPoints
        if (pts == null || pts.size < FaceGeometry.POINT_COUNT) {
            latest = null
            return
        }
        val out = FloatArray(2 * FaceGeometry.POINT_COUNT)
        for (i in 0 until FaceGeometry.POINT_COUNT) {
            val p = pts[i].position
            val (x, y) = FaceGeometry.uprightToTexture(p.x / uw, p.y / uh, rotation, aspect)
            val f = filters[i]
            f.filter(x, y, ts)
            out[2 * i] = f.x
            out[2 * i + 1] = f.y
        }
        latest = FaceFrame(out, aspect, ts)
        lastSeenNs = ts
    }

    private companion object {
        const val TAG = "MilesBeautyFace"
    }
}
