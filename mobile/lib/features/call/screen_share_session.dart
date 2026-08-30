import 'dart:async';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:miles/core/app/logging.dart' show shareLog;
import 'package:miles/core/diag/diag.dart' show ShareQualityDigest;

/// The sentence the user sees when a share ended ITSELF, or null when the end
/// needs no message (a deliberate stop, or a superseded session).
///
/// Pure and top-level so a test can pin every mapping. The reasons are
/// [ScreenShareSession]'s `_endReason` values.
String? shareEndMessage(int endReason) => switch (endReason) {
      1 || 4 => 'Screen share ended: the connection dropped.',
      2 => 'Screen share failed — nothing could be sent. Try again.',
      3 => "Screen share couldn't connect. Try again.",
      _ => null,
    };

/// One screen share = one dedicated RTCPeerConnection.
///
/// This is Meet's architecture, adopted after the shared-connection design
/// failed twice (BRAIN §180). On a dedicated connection the share gets its own
/// bandwidth estimate — it cannot fight the camera for one uplink number and
/// the camera cannot starve it; its negotiation cannot disturb the call's; and
/// when it dies, it dies ALONE — the call never feels it.
///
/// The second lesson is baked into the ladder: quality is CLIMBED, never
/// gambled. The first frame goes out within a second at a rate any mobile
/// uplink can fund, and the encoder walks up to full 1080p-class sharpness as
/// clean samples prove the link — one clean second per rung when the share's
/// own bandwidth estimate already funds the next rung, two otherwise. The
/// failed design opened at the top (1920 + maintain-resolution on an unproven
/// estimate) and the encoder could never fund frame one — the receiver got
/// literally nothing.
///
/// Degradation stays BALANCED, deliberately: this codebase already tried
/// maintain-resolution for screencast and shipped "a viewer watching a picture
/// that sticks". Sharpness comes from the climb REACHING the top rung, not
/// from forbidding the encoder to breathe on the way there.
class ScreenShareSession {
  ScreenShareSession({
    required this.send,
    required this.iceConfig,
    required this.onRemoteStream,
    required this.onEnded,
    required this.stopHinted,
    this.shareId,
  });

  /// This share's generation. Minted by the sharer, adopted by the receiver
  /// from the offer, stamped into every share signal by the controller's send
  /// wrapper. Before it existed, `share-answer`/`share-ice` were routed to
  /// whatever `_shareSession` happened to be current, so two shares in quick
  /// succession cross-fed candidates into the wrong connection.
  final String? shareId;

  /// Whether a signal carrying [sid] belongs to this session. A missing id on
  /// either side matches — an old client that stamps nothing keeps working
  /// exactly as before the protocol existed.
  bool matchesShare(String? sid) =>
      sid == null || shareId == null || sid == shareId;

  /// Whether negotiation completed (the remote description landed). The
  /// controller re-offers on channel resubscribe while this is false.
  bool get negotiated => _remoteSet;

  /// Broadcasts one signal to the partner — the call controller's own `_send`,
  /// so share signalling rides the channel the call already trusts.
  final void Function(String kind, Map<String, dynamic> data) send;
  final Map<String, dynamic> iceConfig;

  /// Receiver side: the partner's display arrived.
  final void Function(MediaStream stream) onRemoteStream;

  /// Sharer side: the share is dead (stall confirmed, or the connection
  /// failed). The controller stops the capture and announces it.
  final void Function() onEnded;

  /// Whether the OS hinted a stop (the spurious-capable MediaProjection
  /// onStop). One zero-fps sample then suffices where three are otherwise
  /// required — the hint fast-tracks, it never kills (BRAIN §178).
  final bool Function() stopHinted;

  RTCPeerConnection? _pc;
  RTCRtpSender? _sender;
  Timer? _stats;
  bool _isSharer = false;
  bool get active => _pc != null;

  /// Candidates that arrived before the remote description; flushed after.
  final List<Map<String, dynamic>> _pendingIce = [];
  bool _remoteSet = false;

  // ── The climb ─────────────────────────────────────────────────────────
  //
  // Long edge, fps, the ceiling that funds them, and the floor under the
  // encoder's undershoot. Every rung is strictly richer than the one below;
  // the ladder is walked UP on clean samples and DOWN one rung the moment
  // the encoder reports cpu or bandwidth limitation. The ceilings are sized
  // for H.264, which needs roughly a quarter more bits than VP9 for the same
  // text — and a ceiling is what BWE ramps into, never an opening bid.
  //
  // THE FLOOR LAW (build 62's black share, field-proven): libwebrtc's
  // bandwidth estimator is BORN at ~300kbps, and a stream whose minBitrate
  // the estimate cannot fund is SUSPENDED — zero frames encoded, and with no
  // media the estimate never moves, so the share sits connected and black
  // forever (`fps0 bwe300` for 138s in the field). The start rung's floor
  // must therefore sit well under 300k; higher rungs only run once the
  // estimate has proven bigger, and may afford more.
  static const climb = <({int longEdge, int fps, int maxKbps, int minKbps})>[
    (longEdge: 960, fps: 15, maxKbps: 1200, minKbps: 100),
    (longEdge: 1280, fps: 20, maxKbps: 2000, minKbps: 150),
    (longEdge: 1920, fps: 24, maxKbps: 3500, minKbps: 250),
    (longEdge: 1920, fps: 30, maxKbps: 5000, minKbps: 300),
  ];

