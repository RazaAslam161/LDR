// Miles patch — this whole file is an addition, not upstream code.
//
// WHY THIS EXISTS
// camera_android_camerax binds through the varargs overload
// ProcessCameraProvider.bindToLifecycle(owner, selector, UseCase...), which has
// nowhere to attach an androidx.camera.core.CameraEffect. The retouch pipeline
// needs ONE effect targeting PREVIEW | VIDEO_CAPTURE | IMAGE_CAPTURE together,
// because that is what makes a captured photo and a recorded video carry the
// same pixels the viewfinder showed — by construction, rather than by two
// implementations agreeing to stay in sync. (Today they do NOT: the still is
// re-processed on the CPU in camera_bake.dart and video is not processed at
// all, so a filtered recording has never actually been filtered.)
//
// WHY A STATIC HOLDER AND NOT A PIGEON API
// The Dart<->Java surface here is generated: camerax_library.g.dart is 8,324
// lines and CameraXLibrary.g.kt is 7,771. Exposing an effect through Pigeon
// means regenerating both, and a fork that carries regenerated codegen is a
// fork nobody can rebase. This holder keeps the patch to one new file plus a
// ~15-line hunk in a 93-line file, and keeps every line that will actually
// change during development in :app, outside the fork entirely.
//
// WHY io.flutter.plugins.camerax AND NOT com.miles.miles
// mobile/android/app/proguard-rules.pro keeps io.flutter.plugins.** { *; }.
// Nothing keeps com.miles.miles.**. R8 runs on the play flavour only, which is
// the build real users install and the one no local test exercises, so a class
// reached across the module boundary lives where it is already kept.
//
// LIFECYCLE CONTRACT
// arm() must be called BEFORE the camera binds; the effect is read once per
// bindToLifecycle. disarm() must be called when the screen that armed it goes
// away. The effect is opt-in per screen and never global on purpose: the
// heartbeat PPG reader (lib/features/heartbeat/heartbeat_screen.dart) drives
// the camera with startImageStream over a torch-lit fingertip, and beautifying
// that stream would corrupt the measurement it exists to take.

package io.flutter.plugins.camerax;

import androidx.annotation.Nullable;
import androidx.camera.core.CameraEffect;

/**
 * Process-wide holder for the one {@link CameraEffect} Miles may attach to the CameraX use-case
 * graph, plus the {@code ImageAnalysis} hand-off the effect's face tracker needs.
 *
 * <p>Both fields are {@code volatile} and read on the camera binding thread while being written
 * from the platform thread. Neither is ever mutated in place.
 */
public final class MilesCameraEffectHook {
  private MilesCameraEffectHook() {}

  @Nullable private static volatile CameraEffect effect;

  /**
   * Arms {@code e} so the next bind attaches it. Passing null is the same as {@link #disarm()}.
   *
   * <p>Arming after the camera has bound does nothing until the next bind — a flip or a
   * background/resume — because the effect list is captured at bind time.
   */
  public static void arm(@Nullable CameraEffect e) {
    effect = e;
  }

  /** Removes the effect. The next bind takes the original, un-patched code path exactly. */
  public static void disarm() {
    effect = null;
  }

  /** The armed effect, or null. Read once per bind. */
  @Nullable
  public static CameraEffect effect() {
    return effect;
  }

  /** Whether a bind would attach an effect. */
  public static boolean isArmed() {
    return effect != null;
  }
}
