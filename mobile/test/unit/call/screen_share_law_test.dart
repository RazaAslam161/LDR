import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The redesign's laws, pinned as structure (BRAIN §180).
///
/// The architecture is Meet's: a screen share gets a DEDICATED peer connection
/// — its own bandwidth estimate, its own negotiation, its own death — and
/// quality is CLIMBED from a fundable start, never gambled on an unproven
/// estimate. Source-read, because everything here needs two handsets to
/// exercise live and this machine has no Android SDK. Every assertion is the
/// shape a refactor would most plausibly break while "improving" something.
void main() {
  final controller =
      File('lib/features/call/call_controller.dart').readAsStringSync();
  final session =
      File('lib/features/call/screen_share_session.dart').readAsStringSync();
  final screen = File('lib/features/call/call_screen.dart').readAsStringSync();

  group('the dedicated connection', () {
    test('the share never rides the call\'s connection', () {
      expect(controller.contains('addTransceiver'), isFalse,
          reason: 'a pre-negotiated share m-line on the call connection is the '
              'shared-PC design that failed twice — builds 59/60',);
      expect(session.contains('createPeerConnection'), isTrue,
          reason: 'the session must build its own connection',);
      expect(controller.contains('ScreenShareSession('), isTrue,
          reason: 'the controller must hand the share to a session',);
    });

    test('share signalling has its own kinds, on the call channel', () {
      for (final kind in ['share-offer', 'share-answer', 'share-ice']) {
        expect(session.contains("'$kind'"), isTrue,
            reason: '$kind must be sent or consumed by the session',);
        expect(controller.contains("case '$kind':"), isTrue,
            reason: 'the dispatch switch must route $kind',);
      }
    });

    test('every share exit lets go of the session', () {
      // Stop, teardown, the partner's screen-off, and the receive-side swap
      // each hand the old session over for closing. A path that forgets keeps
      // sockets and an encoder alive behind a UI that says nothing is shared.
      expect('_shareSession = null;'.allMatches(controller).length,
          greaterThanOrEqualTo(4),
          reason: 'an exit path stopped releasing the session',);
      final off = controller.indexOf("case 'screen':");
      expect(off, greaterThan(-1));
      expect(
          controller
              .substring(off, off + 700)
              .contains('screenRenderer.srcObject = null'),
          isTrue,
          reason: 'screen-off must drop the last frame, not letterbox it',);
    });
  });

  group('the climb', () {
    test('degradation is BALANCED — MAINTAIN_RESOLUTION is banned', () {
      expect(session.contains('RTCDegradationPreference.BALANCED'), isTrue);
      for (final src in [session, controller]) {
        expect(src.contains('MAINTAIN_RESOLUTION'), isFalse,
            reason: 'this codebase already shipped "a picture that sticks" '
                'with MAINTAIN_RESOLUTION screencast — twice. Sharpness comes '
                'from the climb reaching the top rung.',);
      }
    });

    test('bitrate has a floor as well as a per-rung ceiling', () {
      expect(session.contains('minBitrate'), isTrue,
          reason: 'without the floor, VP9 undershoot starves a static page',);
      expect(session.contains('maxBitrate'), isTrue,
          reason: 'without the ceiling, the first congested second collapses '
              'the estimate for both connections',);
    });

    test('the share prefers HARDWARE H.264 — a VP9 preference is banned', () {
      expect(session.contains("'video/h264'"), isTrue,
          reason: 'H.264 is the one codec with a hardware encoder on '
              'effectively every Android handset',);
      expect(session.toLowerCase().contains("'video/vp9'"), isFalse,
          reason: 'neither owner phone has a VP9 hardware encoder '
              '(vendor media_codecs.xml, checked on-device) — preferring it '
              'means libvpx software-encoding the whole display: the '
              'cpu-limited, laggy, never-climbing share of build 61',);
      expect(session.contains('setCodecPreferences'), isTrue);
      expect(controller.contains('setCodecPreferences'), isFalse,
          reason: 'a codec preference on the call connection is the '
              'H264-promotion regression, and disturbing the call\'s '
              'negotiation is what the dedicated connection exists to end',);
    });

    test('the camera pays half price during a share, and is restored', () {
      expect(controller.contains('damp ? 2.0 : 1.0'), isTrue,
          reason: 'the doubled literal is load-bearing — the Android bridge '
              'hard-casts scaleResolutionDownBy to Double',);
      final at = controller.indexOf('Future<void> _setCameraShareProfile(');
      expect(at, greaterThan(-1));
      expect(controller.substring(at, at + 1800).contains('maxBitrate'),
          isFalse,
          reason: 'a bitrate field can NEVER be unset through this plugin — '
              'capping the camera once would cap it forever',);
      final stop = controller.indexOf('Future<void> stopScreenShare(');
      expect(
          controller
              .substring(stop, stop + 1600)
              .contains('_setCameraShareProfile(damp: false)'),
          isTrue,
          reason: 'the share ends, the face goes back to full quality',);
    });

    test('every ended share files its quality digest', () {
      expect(controller.contains("kind: 'share-quality'"), isTrue);
      expect(session.contains('ShareQualityDigest'), isTrue);
      expect('takeDigest()'.allMatches(controller).length,
          greaterThanOrEqualTo(2),
          reason: 'both share ends — stop and hangup-mid-share — must file',);
    });
  });

  group('capture and preview', () {
    test('the capture request no longer opts out of single-app sharing', () {
      expect(controller.contains('fullScreenOnly: true'), isFalse,
          reason: 'verified in the plugin source: true forces whole-display '
              'and is the echo/notification-leak class',);
    });

    test('the live self-preview is gated on app-scoped capture', () {
      final at = screen.indexOf('screenSelfRenderer');
      expect(at, greaterThan(-1));
      expect(screen.substring(at - 400, at).contains('appScopedShare'), isTrue,
          reason: 'an ungated preview of a whole-display share is a mirror '
              'inside the captured pixels',);
      expect(controller.contains('bool appScopedShare = false;'), isTrue);
    });

    test('during a share, every face lives in the scrollable strip', () {
      expect(screen.contains('FaceStrip('), isTrue);
      final strip =
          File('lib/features/call/call_face_strip.dart').readAsStringSync();
      expect(strip.contains('scrollDirection: Axis.horizontal'), isTrue);
      expect(strip.contains('BouncingScrollPhysics'), isTrue,
          reason: 'the owner asked for smooth scrollable previews — a fixed '
              'column of tiles is the build-61 complaint',);
    });

    test('the full-screen sharing panel cannot eat the stats long-press', () {
      final at = screen.indexOf('_SharingCard(big: true)');
      expect(at, greaterThan(-1));
      expect(screen.substring(at - 400, at).contains('IgnorePointer'), isTrue,
          reason: 'ColoredBox hit-tests opaque; full-screen it would sit over '
              'the long-press layer and the diagnostic overlay would be '
              'untogglable on the one phone whose numbers matter mid-share',);
    });
  });

  group('the stop path', () {
    test('the system Stop press is a HINT that fast-tracks the watchdog', () {
      // Build 59 called stopScreenShare() directly here and every share on
      // OEMs with the spurious-onStop quirk (named in the upstream comment
      // the patch preserves) died at birth. The event must gate on the
      // just-started window and only ever arm the hint.
      final at = controller.indexOf('void _onWebrtcPluginEvent(');
      expect(at, greaterThan(-1));
      final body = controller.substring(at, at + 2400);
      final stopBranch =
          body.substring(0, body.indexOf('miles.screenCaptureContentResize'));
      expect(stopBranch.contains('stopScreenShare()'), isFalse,
          reason: 'a direct kill on a spurious event is the build-59 '
              'regression',);
      expect(stopBranch.contains('_screenStopHinted = true'), isTrue);
      expect(stopBranch.contains('Duration(seconds: 3)'), isTrue,
          reason: 'the documented spurious window must be ignored entirely',);
      // And the session's watchdog honors the hint but still demands real
      // evidence — frames actually stopped. The counts are per 1s sample:
      // the same 2s/6s wall clock that survived field use, not a faster kill.
      expect(session.contains('stopHinted() ? 2 : 6'), isTrue);
      expect(session.contains('else if (_sawFrames)'), isTrue,
          reason: 'a share that has not yet produced frames reports the same '
              'zero as a dead one; killing it there breaks slow handsets',);
    });

    test('the resize event re-aims the running session', () {
      final at = controller.indexOf('miles.screenCaptureContentResize');
      expect(at, greaterThan(-1));
      expect(controller.substring(at, at + 1600).contains('retarget'), isTrue,
          reason: 'an app-scoped capture is smaller than the panel; scaling '
              'from the panel would shrink content that already fits',);
    });
  });

  group('the vendored fork', () {
    final java = File(
      'third_party/flutter_webrtc/android/src/main/java/com/cloudwebrtc/webrtc/GetUserMediaImpl.java',
    ).readAsStringSync();
    final pubspec = File('pubspec.yaml').readAsStringSync();

    test('pinned as a path override, and patched where claimed', () {
      expect(pubspec.contains('third_party/flutter_webrtc'), isTrue,
          reason: 'without the override the hosted plugin loads and the '
              'events this design relies on never fire',);
      expect(java.contains('miles.screenCaptureStop'), isTrue);
      expect(java.contains('miles.screenCaptureContentResize'), isTrue);
      expect(java.contains('getMainLooper'), isTrue,
          reason: 'MediaProjection callbacks arrive on the capture thread; an '
              'un-posted sendEvent throws on the @UiThread sink',);
    });
  });
}
