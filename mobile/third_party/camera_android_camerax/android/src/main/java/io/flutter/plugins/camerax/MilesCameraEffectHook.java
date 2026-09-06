// Miles patch — this whole file is an addition, not upstream code.
//
// WHY THIS EXISTS
// camera_android_camerax binds through the varargs overload
// ProcessCameraProvider.bindToLifecycle(owner, selector, UseCase...), which has
// nowhere to attach an androidx.camera.core.CameraEffect. The retouch pipeline
// needs ONE effect targeting PREVIEW | VIDEO_CAPTURE | IMAGE_CAPTURE together,
// because that is what makes a captured photo and a recorded video carry the
// same pixels the viewfinder showed — by construction.
//
// WHY A STATIC HOLDER AND NOT A PIGEON API
// The Dart<->Java surface here is generated (camerax_library.g.dart, 8k lines;
// CameraXLibrary.g.kt, 7k). Exposing this through Pigeon means regenerating both,
// and a fork that carries regenerated codegen is a fork nobody can rebase.
//
// WHY io.flutter.plugins.camerax AND NOT com.miles.miles
// mobile/android/app/proguard-rules.pro keeps io.flutter.plugins.** { *; } and
// keeps nothing under com.miles.miles.**. R8 runs on the play flavour only.
//
// LIFECYCLE CONTRACT
// arm() BEFORE the camera binds; the fields are read once per bindToLifecycle.
// disarm() when the screen that armed it goes away. Opt-in per screen, never
// global: the heartbeat PPG reader drives the camera with startImageStream over
// a torch-lit fingertip, and an effect on that stream would corrupt the
// measurement it exists to take.

package io.flutter.plugins.camerax;

import androidx.annotation.Nullable;
import androidx.camera.core.Camera;
import androidx.camera.core.CameraEffect;
import androidx.camera.core.ImageAnalysis;
import java.util.concurrent.Executor;

/**
 * Process-wide holder for the one {@link CameraEffect} Miles may attach to the CameraX use-case
 * graph, the face analyzer that rides beside it, and the camera the patched bind produced.
 *
 * <p>Every field is {@code volatile}, written from the platform thread and read on the camera
 * binding thread. None is ever mutated in place.
 */
public final class MilesCameraEffectHook {
  private MilesCameraEffectHook() {}

  @Nullable private static volatile CameraEffect effect;
  @Nullable private static volatile ImageAnalysis analysis;
  @Nullable private static volatile ImageAnalysis.Analyzer analyzer;
  @Nullable private static volatile Executor analyzerExecutor;
  @Nullable private static volatile Camera boundCamera;
  private static volatile boolean analysisRefused;

  /**
   * Arms {@code e} so the next bind attaches it.
   *
   * @param a a use case of the effect's own, for a bind that carries no ImageAnalysis to ride
   * @param an the analyzer, attached to the PLUGIN's own ImageAnalysis when the bind has one —
   *     two ImageAnalysis use cases are two YUV streams, which most cameras refuse beside the
   *     shared PRIV and the JPEG
   */
  public static void arm(
      @Nullable CameraEffect e,
      @Nullable ImageAnalysis a,
      @Nullable ImageAnalysis.Analyzer an,
      @Nullable Executor ex) {
    effect = e;
    analysis = e == null ? null : a;
    analyzer = e == null ? null : an;
    analyzerExecutor = e == null ? null : ex;
    analysisRefused = false;
  }

  /** Removes the effect. The next bind takes the original, un-patched code path exactly. */
  public static void disarm() {
    effect = null;
    analysis = null;
    analyzer = null;
    analyzerExecutor = null;
    boundCamera = null;
    analysisRefused = false;
  }

  @Nullable
  public static CameraEffect effect() {
    return effect;
  }

  @Nullable
  public static ImageAnalysis analysis() {
    return analysis;
  }

  @Nullable
  public static ImageAnalysis.Analyzer analyzer() {
    return analyzer;
  }

  @Nullable
  public static Executor analyzerExecutor() {
    return analyzerExecutor;
  }

  public static boolean isArmed() {
    return effect != null;
  }

  /** The camera the patched bind produced, for the preview's rotation contract. */
  static void onBound(@Nullable Camera camera) {
    boundCamera = camera;
  }

  @Nullable
  public static Camera boundCamera() {
    return boundCamera;
  }

  /** The bind refused the analyzer beside the other use cases; retouch is colour-only. */
  public static void onAnalysisRefused() {
    analysisRefused = true;
  }

  public static boolean analysisRefused() {
    return analysisRefused;
  }
}
