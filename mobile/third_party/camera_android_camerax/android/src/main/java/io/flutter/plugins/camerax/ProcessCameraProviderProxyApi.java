// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import android.util.Log;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.camera.core.Camera;
import androidx.camera.core.CameraEffect;
import androidx.camera.core.CameraInfo;
import androidx.camera.core.CameraSelector;
import androidx.camera.core.ImageAnalysis;
import androidx.camera.core.UseCase;
import androidx.camera.core.UseCaseGroup;
import androidx.camera.lifecycle.ProcessCameraProvider;
import androidx.core.content.ContextCompat;
import androidx.lifecycle.LifecycleOwner;
import com.google.common.util.concurrent.ListenableFuture;
import java.util.List;
import java.util.concurrent.ExecutionException;
import kotlin.Result;
import kotlin.Unit;
import kotlin.jvm.functions.Function1;

/**
 * ProxyApi implementation for {@link ProcessCameraProvider}. This class may handle instantiating
 * native object instances that are attached to a Dart instance or handle method calls on the
 * associated native class or an instance of that class.
 */
class ProcessCameraProviderProxyApi extends PigeonApiProcessCameraProvider {
  ProcessCameraProviderProxyApi(@NonNull ProxyApiRegistrar pigeonRegistrar) {
    super(pigeonRegistrar);
  }

  @NonNull
  @Override
  public ProxyApiRegistrar getPigeonRegistrar() {
    return (ProxyApiRegistrar) super.getPigeonRegistrar();
  }

  @Override
  public void getInstance(
      @NonNull Function1<? super Result<ProcessCameraProvider>, Unit> callback) {
    final ListenableFuture<ProcessCameraProvider> processCameraProviderFuture =
        ProcessCameraProvider.getInstance(getPigeonRegistrar().getContext());

    processCameraProviderFuture.addListener(
        () -> {
          try {
            // Camera provider is now guaranteed to be available.
            ResultCompat.success(processCameraProviderFuture.get(), callback);
          } catch (InterruptedException | ExecutionException e) {
            ResultCompat.failure(e, callback);
          }
        },
        ContextCompat.getMainExecutor(getPigeonRegistrar().getContext()));
  }

  @NonNull
  @Override
  public List<CameraInfo> getAvailableCameraInfos(ProcessCameraProvider pigeonInstance) {
    return pigeonInstance.getAvailableCameraInfos();
  }

  // Miles patch — see bindToLifecycle.
  private static final String TAG = "MilesCameraEffect";

  @NonNull
  private static UseCaseGroup milesGroup(
      @NonNull List<? extends UseCase> useCases,
      @NonNull CameraEffect effect,
      @Nullable ImageAnalysis analysis) {
    final UseCaseGroup.Builder group = new UseCaseGroup.Builder();
    for (UseCase useCase : useCases) {
      group.addUseCase(useCase);
    }
    if (analysis != null) {
      group.addUseCase(analysis);
    }
    group.addEffect(effect);
    return group.build();
  }

  @NonNull
  @Override
  public Camera bindToLifecycle(
      @NonNull ProcessCameraProvider pigeonInstance,
      @NonNull CameraSelector cameraSelector,
      @NonNull List<? extends UseCase> useCases) {
    final LifecycleOwner lifecycleOwner = getPigeonRegistrar().getLifecycleOwner();
    if (lifecycleOwner != null) {
      // Miles patch — the ONE reason this package is vendored.
      //
      // Upstream calls the varargs overload, which has nowhere to hang a
      // CameraEffect. When Miles has armed one (MilesCameraEffectHook), bind a
      // UseCaseGroup instead so the effect reaches PREVIEW, IMAGE_CAPTURE and
      // VIDEO_CAPTURE from a single processor run. Disarmed, this falls through
      // to the original call below, unchanged, and the camera is bit-for-bit
      // what it was before the fork existed.
      //
      // The effect MUST keep CameraEffect's default OUTPUT_OPTION_ONE_FOR_ALL_
      // TARGETS. With ONE_FOR_EACH_TARGET, StreamSharing routes the still
      // through SurfaceProcessorWithExecutor, whose snapshot() is a hard
      // `immediateFailedFuture("Snapshot not supported by external
      // SurfaceProcessor")` — takePicture() would then fail 100% of the time.
      // Under the default, the still is taken off the shared, already-processed
      // stream by DefaultSurfaceProcessor, which does implement snapshot().
      final CameraEffect effect = MilesCameraEffectHook.effect();
      if (effect != null) {
        final ImageAnalysis analysis = MilesCameraEffectHook.analysis();
        if (analysis != null) {
          try {
            return pigeonInstance.bindToLifecycle(
                lifecycleOwner, cameraSelector, milesGroup(useCases, effect, analysis));
          } catch (IllegalArgumentException e) {
            // This camera cannot run ImageAnalysis beside preview + capture + video (a LIMITED
            // hardware level, or a StreamSharing combination it does not support). CameraX
            // validates the combination before attaching anything, so nothing is bound yet.
            // Rebind without the analyzer: the retouch keeps working on colour alone and only
            // the face-aware passes are lost. Logged and flagged, never swallowed.
            Log.w(TAG, "face analysis refused by this camera, rebinding without it: " + e);
            MilesCameraEffectHook.onAnalysisRefused();
          }
        }
        return pigeonInstance.bindToLifecycle(
            lifecycleOwner, cameraSelector, milesGroup(useCases, effect, null));
      }
      return pigeonInstance.bindToLifecycle(
          lifecycleOwner, cameraSelector, useCases.toArray(new UseCase[0]));
    }

    throw new IllegalStateException(
        "LifecycleOwner must be set to get ProcessCameraProvider instance.");
  }

  @Override
  public boolean isBound(ProcessCameraProvider pigeonInstance, @NonNull UseCase useCase) {
    return pigeonInstance.isBound(useCase);
  }

  @Override
  public void unbind(
      ProcessCameraProvider pigeonInstance, @NonNull List<? extends UseCase> useCases) {
    pigeonInstance.unbind(useCases.toArray(new UseCase[0]));
  }

  @Override
  public void unbindAll(ProcessCameraProvider pigeonInstance) {
    pigeonInstance.unbindAll();
  }
}
