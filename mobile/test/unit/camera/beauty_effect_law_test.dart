import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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
}

/// Java source with comments removed, so a law about CODE is never satisfied or
/// broken by PROSE. Block comments first, then line comments.
String _code(String java) => java
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), ' ')
    // `.` excludes newlines unless dotAll is set, so this stops at end of line.
    .replaceAll(RegExp(r'//.*'), ' ');