  int _rung = 0;
  int _cleanSamples = 0;
  int _stallSamples = 0;
  bool _sawFrames = false;
  bool _sampling = false;
  DateTime? _lastFallAt;
  Size _captureSize = const Size(1920, 1080);

  /// Samples since the answer landed with no frame EVER seen, and whether the
  /// one-shot floor drop has been tried. The never-started watch — distinct
  /// from the stall watchdog, which only fires after frames were seen.
  int _neverStarted = 0;
  bool _floorDropped = false;

  /// Whether the encoder profile has ever actually reached the sender, and how
  /// many attempts found nothing to write to.
  ///
  /// Kept because the failure this guards against was invisible: a share can
  /// run to completion with the profile never applied, which is a black or
  /// unwatchable picture with nothing in any log to say why. [_sampleOnce]
  /// retries while this is false.
  bool _rungApplied = false;
  int _rungSkips = 0;

  /// Consecutive getStats failures. See the catch in [_sampleOnce]: an early
  /// return there used to disable every watchdog in this class.
  int _statsErrors = 0;
  static const int statsErrorLimit = 15;

  // ── Sharer liveness (BRAIN §220 defect B) ─────────────────────────────
  //
  // The sharer had NO deadline of any kind on the answer: if `share-offer`
  // died on the wire — and the start sequence drives the app through paused
  // for the consent dialog, exactly when the realtime socket resets — the
  // share sat "on" forever with nothing transmitted and no way to know.
  // 10s spans one full resubscribe backoff cycle (1+2+4s) plus the subscribe
  // round trip; three offers total before a loud failure.
  static const answerDeadline = Duration(seconds: 10);
  static const int maxOfferRetries = 2;
  Timer? _answerWatch;
  int _offerRetries = 0;
  Map<String, dynamic>? _offerPayload;

  /// The sharer's own candidates, kept so a re-offer can re-broadcast them —
  /// the call PC caches its own for the same reason. Bounded like
  /// the controller's share-ice buffer.
  final List<Map<String, dynamic>> _localCands = [];

  // ── Blip resilience (BRAIN §220 defect A) ─────────────────────────────
  //
  // A 1–2s cellular ICE blip is routine. The sharer debounces `Disconnected`
  // three seconds (libwebrtc already burned ~2.5s of dead ICE reporting it),
  // then restarts ICE on the SAME connection and re-offers in place; it gives
  // up loudly after 12s. The receiver holds the last frame for 15s — a
  // backstop deliberately LONGER than the sharer's give-up, so the sharer
  // stays the authority — instead of killing the share on the first blink.
  static const restartDebounce = Duration(seconds: 3);
  static const disconnectGiveUp = Duration(seconds: 12);
  static const disconnectGrace = Duration(seconds: 15);
  static const int maxIceRestarts = 2;
  Timer? _restartDebounce;
  Timer? _disconnectGiveUp;
  Timer? _graceTimer;
  int _restarts = 0;

  /// Every share state transition, on one greppable tag: `adb logcat | grep MilesShare`.
  ///
  /// Not decoration. `Diag` records nothing in production
  /// (core/diag/diag.dart:349) and this handset's logcat ring is 256 KiB
  /// drowned in OS freeze/unfreeze spam, so an untagged debugPrint is not a
  /// diagnostic — it is a hope. Five builds shipped an unverified share partly
  /// because nothing it did could be seen from outside.
  ///
  /// Routed through [shareLog], NOT `debugPrint`: `silenceLogsInRelease()`
  /// nulls debugPrint in every release build, so the original version of this
  /// line could never print on a handset — the exact blindness it was written
  /// to end (BRAIN §220). Content contract: numbers and state words only.
  static void _log(String msg) => shareLog(msg);

  /// How this share ended, for the digest: 0 stopped, 1 stalled after frames,
  /// 2 never produced a frame at all.
  int _endReason = 0;

  /// Read by the controller's `onEnded` to pick the sentence the user sees
  /// ([shareEndMessage]). Read it BEFORE `close()`, which resets it.
  int get endReason => _endReason;

  /// The newest per-second sample line, for the long-press stats overlay.
  String? _lastSample;
  String? get hudLine => _lastSample;

  // What this share actually did, for the one digest row it reports when it
  // ends. Counters only — nothing user-generated.
  DateTime? _shareStart;
  int _climbs = 0;
  int _falls = 0;
  int _cpuSamples = 0;
  int _bwSamples = 0;
  int _topRung = 0;
  int _lastBweKbps = 0;
  String _codec = '';
  final List<double> _fpsRing = [];

