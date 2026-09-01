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
    test("the share never rides the call's connection", () {
      expect(controller.contains('addTransceiver'), isFalse,
          reason: 'a pre-negotiated share m-line on the call connection is the '
              'shared-PC design that failed twice — builds 59/60',);
      expect(session.contains('createPeerConnection'), isTrue,
          reason: 'the session must build its own connection',);
      expect(controller.contains('ScreenShareSession('), isTrue,
          reason: 'the controller must hand the share to a session',);
    });

    test('held share-ice is flushed AFTER the offer, never before', () {
      // The buffer exists because share-ice can arrive before the receive
      // session does. It was flushed one line too early, and onIce drops any
      // candidate reaching it while `_pc` is null — a guard meant for CLOSED
      // sessions — so the buffer discarded exactly what it was added to save
      // and the receive side negotiated on host candidates alone. onOffer is
      // what creates `_pc`, so the flush belongs after it. This has now been
      // written wrong twice (98291a1, then again in 3bd4fe8's cleanup).
      // Anchored on the copy, not on `.clear()` — that appears five times for
      // five different reasons and the first one is nowhere near this path.
      const copy = 'List<Map<dynamic, dynamic>>.from(_pendingShareIce)';
      final flush = controller.indexOf(copy);
      final offer = controller.indexOf('await session.onOffer(map)');
      expect(offer, greaterThan(-1), reason: 'the offer await must still exist');
      expect(flush, greaterThan(-1), reason: 'the flush must still exist');
      expect(controller.indexOf(copy, flush + 1), -1,
          reason: 'the anchor must stay unique or this ordering check is blind',);
      expect(flush, greaterThan(offer),
          reason: 'flushing before onOffer feeds every held candidate to the '
              'null-_pc drop guard — the bug this buffer exists to prevent',);
      expect(session.contains('_pc != null && _pendingIce.length'), isTrue,
          reason: 'the drop guard is load-bearing for the ordering above; if '
              'it moves, re-derive where the flush belongs',);
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
      // Bounded by the case BLOCK, not by a character count. The old window
      // was a fixed 700 chars, which made this assertion a function of comment
      // length: adding a comment above the assignment failed the test while
      // deleting the assignment entirely could still pass if something else
      // nearby matched. The block is the thing being asserted about.
      final blockEnd = controller.indexOf("case '", off + 6);
      expect(blockEnd, greaterThan(off));
      expect(
          controller
              .substring(off, blockEnd)
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
              "H264-promotion regression, and disturbing the call's "
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

    test('the sharer is never blind — the PiP carries faces during a share',
        () {
      final pip = File('lib/features/call/call_pip.dart').readAsStringSync();
      expect(
          pip.contains('if (call.sharingScreen) return const SizedBox.shrink'),
          isFalse,
          reason: 'hiding the window mid-share left the sharer with no call '
              'surface at all — the build-62 field complaint',);
      expect(pip.contains('pip-share-local'), isTrue);
      expect(pip.contains('pip-share-remote'), isTrue);
      expect(pip.contains('screenSelfRenderer'), isFalse,
          reason: 'faces only — a live share preview inside the captured '
              'display is the recursion tunnel',);
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

    test('a share that never produces a frame ends VISIBLY, not black', () {
      // Build 62 sat connected and black for 138 seconds. The never-started
      // watch first retries with the floor dropped, then ends the share and
      // stamps the digest with the reason.
      expect(session.contains('floorKbps: 50'), isTrue,
          reason: 'the one-shot floor-drop retry',);
      expect(session.contains('_neverStarted >= 20'), isTrue,
          reason: 'twenty frameless seconds after negotiation is a dead '
              'share, and hanging black is the worst possible answer',);
      expect(session.contains('_endReason = 2'), isTrue);
      expect(session.contains('endReason: _endReason'), isTrue,
          reason: 'the digest must say HOW the share ended',);
    });

    test('the resize event re-aims the running session', () {
      final at = controller.indexOf('miles.screenCaptureContentResize');
      expect(at, greaterThan(-1));
      expect(controller.substring(at, at + 1600).contains('retarget'), isTrue,
          reason: 'an app-scoped capture is smaller than the panel; scaling '
              'from the panel would shrink content that already fits',);
    });
  });

  group('the field record (BRAIN §220)', () {
    final logging = File('lib/core/app/logging.dart').readAsStringSync();

    test('share telemetry survives a release build', () {
      // silenceLogsInRelease() nulls debugPrint in EVERY release build, so the
      // original `_log => debugPrint(...)` could never print on a handset —
      // five builds of field tests ran blind on instrumentation that was born
      // dead. _log must route through shareLog, and shareLog's release branch
      // must use print, which the override cannot touch.
      expect(session.contains('static void _log(String msg) => shareLog(msg);'),
          isTrue,
          reason: 'share telemetry routed through debugPrint is silenced in '
              'release — the §220 blindness',);
      expect(logging.contains(r"print('MilesShare $msg');"), isTrue,
          reason: 'print is the one channel silenceLogsInRelease cannot null',);
      expect(session.contains("debugPrint('MilesShare"), isFalse,
          reason: 'the dead channel must not come back',);
    });

    test('the rung retry runs BEFORE the stats read', () {
      // The retry sat below getStats, where the stats-error early return
      // skipped it: a connection with flaky stats ran its whole life
      // unprofiled — the black-share class, again (audit round-2, defect I).
      final body = session.substring(session.indexOf('_sampleOnce() async'));
      final retry = body.indexOf('if (!_rungApplied) await _applyRung();');
      final stats = body.indexOf('pc.getStats()');
      expect(retry, greaterThan(-1));
      expect(stats, greaterThan(-1));
      expect(retry, lessThan(stats),
          reason: 'below the stats try, a getStats error skips the retry',);
    });

    test('a live share prints one field line per second', () {
      // cap (media-source fps) vs fps (outbound) is the discriminator that
      // separates "frames never left the capturer" from "frames died at the
      // encoder" — the exact question §220 could not answer from outside.
      // One string, two consumers: logcat and the long-press stats overlay.
      expect(session.contains(r"'s r$_rung fps="), isTrue);
      expect(session.contains(r'cap=${captureFps.toStringAsFixed(0)}'), isTrue);
      expect(session.contains('_log(_lastSample!)'), isTrue,
          reason: 'the HUD line and the logged line must be the SAME string, '
              'or the two records can disagree about the same second',);
    });

    test('share failures reach the user, mid-call', () {
      expect(controller.contains('String? _shareError;'), isTrue);
      expect(controller.contains('String? takeShareError()'), isTrue);
      expect(screen.contains('takeShareError()'), isTrue,
          reason: 'the call screen must consume it on notify — _lastError is '
              'only read at pop time and a share fails on a screen that '
              'stays up',);
      expect(controller.contains('shareEndMessage(session.endReason)'), isTrue,
          reason: 'a share that ended itself says why on screen',);
      expect(controller.contains(r"shareLog('capture FAILED: $e')"), isTrue,
          reason: 'the getDisplayMedia catch was catch (_) and cost a field '
              'session the exception text that named the refusal',);
    });

    test('the foreground service never fails silently', () {
      final fgs =
          File('lib/features/call/call_foreground.dart').readAsStringSync();
      expect(fgs.contains('fgs start(force='), isTrue);
      expect(fgs.contains('fgs type swap'), isTrue);
      expect(RegExp(r'catch \(_\) \{\s*\n\s*// Background-keepalive')
              .hasMatch(fgs),
          isFalse,
          reason: 'a swallowed startForeground failure is a share with no '
              "mediaProjection type and no trace — §205's one unverified "
              'link',);
    });
  });

  group('the share generation protocol (BRAIN §220 defects A/B/C/F/G/H)', () {
    test('every share signal carries the generation, and dispatch demuxes',
        () {
      expect(controller.contains('_shareSend('), isTrue,
          reason: 'the per-share send wrapper stamps share_id into every '
              'signal the session broadcasts',);
      expect(controller.contains("'share_id': shareId"), isTrue);
      expect(
          RegExp(r"matchesShare\(map\['share_id'\]\?\.toString\(\)\)")
              .allMatches(controller)
              .length,
          greaterThanOrEqualTo(3),
          reason: 'share-answer, share-ice and share-fail must all route by '
              'generation, not by whichever session is current',);
      expect(session.contains('bool matchesShare(String? sid)'), isTrue);
    });

    test('the sharer has a deadline on the answer, and re-offers', () {
      expect(session.contains('answerDeadline'), isTrue);
      expect(session.contains('Future<void> reoffer()'), isTrue);
      expect(controller.contains('s.reoffer()'), isTrue,
          reason: 'the resubscribe hook must re-send the OFFER, not only the '
              'announce — a share whose offer died in a channel outage was '
              'dead-but-"on" forever (§220 defect B)',);
      expect(session.contains('_endReason = 3'), isTrue,
          reason: 'retries exhausted is a loud failure, not a hang',);
    });

    test('a blip is a grace window, never an instant kill', () {
      // The receiver used to treat Disconnected as fatal alongside
      // Failed/Closed — one cellular blink permanently destroyed the share.
      final recvKill = RegExp(
        r'RTCPeerConnectionStateFailed \|\|\s*\n\s*s == RTCPeerConnectionState'
        r'\.RTCPeerConnectionStateClosed \|\|\s*\n\s*s == RTCPeerConnectionState'
        r'\.RTCPeerConnectionStateDisconnected',
      );
      expect(recvKill.hasMatch(session), isFalse,
          reason: 'Disconnected inside the immediate-kill condition is the '
              '§220 defect A',);
      expect(session.contains('disconnectGrace'), isTrue);
      expect(session.contains('restartIce()'), isTrue,
          reason: 'the sharer restarts ICE on the SAME connection',);
      expect(session.contains("'restart': true"), isTrue);
      expect(session.contains('recv restart answered'), isTrue,
          reason: 'the receiver answers a restart IN PLACE — a rebuild pays '
              'full ICE and a black gap for a 2s blip',);
      // The in-place path is only real if DISPATCH routes to the standing
      // session. Round-2 finding D1: every offer went through _receiveShare,
      // which closed the healthy PC and rebuilt — and a rebuilt answer's new
      // DTLS certificate kills the sharer's standing PC, so the "resilience"
      // converted every blip into silent share death.
      expect(controller.contains('standing.onOffer(map)'), isTrue,
          reason: 'a restart offer must reach the STANDING session',);
      expect(controller.contains('standing.resendAnswer()'), isTrue,
          reason: 'a duplicate plain offer means our answer was lost — '
              'resend it; a rebuild answers with a new certificate the '
              'sharer must reject',);
      expect(session.contains('recv restart offer with no standing pc'),
          isTrue,
          reason: 'the rebuild path must be unreachable for restart offers '
              'even if dispatch regresses',);
      expect(session.contains('send duplicate answer ignored'), isTrue,
          reason: 'the reoffer protocol can produce two answers; applying '
              'the second to a stable connection kills a share that just '
              'connected (D2)',);
    });

    test('the reoffer budget cannot be bypassed', () {
      // Round-2 finding D6: the budget lived in the deadline timer, and the
      // resubscribe hook called reoffer() directly — a flapping channel
      // re-offered unboundedly and the give-up never fired: the §220 hang,
      // recreated in exactly the unstable-network scenario it was built for.
      final reofferBody = session.substring(
        session.indexOf('Future<void> reoffer() async'),
        session.indexOf('void _armRestart('),
      );
      expect(reofferBody.contains('_offerRetries >= maxOfferRetries'), isTrue,
          reason: 'the budget check must live in reoffer() itself — every '
              'caller pays',);
      expect(reofferBody.contains('_offerRetries++'), isTrue);
    });

    test('a dead receive side tells the sharer to stop encoding', () {
      expect(RegExp(r"send\('share-fail'").allMatches(session).length,
          greaterThanOrEqualTo(3),
          reason: 'deadline, hard loss and grace expiry must all report',);
      expect(controller.contains("case 'share-fail':"), isTrue);
      expect(session.contains('Future<void> onShareFail()'), isTrue);
    });

    test("a dead sharer re-enables the partner's Screen button", () {
      expect(controller.contains('remoteSharePendingTimeout'), isTrue);
      expect(controller.contains('_armRemoteSharePendingTimeout'), isTrue,
          reason: 'remoteSharePending with no deadline disabled the button '
              'for the rest of the call after a sharer crash (§220 defect H)',);
    });

    test('the encoder scales from the CAPTURED surface, not the Flutter view',
        () {
      expect(session.contains('static Size captureSizeOf('), isTrue);
      expect(controller.contains('ScreenShareSession.captureSizeOf('), isTrue);
      expect(controller.contains('_captureSize ?? _displayPixels()'), isTrue,
          reason: 'the app-scoped gate must compare against the capture; in '
              'OS PiP the view is ~400px wide and everything reads as '
              '"scoped", which wrongly enables the recursion-hazard preview',);
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
      expect(java.contains('track_.putMap("settings", settings.toMap());'),
          isTrue,
          reason: 'the display track must expose the real captured surface '
              'size — getSettings() is otherwise EMPTY for display tracks and '
              'the app falls back to the Flutter view, wrong in split-screen '
              'and OS PiP (3rd Miles patch)',);
    });

    test('display audio is real: audio:true arms the playback mixer', () {
      final mixerFile = File(
        'third_party/flutter_webrtc/android/src/main/java/com/cloudwebrtc/webrtc/audio/PlaybackAudioMixer.java',
      );
      expect(mixerFile.existsSync(), isTrue,
          reason: '4th Miles patch: upstream discards audio:true entirely',);
      final mixer = mixerFile.readAsStringSync();
      expect(mixer.contains('AudioPlaybackCaptureConfiguration'), isTrue);
      expect(mixer.contains('READ_NON_BLOCKING'), isTrue,
          reason: 'a blocking read on the ADM record thread starves the mic',);
      expect(java.contains('withAudio'), isTrue,
          reason: 'the audio flag must survive into the private overload — '
              'upstream dropped the whole constraints map on the floor',);
      expect(java.contains('getMediaProjection()'), isTrue,
          reason: 'the mixer must ride the SAME projection as the capture; a '
              'consent token is single-use on Android 15+',);
      expect('playbackMixer = null'.allMatches(java).length, 1,
          reason: 'exactly ONE teardown path: capturer removal. The onStop '
              'callback fires SPURIOUSLY on some OEMs (the build-59 class) '
              'and releasing there cost an audio share its sound with no way '
              'back (round-2 finding F1) — the mixer has its own released '
              'latch against resurrection instead',);
      final mixer2 = File(
        'third_party/flutter_webrtc/android/src/main/java/com/cloudwebrtc/webrtc/audio/PlaybackAudioMixer.java',
      ).readAsStringSync();
      expect(mixer2.contains('volatile boolean released'), isTrue,
          reason: 'an in-flight onBuffer seeing record==null after release '
              'would lazily START a new capture on an orphaned mixer '
              '(round-2 finding F2)',);
      final handler = File(
        'third_party/flutter_webrtc/android/src/main/java/com/cloudwebrtc/webrtc/MethodCallHandlerImpl.java',
      ).readAsStringSync();
      expect(handler.contains('setAudioBufferCallback'), isTrue,
          reason: 'the mix point is the ADM buffer callback — after mute '
              'zeroing, so a muted mic keeps the shared media audible',);
    });
  });

  group('display audio, Dart side', () {
    test('the share asks for audio, and mute moves to the ADM during it', () {
      expect(
          controller.contains("getDisplayMedia({'video': true, 'audio': true})"),
          isTrue,);
      expect('Helper.setMicrophoneMute('.allMatches(controller).length, 1,
          reason: 'exactly one raw call site — the guarded _setAdmMute '
              'helper. Raw calls fail silently and cannot keep _admMuted '
              'true to reality (round-2 findings D4/D5)',);
      expect('_setAdmMute('.allMatches(controller).length,
          greaterThanOrEqualTo(5),
          reason: 'the definition, toggleMic during a share, the start-share '
              'migration, the stop-share restore, and the teardown clear — '
              'ADM mute is process-global and any missed path leaves the '
              'phone muted',);
      expect(controller.contains('if (_admMuted) {'), isTrue,
          reason: 'teardown gates on the tracked flag, never on call state: '
              'stopScreenShare flips sharingScreen before its unmute lands, '
              'and the race left every later call with a dead mic (D4)',);
      expect(controller.contains('adm unmute at teardown FAILED'), isTrue,
          reason: 'hangup mid-share bypasses stopScreenShare; teardown must '
              'clear the ADM mute itself',);
      final startAt = controller.indexOf('await _setAdmMute(true);');
      final enableAt = controller.indexOf('if (_admMuted) {', startAt);
      expect(startAt, greaterThan(-1));
      expect(enableAt, greaterThan(startAt),
          reason: 'the ADM mute must LAND before the track re-enables, or '
              'the mic is hot for the round trip (D5)',);
    });
  });
}
