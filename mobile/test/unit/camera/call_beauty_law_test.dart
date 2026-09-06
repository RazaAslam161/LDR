import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/chat/camera/beauty/beauty_engine.dart';
import 'package:miles/features/chat/camera/beauty/beauty_settings.dart';

/// The call-side retouch seam's laws.
///
/// Half of this is Java in the vendored flutter_webrtc, which `flutter test`
/// never compiles — so it is pinned by reading the source, the way
/// screen_share_law_test.dart pins that fork's other patches. The other half
/// is the Dart ordering the seam depends on.
void main() {
  const fork =
      'third_party/flutter_webrtc/android/src/main/java/com/cloudwebrtc/webrtc';
  final hook = File('$fork/MilesVideoProcessorHook.java');
  final gum = File('$fork/GetUserMediaImpl.java').readAsStringSync();
  final track = File('$fork/video/LocalVideoTrack.java').readAsStringSync();
  final controller =
      File('lib/features/call/call_controller.dart').readAsStringSync();

  group('the vendored fork still carries its patch', () {
    test('the hook exists — a re-vendor that drops it is silent otherwise', () {
      expect(hook.existsSync(), isTrue,
          reason: 'MilesVideoProcessorHook is an addition, not upstream code',);
    });

    test('camera tracks are reported to the hook, screen capture is not', () {
      expect('MilesVideoProcessorHook.onCameraTrack('.allMatches(gum).length, 1,
          reason: 'exactly one report site: the camera track',);
      expect(gum.contains('onCameraTrack(displayLocalVideoTrack'), isFalse,
          reason: 'a retouch on a shared screen would be a bug, not a feature',);
      // The report must follow the camera track's own creation line.
      final create = gum.indexOf('videoSource.setVideoProcessor(localVideoTrack)');
      final report = gum.indexOf('MilesVideoProcessorHook.onCameraTrack(localVideoTrack)');
      expect(create, greaterThan(-1));
      expect(report, greaterThan(create));
    });

    test('a replacement frame is released after the sink has taken it', () {
      // Upstream never released a processor's returned frame. For a texture-
      // backed frame that is one GPU texture leaked per frame, forever, and the
      // output pool exhausts in three frames.
      expect(track.contains('if (current != original) current.release();'),
          isTrue,
          reason: 'the fork must release the replacement after sink.onFrame',);
      final sink = track.indexOf('sink.onFrame(current)');
      final release = track.indexOf('if (current != original) current.release();');
      expect(sink, greaterThan(-1));
      expect(release, greaterThan(sink),
          reason: 'release AFTER the sink, or the sink reads a freed buffer',);
    });

    test('the hook lives in a package the fork already keeps under R8', () {
      final rules = File('third_party/flutter_webrtc/android/proguard-rules.pro')
          .readAsStringSync();
      expect(rules.contains('-keep class com.cloudwebrtc.webrtc.** { *; }'),
          isTrue,);
      expect(hook.readAsStringSync().contains('package com.cloudwebrtc.webrtc;'),
          isTrue,);
    });
  });

  group('the call arms in the right order', () {
    test('armCalls precedes getUserMedia, and is gated on BOTH switches', () {
      final arm = controller.indexOf('BeautyEngine.armCalls(');
      final gum = controller.indexOf('navigator.mediaDevices.getUserMedia(');
      expect(arm, greaterThan(-1), reason: 'the call never arms the retouch');
      expect(gum, greaterThan(-1));
      expect(arm, lessThan(gum),
          reason: 'armed after the track exists still works, but the first '
              'frames the far side sees would be unprocessed',);
      expect(controller.contains('BeautyPrefs.forCall().enabled'), isTrue,
          reason: 'forCall folds in enabled AND useInCalls; using forCamera '
              'here would ignore the calls switch',);
    });

    test('teardown disarms before the local stream is disposed', () {
      final disarm = controller.indexOf('BeautyEngine.disarmCalls()');
      final dispose = controller.indexOf('await _localStream?.dispose()');
      expect(disarm, greaterThan(-1));
      expect(disarm, lessThan(dispose));
    });
  });

  group('the engine, against a mocked channel', () {
    final calls = <MethodCall>[];
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      calls.clear();
      BeautyEngine.debugReset();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(BeautyEngine.channel, (call) async {
        calls.add(call);
        return call.method == 'armCalls' ? true : null;
      });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(BeautyEngine.channel, null);
    });

    test('armCalls sends the pre-multiplied payload and records the state',
        () async {
      const s = BeautySettings(
        enabled: true,
        amount: 0.5,
        retouch: RetouchParams(smooth: 0.8),
      );
      expect(await BeautyEngine.armCalls(s), isTrue);
      expect(BeautyEngine.callsArmed, isTrue);
      expect(calls.single.method, 'armCalls');
      final args = calls.single.arguments as Map;
      expect(args['smooth'], closeTo(0.4, 1e-9));
    });

    test('a disabled look disarms rather than arming a no-op', () async {
      await BeautyEngine.armCalls(const BeautySettings(enabled: true));
      calls.clear();
      expect(await BeautyEngine.armCalls(const BeautySettings()), isFalse);
      expect(calls.single.method, 'disarmCalls');
      expect(BeautyEngine.callsArmed, isFalse);
    });

    test('update reaches native when only calls are armed', () async {
      await BeautyEngine.armCalls(const BeautySettings(enabled: true));
      calls.clear();
      await BeautyEngine.update(const BeautySettings(enabled: true, amount: 1));
      expect(calls.single.method, 'update');
    });

    test('disarmCalls is idempotent and never sends when not armed', () async {
      await BeautyEngine.disarmCalls();
      expect(calls, isEmpty);
    });

    test('the camera and call states are independent', () async {
      await BeautyEngine.armCalls(const BeautySettings(enabled: true));
      expect(BeautyEngine.callsArmed, isTrue);
      expect(BeautyEngine.armed, isFalse);
    });
  });
}