  /// The truth about the captured surface, read off the display track's
  /// settings — filled by the vendored fork from the exact value the native
  /// capturer received (`display.getRealSize()`). Falls back (the Flutter
  /// view's size) only when the settings are absent or malformed — an old
  /// fork build. The fallback diverges from the capture in split-screen and
  /// OS PiP, which mis-scales the encoder: the §220 black-share class.
  static Size captureSizeOf(Map<String, dynamic> settings, Size fallback) {
    final w = settings['width'];
    final h = settings['height'];
    if (w is num && h is num && w > 0 && h > 0) {
      return Size(w.toDouble(), h.toDouble());
    }
    return fallback;
  }

  /// The capture's long edge divided by the rung's target — never below 1
  /// (never upscale).
  static double scaleFor(Size capture, int longEdge) {
    final longest =
        capture.width > capture.height ? capture.width : capture.height;
    final s = longest / longEdge;
    return s < 1.0 ? 1.0 : s;
  }

  // ── Sharer ────────────────────────────────────────────────────────────

  Future<void> startSharing(
    MediaStreamTrack track,
    MediaStream stream,
    Size captureSize,
  ) async {
    _isSharer = true;
    _captureSize = captureSize;
    final pc = await createPeerConnection(iceConfig);
    _pc = pc;
    _wireIce(pc);
    pc.onConnectionState = (s) {
      if (!identical(pc, _pc)) return;
      _log('send state=${s.name}');
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        // Still the current PC (close() nulls _pc before closing, so a
        // deliberate stop never reaches this line): the link is gone. A
        // straight-to-Failed transition skips Disconnected, so the give-up
        // timer never armed — without a reason here the death was silent.
        _endReason = 4;
        onEnded();
      } else if (s ==
          RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _armRestart(pc);
      } else if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _restartDebounce?.cancel();
        _restartDebounce = null;
        _disconnectGiveUp?.cancel();
        _disconnectGiveUp = null;
      }
    };
    _sender = await pc.addTrack(track, stream);
    // Send-only: this connection exists to carry one display one way. Best
    // effort — a SendRecv m-line still works, it just offers a direction
    // nobody uses.
    try {
      final ts = await pc.getTransceivers();
      if (ts.isNotEmpty) {
        await ts.first.setDirection(TransceiverDirection.SendOnly);
      }
    } catch (e) {
      debugPrint('[share] setDirection: $e');
    }
    // H.264 first — ISOLATED on this dedicated connection, where a preference
    // cannot disturb the call's own negotiation. H.264 because it is the one
    // codec with a HARDWARE encoder on effectively every Android handset;
    // neither owner phone has a VP9 encoder at all, so a VP9 preference here
    // meant libvpx software-encoding the whole display — the cpu-limited,
    // laggy, never-climbing share the field report described. A preference
    // with fallback, never a requirement.
    try {
      final caps = await getRtpSenderCapabilities('video');
      final codecs = caps.codecs ?? const [];
      final h264 = [
        for (final c in codecs)
          if (c.mimeType.toLowerCase() == 'video/h264') c,
      ];
      if (h264.isNotEmpty) {
        final ts = await pc.getTransceivers();
        if (ts.isNotEmpty) {
          await ts.first.setCodecPreferences([
            ...h264,
            for (final c in codecs)
              if (c.mimeType.toLowerCase() != 'video/h264') c,
          ]);
        }
      }
    } catch (e) {
      debugPrint('[share] codec preference: $e');
    }
    await _applyRung();
    try {
      final offer = await pc.createOffer({});
      if (!identical(pc, _pc)) {
        // The session was closed underneath us mid-negotiation. Returning
        // quietly here used to leave the controller with sharingScreen true
        // and no offer ever sent — a share that is "on" forever and does
        // nothing. Say so, and let the controller unwind.
        _log('send superseded during createOffer');
        onEnded();
        return;
      }
      await pc.setLocalDescription(offer);
      _offerPayload = {'sdp': offer.sdp, 'type': offer.type};
      send('share-offer', _offerPayload!);
      _log('send offered');
      _armAnswerWatch();
    } catch (e) {
      _log('send offer FAILED: $e');
      _endReason = 3;
      onEnded();
      return;
    }
    _shareStart = DateTime.now();
    _stats = Timer.periodic(const Duration(seconds: 1), (_) => _sample());
  }

  void _armAnswerWatch() {
    _answerWatch?.cancel();
    _answerWatch = Timer(answerDeadline, () {
      if (_remoteSet || _pc == null || !_isSharer) return;
      unawaited(reoffer());
    });
  }

  /// Re-broadcast the standing offer and every cached local candidate — the
  /// receiver's rebuild path answers it whether or not it saw the first copy.
  /// Also called by the controller when the signalling channel resubscribes:
  /// `screen{on:true}` was the only share signal re-announced there, so a
  /// share whose offer died in a channel outage stayed dead-but-"on" forever.
  ///
  /// The retry budget is consumed HERE, not in the deadline timer — the
  /// resubscribe path used to bypass it, so a flapping channel re-offered
  /// unboundedly and the give-up could never fire: the §220 hang, recreated
  /// in exactly the unstable-network scenario this exists for.
  Future<void> reoffer() async {
    final payload = _offerPayload;
    if (!_isSharer || payload == null || _remoteSet || _pc == null) return;
    if (_offerRetries >= maxOfferRetries) {
      _log('send answer never arrived after ${_offerRetries + 1} offers — '
          'ending');
      _endReason = 3;
      onEnded();
      return;
    }
    _offerRetries++;
    _log('send re-offer #$_offerRetries cands=${_localCands.length}');
    send('share-offer', {...payload, 'attempt': _offerRetries});
    for (final c in _localCands) {
      send('share-ice', c);
    }
    _armAnswerWatch();
  }

  void _armRestart(RTCPeerConnection pc) {
    _disconnectGiveUp ??= Timer(disconnectGiveUp, () {
      if (!identical(pc, _pc)) return;
      _log('send link lost for ${disconnectGiveUp.inSeconds}s — ending');
      _endReason = 4;
      onEnded();
    });
    _restartDebounce?.cancel();
    _restartDebounce = Timer(restartDebounce, () {
      if (!identical(pc, _pc)) return;
      unawaited(_restartIce(pc));
    });
  }

  /// New ICE credentials on the SAME connection — the receiver answers in
  /// place, no rebuild, no black gap. `restartIce()` only flags the need; the
  /// fresh ufrag/pwd ride the next offer.
  Future<void> _restartIce(RTCPeerConnection pc) async {
    if (_restarts >= maxIceRestarts) return; // the give-up timer decides
    _restarts++;
    try {
      await pc.restartIce();
      final offer = await pc.createOffer({});
      if (!identical(pc, _pc)) return;
      await pc.setLocalDescription(offer);
      send('share-offer', {
        'sdp': offer.sdp,
        'type': offer.type,
        'restart': true,
      });
      _log('send ICE restart #$_restarts offered');
    } catch (e) {
      _log('send ICE restart FAILED: $e');
    }
  }

  /// The receiver said its side died (`share-fail`). Restart if budget
  /// remains; otherwise stop encoding into the void — without this the sharer
  /// kept the capture and encoder running forever after a dead receive.
  Future<void> onShareFail() async {
    final pc = _pc;
    if (pc == null || !_isSharer) return;
    if (_restarts >= maxIceRestarts) {
      _log('recv reported failure after $_restarts restarts — ending');
      _endReason = 4;
      onEnded();
      return;
    }
    _log('recv reported failure — restarting');
    await _restartIce(pc);
  }

  /// Android 14 reported the real captured-content size (an app window is
  /// smaller than the panel): re-aim the current rung at it.
  Future<void> retarget(Size captureSize) async {
    _captureSize = captureSize;
    await _applyRung();
  }

  Future<void> _applyRung({int? floorKbps}) async {
    final pc = _pc;
    if (pc == null) return;
    final r = climb[_rung];
    try {
      // Re-read the sender from the connection. NEVER reuse the one captured
      // at addTrack.
      //
      // This is the defect that made the share black. In the vendored plugin
      // `RTCRtpSender.parameters` is a plain field
      // (third_party/flutter_webrtc/lib/src/native/rtc_rtp_sender_impl.dart:138)
      // filled once from the addTrack response and thereafter written only by
      // our own setParameters — it is never re-read from native. Before
      // negotiation that response usually carries NO encodings, so the guard
      // below returned early; and because the snapshot could not refresh, the
      // onAnswer re-assert that exists precisely to cover that case returned
      // early too, for the entire life of the share. The sender then ran
      // completely unprofiled: no scale, no fps cap, no ceiling and — the one
      // that kills — no floor. That is the unfunded start of BRAIN §180 and
      // the connected-and-black share of §186, reintroduced through a cache.
      //
      // getSenders() rebuilds each sender with RTCRtpParameters.fromMap of a
      // fresh native read, which is what every other setParameters site in
      // this app (call_controller.dart:1271) already did.
      final senders = await pc.getSenders();
      if (!identical(pc, _pc)) return;
      RTCRtpSender? sender;
      for (final s in senders) {
        if (s.track?.kind == 'video') {
          sender = s;
          break;
        }
      }
      if (sender == null && senders.isNotEmpty) sender = senders.first;
      sender ??= _sender;
      if (sender == null) {
        _rungSkips++;
        _log('rung$_rung SKIP no-sender n=$_rungSkips');
        return;
      }
      final params = sender.parameters;
      final encodings = params.encodings;
      if (encodings == null || encodings.isEmpty) {
        // Not a no-op worth swallowing: an unprofiled screencast sender opens
        // at the whole panel's pixel rate with no floor under it. Counted and
        // announced so _sampleOnce retries it, and so this can never again be
        // silent for the life of a share.
        _rungSkips++;
        _log('rung$_rung SKIP no-encodings n=$_rungSkips');
        return;
      }
      final scale = scaleFor(_captureSize, r.longEdge);
      final floor = floorKbps ?? r.minKbps;
      for (final e in encodings) {
        e
          ..scaleResolutionDownBy = scale
          ..maxFramerate = r.fps
          ..maxBitrate = r.maxKbps * 1000
          ..minBitrate = floor * 1000;
      }
      params.degradationPreference = RTCDegradationPreference.BALANCED;
      await sender.setParameters(params);
      _sender = sender;
      _rungApplied = true;
      _log('rung$_rung APPLIED scale=${scale.toStringAsFixed(2)} '
          'fps=${r.fps} max=${r.maxKbps}k min=${floor}k');
    } catch (e) {
      // The share still runs at whatever libwebrtc picked; a profile is an
      // improvement, never a precondition.
      _log('rung$_rung apply failed: $e');
    }
  }

  /// Whether one sample says the link is carrying this rung comfortably.
  ///
  /// Capture-aware on purpose: Android's screen capturer only produces frames
  /// when the display CHANGES, so a shared document sits at near-zero encoded
  /// fps while perfectly healthy — and static text is exactly the content
  /// that needs the top rung most. An fps-only gate would pin it at the
  /// blurry bottom forever. So fps must keep up only with what the capturer
  /// actually produced ([captureFps]); when the capturer is idle (or the stat
  /// is absent), the limitation reason alone decides. The encoder secretly
  /// struggling is still caught: libwebrtc's overuse detector reports 'cpu'
  /// when it drops frames under load.
  @visibleForTesting
  static bool isClean({
    required String limitation,
    required double fps,
    required double captureFps,
    required int rungFps,
  }) {
    // '' = no outbound report yet (every share's first second). Not evidence.
    if (limitation.isEmpty) return false;
    if (limitation == 'cpu' || limitation == 'bandwidth') return false;
    if (captureFps <= 0) return true;
    final target = rungFps < captureFps ? rungFps.toDouble() : captureFps;
    return fps >= 0.8 * target;
  }

  /// Clean samples needed before the next rung: one when the share's own
  /// bandwidth estimate already funds it with 30% headroom, two otherwise —
  /// and never the fast path within ten seconds of a fall, or a link hovering
  /// at a rung boundary oscillates once a second.
  @visibleForTesting
  static int samplesNeeded({
    required int bweKbps,
    required int nextRungMaxKbps,
    required bool recentFall,
  }) =>
      !recentFall && bweKbps >= 1.3 * nextRungMaxKbps ? 1 : 2;

  Future<void> _sample() async {
    // One tick at a time: a stats round trip that outlives its second must
    // not stack a second one on top of it.
    if (_pc == null || !_isSharer || _sampling) return;
    _sampling = true;
    try {
      await _sampleOnce();
    } finally {
      _sampling = false;
    }
  }

  Future<void> _sampleOnce() async {
    final pc = _pc;
    if (pc == null) return;
    // Keep trying to profile the sender until it takes — BEFORE the stats
    // read, not after it. This retry used to sit below the getStats try, where
    // the stats-error early return skipped it: a connection with flaky stats
    // could run its whole life unprofiled, the exact black-share class the
    // retry exists to close (audit round-2, defect I).
    if (!_rungApplied) await _applyRung();
    if (!identical(pc, _pc)) return;
    double fps = 0;
    double captureFps = 0;
    var limitation = '';
    String? codecId;
    try {
      final reports = await pc.getStats();
      final byId = {for (final r in reports) r.id: r};
      StatsReport? pair;
      for (final r in reports) {
        final v = r.values;
        final kind = (v['kind'] ?? v['mediaType'])?.toString();
        switch (r.type) {
          case 'outbound-rtp':
            if (kind == 'video') {
              fps = double.tryParse(
                      v['framesPerSecond']?.toString() ?? '',) ??
                  0;
              limitation = v['qualityLimitationReason']?.toString() ?? '';
              codecId = v['codecId']?.toString();
            }
          case 'media-source':
            if (kind == 'video') {
              captureFps = double.tryParse(
                      v['framesPerSecond']?.toString() ?? '',) ??
                  0;
            }
          case 'transport':
            final id = v['selectedCandidatePairId']?.toString();
            if (id != null && byId[id] != null) pair = byId[id];
        }
      }
      pair ??= reports
          .where((r) =>
              r.type == 'candidate-pair' &&
              r.values['nominated'] == true &&
              r.values['state'] == 'succeeded',)
          .firstOrNull;
      final bwe = double.tryParse(
          pair?.values['availableOutgoingBitrate']?.toString() ?? '',);
      if (bwe != null && bwe > 0) _lastBweKbps = bwe ~/ 1000;
      final mime = codecId == null
          ? null
          : byId[codecId]?.values['mimeType']?.toString();
      if (mime != null && mime.contains('/')) {
        _codec = mime.split('/').last.toLowerCase();
      }
    } catch (e) {
      // A connection mid-close answers getStats with an error, and the next
      // tick usually finds it gone or working — so one failure is not news.
      //
      // But returning unconditionally meant a connection whose stats ALWAYS
      // error advanced neither the stall counter nor the never-started one, so
      // nothing was watching it at all: it could sit black and connected
      // forever with every watchdog in this class disabled by the early
      // return. Persistent failure is itself a dead share.
      if (++_statsErrors >= statsErrorLimit) {
        _log('stats errored ${_statsErrors}x — ending: $e');
        _endReason = 2;
        onEnded();
      }
      return;
    }
    _statsErrors = 0;

    // The per-second field record. One content-free line while a share is
    // live; this is what turns the next device run from a guess into a
    // reading. `cap` (media-source fps) is the §220 discriminator: a positive
    // cap with zero fps means frames reach the WebRTC source and die at the
    // encoder; a zero cap means they never left the capturer. It feeds the
    // long-press stats overlay ([hudLine]) — the on-device proof that every
    // encoder setting actually took, which no share build ever had.
    _lastSample = 's r$_rung fps=${fps.toStringAsFixed(0)} '
        'cap=${captureFps.toStringAsFixed(0)} '
        'lim=${limitation.isEmpty ? '-' : limitation} '
        'bwe=${_lastBweKbps}k codec=${_codec.isEmpty ? '?' : _codec} '
        'applied=$_rungApplied skips=$_rungSkips never=$_neverStarted';
    _log(_lastSample!);

    _fpsRing.add(fps);
    if (_fpsRing.length > 300) _fpsRing.removeAt(0);

    // The stall check — the only thing that may END a share, and only on the
    // real evidence of frames having stopped. Thresholds are sample counts at
    // a 1s cadence: the same 2s hinted / 6s unhinted wall clock that survived
    // field use, NOT a faster kill. The clean gate's fps threshold plays no
    // part here — this reads raw zero only.
    if (fps > 0) {
      _sawFrames = true;
      _stallSamples = 0;
    } else if (_sawFrames) {
      if (++_stallSamples >= (stopHinted() ? 2 : 6)) {
        _endReason = 1;
        onEnded();
        return;
      }
    } else if (_remoteSet) {
      // Negotiated, connected — and not one frame yet. Build 62 sat here,
      // connected and black, for 138 seconds. First a one-shot retry with the
      // floor dropped to nothing (against any allocator refusing to fund the
      // configured minimum); if the encoder still never starts, END VISIBLY —
      // the receiver's letterbox falls with the 'screen off' announcement,
      // and the digest names the death instead of a person guessing at it.
      _neverStarted++;
      if (_neverStarted == 10 && !_floorDropped) {
        _floorDropped = true;
        await _applyRung(floorKbps: 50);
      } else if (_neverStarted >= 20) {
        _endReason = 2;
        onEnded();
        return;
      }
    }

    if (limitation == 'cpu' || limitation == 'bandwidth') {
      if (limitation == 'cpu') {
        _cpuSamples++;
      } else {
        _bwSamples++;
      }
      _cleanSamples = 0;
      _lastFallAt = DateTime.now();
      if (_rung > 0) {
        _rung--;
        _falls++;
        await _applyRung();
      }
      return;
    }

    if (_rung >= climb.length - 1) return;
    if (!isClean(
      limitation: limitation,
      fps: fps,
      captureFps: captureFps,
      rungFps: climb[_rung].fps,
    )) {
      return;
    }
    final fell = _lastFallAt;
    final needed = samplesNeeded(
      bweKbps: _lastBweKbps,
      nextRungMaxKbps: climb[_rung + 1].maxKbps,
      recentFall: fell != null &&
          DateTime.now().difference(fell) < const Duration(seconds: 10),
    );
    if (++_cleanSamples >= needed) {
      _cleanSamples = 0;
      _rung++;
      _climbs++;
      if (_rung > _topRung) _topRung = _rung;
      await _applyRung();
    }
  }

  /// The share's one-line performance record, or null when there is nothing
  /// worth a row (receive side, or a share too short to say anything).
  /// Consumed by the controller at share end; the session deliberately knows
  /// nothing about reporting.
  ShareQualityDigest? takeDigest() {
    final start = _shareStart;
    if (!_isSharer || start == null) return null;
    final duration = DateTime.now().difference(start);
    if (duration.inSeconds <= 5) return null;
    _shareStart = null;
    final sorted = List<double>.of(_fpsRing)..sort();
    return ShareQualityDigest(
      codec: _codec.isEmpty ? 'unknown' : _codec,
      finalRung: _rung,
      topRung: _topRung,
      durationS: duration.inSeconds,
      climbs: _climbs,
      falls: _falls,
      cpu: _cpuSamples,
      bw: _bwSamples,
      fpsP50: sorted.isEmpty ? 0 : sorted[sorted.length ~/ 2].round(),
      bweKbps: _lastBweKbps,
      endReason: _endReason,
    );
  }

  // ── Receiver ──────────────────────────────────────────────────────────

  /// How long the receiver waits for the partner's display before giving up.
  ///
  /// The receiving side previously had NO watchdog of any kind: `onOffer` set
  /// no connection-state handler and started no timer — only the sharer did.
  /// So every way this negotiation could fail ended the same way, with the
  /// viewer holding a black full-screen letterbox that had already replaced
  /// their partner's face, forever, with nothing to clear it.
  static const receiveDeadline = Duration(seconds: 15);

  Timer? _receiveWatch;

  /// The receiver's standing answer, kept so a duplicate offer (the sharer
  /// re-offering because OUR answer died on the wire) is answered by
  /// RESENDING it. Rebuilding instead — the old behaviour — produced an
  /// answer with a new DTLS certificate that the sharer's standing PC
  /// rejects: the retry protocol killing the share it exists to save.
  Map<String, dynamic>? _answerPayload;

  Future<void> resendAnswer() async {
    final a = _answerPayload;
    if (a == null || _isSharer || _pc == null) return;
    _log('recv re-sent answer cands=${_localCands.length}');
    send('share-answer', a);
    for (final c in _localCands) {
      send('share-ice', c);
    }
  }

  Future<void> onOffer(Map<dynamic, dynamic> map) async {
    // An in-place ICE restart from the sharer: same share, same connection,
    // fresh credentials. Answer on the standing PC — a rebuild here pays full
    // ICE and a black gap for what is a 2-second blip on the sharer's side.
    // Every other shape (no PC yet, never negotiated, or a genuinely new
    // share) falls through to the rebuild below, which also handles a restart
    // offer arriving after this side already tore down.
    final restartPc = _pc;
    if (map['restart'] == true &&
        !_isSharer &&
        restartPc != null &&
        _remoteSet) {
      try {
        await restartPc.setRemoteDescription(RTCSessionDescription(
          map['sdp']?.toString(),
          map['type']?.toString(),
        ),);
        if (!identical(restartPc, _pc)) return;
        final answer = await restartPc.createAnswer();
        if (!identical(restartPc, _pc)) return;
        await restartPc.setLocalDescription(answer);
        _answerPayload = {'sdp': answer.sdp, 'type': answer.type};
        send('share-answer', _answerPayload!);
        _graceTimer?.cancel();
        _graceTimer = null;
        _log('recv restart answered');
      } catch (e) {
        _log('recv restart FAILED: $e');
        send('share-fail', {'reason': 'failed'});
        onEnded();
      }
      return;
    }
    if (map['restart'] == true) {
      // A restart offer with no standing negotiated connection must NEVER
      // take the rebuild path below: the rebuilt answer carries a NEW DTLS
      // certificate, which the sharer's standing PC rejects — killing the
      // share it was trying to save. The controller answers this case with
      // `share-fail` instead; here it is only a guard against re-entry.
      _log('recv restart offer with no standing pc — ignored');
      return;
    }
    _isSharer = false;
    await close();
    RTCPeerConnection? pc;
    try {
      pc = await createPeerConnection(iceConfig);
      _pc = pc;
      _wireIce(pc);
      final self = pc;
      pc.onConnectionState = (s) {
        if (!identical(self, _pc)) return;
        _log('recv state=${s.name}');
        if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            s == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
          send('share-fail', {'reason': 'failed'});
          onEnded();
        } else if (s ==
            RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          // A blip, until proven otherwise: hold the last frame and give the
          // sharer's own restart (3s debounce, 12s give-up) time to land.
          // Killing the receive side here — the old behaviour — destroyed
          // every share the first time a cellular link blinked, and the
          // sharer kept encoding into the void with no way to learn.
          _graceTimer ??= Timer(disconnectGrace, () {
            if (!identical(self, _pc)) return;
            _log('recv link lost for ${disconnectGrace.inSeconds}s — ending');
            send('share-fail', {'reason': 'disconnected'});
            onEnded();
          });
        } else if (s ==
            RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _graceTimer?.cancel();
          _graceTimer = null;
        }
      };
      pc.onTrack = (event) {
        // Guarded: without an identity check a late event from a superseded
        // connection re-points the renderer at a dead track.
        if (!identical(self, _pc)) return;
        if (event.track.kind != 'video') return;
        final stream = event.streams.isNotEmpty ? event.streams.first : null;
        if (stream == null) {
          _log('recv track with NO stream — nothing to render');
          return;
        }
        _receiveWatch?.cancel();
        _receiveWatch = null;
        _log('recv first stream');
        onRemoteStream(stream);
      };
      await pc.setRemoteDescription(RTCSessionDescription(
        map['sdp']?.toString(),
        map['type']?.toString(),
      ),);
      if (!identical(pc, _pc)) return;
      _remoteSet = true;
      await _flushIce();
      final answer = await pc.createAnswer();
      if (!identical(pc, _pc)) return;
      await pc.setLocalDescription(answer);
      _answerPayload = {'sdp': answer.sdp, 'type': answer.type};
      send('share-answer', _answerPayload!);
      _log('recv answered');
      // Nothing arriving is a failure with a deadline, not a wait forever.
      _receiveWatch = Timer(receiveDeadline, () {
        if (!identical(pc, _pc)) return;
        _log('recv DEADLINE — no display in ${receiveDeadline.inSeconds}s');
        // Tell the sharer: without this it keeps capturing and encoding into
        // a receive side that no longer exists (§220 — the 20s never-started
        // suicide was the only thing that ever stopped it).
        send('share-fail', {'reason': 'deadline'});
        onEnded();
      });
    } catch (e) {
      // Every one of these awaits used to throw straight out of an
      // `unawaited(...)` call with no catch — an invisible unhandled async
      // error, and a viewer left black with no signal that anything failed.
      _log('recv FAILED: $e');
      onEnded();
    }
  }

  Future<void> onAnswer(Map<dynamic, dynamic> map) async {
    final pc = _pc;
    if (pc == null || !_isSharer) return;
    if (_remoteSet) {
      // The reoffer protocol can legitimately produce a second copy of the
      // answer (a re-offer crossing the first answer on the wire). Applying
      // it to a stable connection throws wrong-state, which used to read as
      // a failure and killed the share right after it connected.
      _log('send duplicate answer ignored');
      return;
    }
    try {
      await pc.setRemoteDescription(RTCSessionDescription(
        map['sdp']?.toString(),
        map['type']?.toString(),
      ),);
      if (!identical(pc, _pc)) return;
      _remoteSet = true;
      _answerWatch?.cancel();
      _answerWatch = null;
      await _flushIce();
      _log('send answered, negotiated');
      // Re-assert the rung now that negotiation is done. Before the answer the
      // sender often reports NO encodings, so the pre-offer apply can no-op —
      // and an unprofiled screencast sender opens at the full display's pixel
      // rate, which is the unfunded start this design exists to end. This only
      // became true once _applyRung stopped reading a snapshot that could
      // never refresh; see the note there.
      await _applyRung();
    } catch (e) {
      _log('send answer FAILED: $e');
      // Negotiation failed — say so; endReason 0 here read as a deliberate
      // stop and the death was invisible.
      _endReason = 3;
      onEnded();
    }
  }

  Future<void> onIce(Map<dynamic, dynamic> map) async {
    final m = <String, dynamic>{
      'candidate': map['candidate']?.toString(),
      'sdpMid': map['sdpMid']?.toString(),
      'sdpMLineIndex': map['sdpMLineIndex'] is num
          ? (map['sdpMLineIndex'] as num).toInt()
          : null,
    };
    if (!_remoteSet) {
      // Only while a connection is actually being negotiated. After close()
      // _remoteSet is false too, and without the _pc check every late
      // candidate accumulated on a dead session's list forever.
      if (_pc != null && _pendingIce.length < 128) _pendingIce.add(m);
      return;
    }
    await _addIce(m);
  }

  void _wireIce(RTCPeerConnection pc) {
    pc.onIceCandidate = (c) {
      final m = <String, dynamic>{
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      };
      // BOTH sides keep their candidates so a re-offer (sharer) or re-sent
      // answer (receiver) can re-broadcast them: the first batch goes out
      // within ~1s of the SDP, exactly the window a channel outage eats.
      // Bounded like every other ICE buffer.
      if (_localCands.length < 64) _localCands.add(m);
      send('share-ice', m);
    };
  }

  Future<void> _flushIce() async {
    final pending = List<Map<String, dynamic>>.of(_pendingIce);
    _pendingIce.clear();
    for (final m in pending) {
      await _addIce(m);
    }
  }

  Future<void> _addIce(Map<String, dynamic> m) async {
    try {
      await _pc?.addCandidate(RTCIceCandidate(
        m['candidate'] as String?,
        m['sdpMid'] as String?,
        m['sdpMLineIndex'] as int?,
      ),);
    } catch (e) {
      debugPrint('[share] addCandidate: $e');
    }
  }

  Future<void> close() async {
    _stats?.cancel();
    _stats = null;
    _receiveWatch?.cancel();
    _receiveWatch = null;
    _answerWatch?.cancel();
    _answerWatch = null;
    _restartDebounce?.cancel();
    _restartDebounce = null;
    _disconnectGiveUp?.cancel();
    _disconnectGiveUp = null;
    _graceTimer?.cancel();
    _graceTimer = null;
    _offerPayload = null;
    _answerPayload = null;
    _offerRetries = 0;
    _restarts = 0;
    _localCands.clear();
    _lastSample = null;
    final pc = _pc;
    _pc = null;
    _sender = null;
    _remoteSet = false;
    _pendingIce.clear();
    _rung = 0;
    _cleanSamples = 0;
    _stallSamples = 0;
    _sawFrames = false;
    _sampling = false;
    _lastFallAt = null;
    _shareStart = null;
    _climbs = 0;
    _falls = 0;
    _cpuSamples = 0;
    _bwSamples = 0;
    _topRung = 0;
    _lastBweKbps = 0;
    _codec = '';
    _fpsRing.clear();
    _neverStarted = 0;
    _floorDropped = false;
    _rungApplied = false;
    _rungSkips = 0;
    _statsErrors = 0;
    _endReason = 0;
    if (pc != null) {
      try {
        await pc.close();
      } catch (_) {}
      try {
        await pc.dispose();
      } catch (_) {}
    }
  }
}
