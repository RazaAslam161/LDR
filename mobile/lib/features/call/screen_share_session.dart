import 'dart:async';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:miles/core/diag/diag.dart' show ShareQualityDigest;

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
  });

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
  // Long edge, fps, and the ceiling that funds them. Every rung is strictly
  // richer than the one below; the ladder is walked UP on clean samples and
  // DOWN one rung the moment the encoder reports cpu or bandwidth limitation.
  // The ceilings are sized for H.264, which needs roughly a quarter more bits
  // than VP9 for the same text — and a ceiling is what BWE ramps into, never
  // an opening bid.
  static const climb = <({int longEdge, int fps, int maxKbps})>[
    (longEdge: 960, fps: 15, maxKbps: 1200),
    (longEdge: 1280, fps: 20, maxKbps: 2000),
    (longEdge: 1920, fps: 24, maxKbps: 3500),
    (longEdge: 1920, fps: 30, maxKbps: 5000),
  ];

  /// The floor that stops the encoder's undershoot starving a static page
  /// into mush between refreshes; low enough that rung 0 always funds.
  static const minKbps = 300;

  int _rung = 0;
  int _cleanSamples = 0;
  int _stallSamples = 0;
  bool _sawFrames = false;
  bool _sampling = false;
  DateTime? _lastFallAt;
  Size _captureSize = const Size(1920, 1080);

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
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        onEnded();
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
    final offer = await pc.createOffer({});
    if (!identical(pc, _pc)) return;
    await pc.setLocalDescription(offer);
    send('share-offer', {'sdp': offer.sdp, 'type': offer.type});
    _shareStart = DateTime.now();
    _stats = Timer.periodic(const Duration(seconds: 1), (_) => _sample());
  }

  /// Android 14 reported the real captured-content size (an app window is
  /// smaller than the panel): re-aim the current rung at it.
  Future<void> retarget(Size captureSize) async {
    _captureSize = captureSize;
    await _applyRung();
  }

  Future<void> _applyRung() async {
    final sender = _sender;
    if (sender == null) return;
    final r = climb[_rung];
    try {
      final params = sender.parameters;
      final encodings = params.encodings;
      if (encodings == null || encodings.isEmpty) return;
      for (final e in encodings) {
        e
          ..scaleResolutionDownBy = scaleFor(_captureSize, r.longEdge)
          ..maxFramerate = r.fps
          ..maxBitrate = r.maxKbps * 1000
          ..minBitrate = minKbps * 1000;
      }
      params.degradationPreference = RTCDegradationPreference.BALANCED;
      await sender.setParameters(params);
    } catch (e) {
      // The share still runs at whatever libwebrtc picked; a profile is an
      // improvement, never a precondition.
      debugPrint('[share] rung $_rung apply: $e');
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
    } catch (_) {
      // A connection mid-close answers getStats with an error; the next tick
      // either finds it gone or finds it working.
      return;
    }

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
    );
  }

  // ── Receiver ──────────────────────────────────────────────────────────

  Future<void> onOffer(Map<dynamic, dynamic> map) async {
    _isSharer = false;
    await close();
    final pc = await createPeerConnection(iceConfig);
    _pc = pc;
    _wireIce(pc);
    pc.onTrack = (event) {
      if (event.track.kind != 'video') return;
      final stream = event.streams.isNotEmpty
          ? event.streams.first
          : null;
      if (stream != null) onRemoteStream(stream);
    };
    await pc.setRemoteDescription(RTCSessionDescription(
      map['sdp']?.toString(),
      map['type']?.toString(),
    ),);
    _remoteSet = true;
    await _flushIce();
    final answer = await pc.createAnswer();
    if (!identical(pc, _pc)) return;
    await pc.setLocalDescription(answer);
    send('share-answer', {'sdp': answer.sdp, 'type': answer.type});
  }

  Future<void> onAnswer(Map<dynamic, dynamic> map) async {
    final pc = _pc;
    if (pc == null || !_isSharer) return;
    await pc.setRemoteDescription(RTCSessionDescription(
      map['sdp']?.toString(),
      map['type']?.toString(),
    ),);
    _remoteSet = true;
    await _flushIce();
    // Re-assert the rung now that negotiation is done. Before the answer the
    // sender often reports NO encodings, so the pre-offer apply can no-op —
    // and an unprofiled screencast sender opens at the full display's pixel
    // rate, which is the unfunded start this design exists to end.
    await _applyRung();
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
      _pendingIce.add(m);
      return;
    }
    await _addIce(m);
  }

  void _wireIce(RTCPeerConnection pc) {
    pc.onIceCandidate = (c) => send('share-ice', {
          'candidate': c.candidate,
          'sdpMid': c.sdpMid,
          'sdpMLineIndex': c.sdpMLineIndex,
        },);
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
