import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/chat/camera/beauty/beauty_settings.dart';

/// The camera-effect seam's laws, pinned as structure.
///
/// `camera_android_camerax` is vendored for ONE reason: upstream binds through
/// the varargs `bindToLifecycle(owner, selector, UseCase...)`, which has
/// nowhere to attach an `androidx.camera.core.CameraEffect`. The retouch
/// pipeline needs one effect covering PREVIEW | IMAGE_CAPTURE | VIDEO_CAPTURE
/// together, so the viewfinder, the saved photo and the recorded video are one
/// processor's output rather than three implementations agreeing to match.
///
/// Source-read, because this is Java: `flutter test` never compiles it, the
/// analyzer never reads it, and the only build that exercises it under R8 is
/// the play flavour on a handset. Same technique and same reason as
/// test/unit/call/screen_share_law_test.dart, which pins the flutter_webrtc
/// patch. Every assertion below is the shape a rebase onto a newer upstream
/// would most plausibly drop while "taking the latest version".
void main() {
  const dir =
      'third_party/camera_android_camerax/android/src/main/java/io/flutter/plugins/camerax';
  final bind = File('$dir/ProcessCameraProviderProxyApi.java');
  final hook = File('$dir/MilesCameraEffectHook.java');

  group('the vendored fork still carries its patch', () {
    test('both files exist — a re-vendor that drops them is silent otherwise',
        () {
      expect(bind.existsSync(), isTrue,
          reason: 'the patch target is gone; the fork has been re-copied from '
              'pub without re-applying the Miles patch');
      expect(hook.existsSync(), isTrue,
          reason: 'MilesCameraEffectHook is an addition, not upstream code, and '
              'a re-copy deletes it');
    });

    test('bindToLifecycle takes the UseCaseGroup path when armed', () {
      final source = bind.readAsStringSync();
      expect(source.contains('MilesCameraEffectHook.effect()'), isTrue,
          reason: 'the bind no longer consults the hook, so an armed effect '
              'would never reach the camera and the whole feature is a dead '
              'control',);
      expect(source.contains('group.addEffect(effect)'), isTrue,
          reason: 'the effect must be attached to the UseCaseGroup',);
      expect(source.contains('new UseCaseGroup.Builder()'), isTrue,
          reason: 'the varargs overload cannot carry an effect; only the '
              'UseCaseGroup overload can',);
    });

    test('the disarmed path is still the original varargs call', () {
      // The fallback is the whole safety story: disarm and the camera is
      // bit-for-bit what it was before this fork existed. That is also the
      // designed degrade for GL init failure, so losing it turns a recoverable
      // failure into a black viewfinder.
      final source = bind.readAsStringSync();
      expect(source.contains('useCases.toArray(new UseCase[0])'), isTrue,
          reason: 'the un-patched call path is the fallback for a disarmed '
              'hook and for every GL failure; it must survive',);
    });

    test('the comment stripper can actually match — proven both ways', () {
      // This gate COUNTS, so it proves it can match before its zero means
      // anything. The first version of the test below read the raw file and
      // failed on its own explanatory comment: the forbidden token appears in
      // the prose that explains why it is forbidden. A matcher that cannot
      // tell code from prose reports whatever the last person wrote.
      expect(_code('int a; // ONE_FOR_EACH_TARGET'), isNot(contains('ONE_FOR')),
          reason: 'a line comment must be stripped',);
      expect(_code('/* ONE_FOR_EACH_TARGET */ int a;'),
          isNot(contains('ONE_FOR')),
          reason: 'a block comment must be stripped',);
      expect(_code('setOutputOption(ONE_FOR_EACH_TARGET);'),
          contains('ONE_FOR_EACH_TARGET'),
          reason: 'real code must SURVIVE stripping, or the check below is '
              'structurally green and measures nothing',);
    });

    test('ONE_FOR_EACH_TARGET is never used in code', () {
      // The trap in this API, and it is the flag a reader reaches for when
      // they want preview and photo to differ. SurfaceProcessorWithExecutor
      // .snapshot() — the wrapper CameraX puts around any app-supplied
      // processor — is an unconditional
      //   immediateFailedFuture("Snapshot not supported by external
      //   SurfaceProcessor")
      // and StreamSharing only routes through it under that output option.
      // Under the default ONE_FOR_ALL_TARGETS the still is taken off the
      // shared stream by DefaultSurfaceProcessor, which implements snapshot().
      // Get this wrong and takePicture() fails 100% of the time, on device,
      // in a build no unit test covers.
      for (final f in [bind, hook]) {
        expect(_code(f.readAsStringSync()).contains('ONE_FOR_EACH_TARGET'),
            isFalse,
            reason: '${f.path} uses ONE_FOR_EACH_TARGET in code, which routes '
                'snapshot() to a stub that always fails — takePicture() would '
                'break on every device',);
      }
    });

    test('the hook stays in a package R8 already keeps', () {
      // mobile/android/app/proguard-rules.pro keeps io.flutter.plugins.** and
      // does NOT keep com.miles.miles.**. R8 runs on the play flavour only —
      // the build real users install and the one no gate here exercises — so
      // moving this class is a crash that surfaces in production and nowhere
      // else.
      expect(hook.readAsStringSync().contains('package io.flutter.plugins.camerax;'),
          isTrue,
          reason: 'the hook must stay in io.flutter.plugins.camerax, which '
              'proguard-rules.pro already keeps',);
    });
  });

  group('the one screen that must never arm it', () {
    test('the heartbeat reader drives the camera with no retouch in the path',
        () {
      // It measures a pulse from a torch-lit fingertip through startImageStream.
      // A GPU pass in that stream would corrupt the measurement it exists to
      // take, and CameraX would refuse a second ImageAnalysis beside its own.
      final heartbeat =
          File('lib/features/heartbeat/heartbeat_screen.dart').readAsStringSync();
      expect(heartbeat.contains('BeautyEngine'), isFalse);
      expect(heartbeat.contains('miles/beauty'), isFalse);
    });
  });

  group('the seven review findings stay fixed', () {
    const cx = 'third_party/camera_android_camerax';
    test('the face tracker rides the plugin analyzer and maps through the sensor', () {
      final bindSrc = File('$cx/android/src/main/java/io/flutter/plugins/camerax/ProcessCameraProviderProxyApi.java').readAsStringSync();
      expect(bindSrc, contains('setAnalyzer(executor, analyzer)'),
          reason: 'a second ImageAnalysis is a second YUV stream most cameras refuse',);
      expect(bindSrc, contains('MilesCameraEffectHook.onBound(camera)'));
      final tracker = File('android/app/src/main/kotlin/com/miles/miles/beauty/FaceTracker.kt').readAsStringSync();
      expect(tracker, contains('sensorToBufferTransformMatrix'));
      final effect = File('android/app/src/main/kotlin/com/miles/miles/beauty/BeautyEffect.kt').readAsStringSync();
      expect(effect, contains('setTransformationInfoListener'),
          reason: 'analysis and effect streams are different crops of the sensor',);
    });
    test('the preview is not rotated twice when armed', () {
      final prev = File('$cx/android/src/main/java/io/flutter/plugins/camerax/PreviewProxyApi.java').readAsStringSync();
      expect(prev, contains('|| MilesCameraEffectHook.isArmed()'));
      expect(prev, contains('MilesCameraEffectHook.boundCamera()'));
    });
    test('the use-case graph stays stable across a recording when armed', () {
      final dart = File('$cx/lib/src/android_camera_camerax.dart').readAsStringSync();
      expect(dart, contains('if (keepGraphStableForEffect) videoCapture!,'));
      expect(dart, contains('streamCallback == null && !keepGraphStableForEffect'));
      expect(dart, contains('if (!keepGraphStableForEffect) {\n      await _unbindUseCaseFromLifecycle(videoCapture!);'));
      final screen = File('lib/features/chat/camera/rapid_camera_screen.dart').readAsStringSync();
      expect('keepGraphStableForEffect = _beautyArmed'.allMatches(screen).length, 2,
          reason: 'set at boot and on every rebind',);
    });
    test('a toggle disposes the old controller and rebinds serially', () {
      final screen = File('lib/features/chat/camera/rapid_camera_screen.dart').readAsStringSync();
      final i = screen.indexOf('Future<void> _applyBeauty(');
      final body = screen.substring(i, screen.indexOf('\n  }\n', i));
      expect(body, contains('await _controller?.dispose();'));
      expect(body, contains('_rebind = _rebind.then('));
    });
  });

  group('the call has its own look control and no silent link', () {
    test('the video call carries the Look control and the shared sheet', () {
      final screen = File('lib/features/call/call_screen.dart').readAsStringSync();
      expect(screen, contains('Icons.face_retouching_natural'));
      expect(screen, contains('showBeautySheet('));
      expect(screen, contains('BeautyEngine.applyCall(s)'));
      expect(screen, contains('BeautyPrefs.useInCalls = true'),
          reason: 'enabling it mid-call must stick for the next call',);
    });
    test('every link from arm to first frame logs what it did', () {
      final ctl = File('lib/features/call/call_controller.dart').readAsStringSync();
      expect(ctl, contains("shareLog('retouch: armCalls -> "));
      expect(ctl, contains('retouch: not armed for this call'));
      final main = File('android/app/src/main/kotlin/com/miles/miles/MainActivity.kt').readAsStringSync();
      expect(main, contains('"armCalls: enabled='));
      final hook = File('third_party/flutter_webrtc/android/src/main/java/com/cloudwebrtc/webrtc/MilesVideoProcessorHook.java').readAsStringSync();
      expect(hook, contains('hook onCameraTrack: armed='));
      final proc = File('android/app/src/main/kotlin/com/miles/miles/beauty/CallBeautyProcessor.kt').readAsStringSync();
      expect(proc, contains('first frame after arm: enabled='));
    });
    test('the sheet shows colours only when the caller has no strip', () {
      final sheet = File('lib/features/chat/camera/beauty/beauty_sheet.dart').readAsStringSync();
      expect(sheet, contains('if (onColour != null && colours.isNotEmpty)'));
      final camera = File('lib/features/chat/camera/rapid_camera_screen.dart').readAsStringSync();
      expect(camera, isNot(contains('onColour:')),
          reason: 'the camera has its own strip; two owners of one choice drift',);
    });
    test('the Settings row for calls flips only from its switch', () {
      final settings = File('lib/features/settings/settings_screen.dart').readAsStringSync();
      final i = settings.indexOf("title: 'In video calls'");
      final block = settings.substring(i, settings.indexOf('),', settings.indexOf('onTap:', i)));
      expect(block, contains('onTap: null'));
    });
  });

  group('the smoothing core is edge-preserving, not a Gaussian', () {
    // GLSL is compiled by NOTHING here — not flutter test, not the analyzer, not CI. Only a
    // handset ever sees it. These are the invariants whose loss would look like a quality
    // regression rather than a failure, which is the kind that survives a release.
    final shaders = File(
      'android/app/src/main/kotlin/com/miles/miles/beauty/BeautyShaders.kt',
    ).readAsStringSync();
    final renderer = File(
      'android/app/src/main/kotlin/com/miles/miles/beauty/BeautyGlRenderer.kt',
    ).readAsStringSync();

    test('the guided filter exists and the composite consumes it', () {
      expect(shaders, contains('const val GUIDED'));
      expect(shaders, contains('vari / (vari + uEps)'),
          reason: 'a = var/(var+eps) IS the skin-or-edge decision; without it there is '
              'no edge preservation and the look goes back to plastic',);
      expect(shaders, contains('float gY = ab.x * Y + ab.y;'),
          reason: 'the composite must apply the linear model, not just compute it',);
    });

    test('the statistics are computed in highp and never stored as moments', () {
      // var = E[Y2] - E[Y]2 cancels catastrophically: skin variance ~1e-4 against means
      // ~0.25. fp16 destroys it, and an 8-bit texture destroys it again. The moments must
      // stay in registers; only (a, b), both well conditioned in 0..1, may be written.
      final guided = shaders.substring(
        shaders.indexOf('const val GUIDED'),
        shaders.indexOf('const val MASK'),
      );
      expect(guided, contains('precision highp float'),
          reason: 'mediump cannot hold the variance subtraction',);
      expect(guided, contains('gl_FragColor = vec4(a, mean * (1.0 - a)'),
          reason: 'only the coefficients leave this shader; storing the moments in an '
              '8-bit target would lose the very signal they carry',);
    });

    test('the detail layer is restored selectively, not as a flat fraction', () {
      // A flat fraction puts the blemish back AND keeps pores flattened — wrong at both
      // ends, and what the Gaussian path did.
      expect(shaders, contains('1.0 - smoothstep(uPoreT, uBlemishT, abs(fine))'));
      expect(shaders.contains('vec3 hi = a - b;'), isFalse,
          reason: 'the old frequency-separation core must not come back',);
      // THREE bands, not two. One scale cannot separate a blotch from a pore: the
      // radius that evens a blotch erases the pores, and the radius that keeps
      // pores cannot see the blotch at all.
      expect(shaders, contains('float mid = gY - gC;'));
      expect(shaders, contains('float fine = Y - gY;'));
      expect(shaders, contains('uEvenness'),
          reason: 'the blotch band needs its own weight, or it is either fully '
              'restored or fully flattened into a mask',);
      // Chroma evening must be held back at edges too; blending toward the
      // edge-blind Gaussian is what left a colour halo at the lips and nose.
      expect(shaders, contains('(1.0 - ab.x)'),
          reason: "the guided model's own edge term must gate the chroma blend",);
    });

    test('the coefficients are measured on the SHARP half, before the blur', () {
      // The blur overwrites texH0 in place. Measuring local variance after it would be
      // measuring the blur's variance, which is nearly zero everywhere — the filter would
      // smooth the entire frame including the eyes.
      final guidedAt = renderer.indexOf('val g = guided!!');
      final blurAt = renderer.indexOf('val b = blur!!');
      expect(guidedAt, greaterThan(0));
      expect(guidedAt, lessThan(blurAt),
          reason: 'the guided pass must run before the blur clobbers the sharp half',);
    });

    test('eps follows the smooth slider on BOTH engines', () {
      // Camera and call share runPasses; each sets eps from its own params. If only one
      // did, the same look would smooth differently on a call than on a snap.
      expect('guidedEps = 0.0008f + p.smooth'.allMatches(renderer).length, 2,
          reason: 'render() and renderToTexture() must both set it',);
    });
  });

  group('the override that makes the fork load at all', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();

    test('the path override is present', () {
      expect(pubspec.contains('path: third_party/camera_android_camerax'),
          isTrue,
          reason: 'without the dependency_overrides entry pub resolves the '
              'pub.dev copy and every patch above is inert — the camera would '
              'work, the effect would simply never attach',);
    });

    test('the sibling fork was not disturbed', () {
      expect(pubspec.contains('path: third_party/flutter_webrtc'), isTrue,
          reason: 'flutter_webrtc is vendored for the screen-share patches '
              '(BRAIN §180); adding a second override must not displace it',);
    });
  });

  group('the Dart side arms in the right order and nowhere else', () {
    final screen =
        File('lib/features/chat/camera/rapid_camera_screen.dart').readAsStringSync();

    test('arm happens BEFORE the first bind, disarm in dispose', () {
      final boot = screen.indexOf('Future<void> _boot() async {');
      final arm = screen.indexOf('BeautyEngine.arm(', boot);
      final init = screen.indexOf('await _initController(', boot);
      expect(arm, greaterThan(boot), reason: '_boot must arm');
      expect(arm, lessThan(init),
          reason: 'CameraX captures the effect list at bind time; arming after '
              '_initController does nothing until the next flip',);
      final dispose = screen.indexOf('void dispose() {');
      expect(screen.indexOf('BeautyEngine.disarm(', dispose), greaterThan(dispose),
          reason: 'dispose must disarm, or the next camera screen inherits '
              'the effect',);
    });

    test('the heartbeat reader never arms the effect', () {
      final hb = File('lib/features/heartbeat/heartbeat_screen.dart').readAsStringSync();
      expect(hb.contains('BeautyEngine'), isFalse,
          reason: 'PPG reads a torch-lit fingertip; a retouch on that stream '
              'corrupts the measurement it exists to take',);
    });
  });

  group('the channel keys are the same on both sides', () {
    test('every key Dart emits is read by BeautyParams.kt', () {
      final kt = File(
        'android/app/src/main/kotlin/com/miles/miles/beauty/BeautyParams.kt',
      ).readAsStringSync();
      for (final key in kBeautyPresets[1].settings.toChannelMap().keys) {
        expect(kt.contains('"$key"'), isTrue,
            reason: 'Kotlin never reads "$key" — a renamed key is a slider that '
                'silently does nothing on a handset',);
      }
    });
  });

  group('the bind degrades without the analyzer', () {
    test('a refused ImageAnalysis rebinds without it and is flagged', () {
      final source = _code(bind.readAsStringSync());
      // The second argument is now a flag: false = no analyzer of any kind.
      expect(source.contains('milesGroup(useCases, effect, false)'), isTrue,
          reason: 'the fallback rebind is the designed degrade for cameras that '
              'cannot run analysis beside preview + capture + video',);
      expect(source.contains('MilesCameraEffectHook.onAnalysisRefused()'), isTrue,
          reason: 'a silent degrade is a dead control; it must be flagged',);
    });
  });
}

/// Java source with comments removed, so a law about CODE is never satisfied or
/// broken by PROSE. Block comments first, then line comments.
String _code(String java) => java
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), ' ')
    // `.` excludes newlines unless dotAll is set, so this stops at end of line.
    .replaceAll(RegExp(r'//.*'), ' ');
