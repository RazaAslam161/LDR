import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// What a live call is actually doing, read from the peer connection.
///
/// The whole point: "the video looks bad" has three completely different causes
/// that feel identical to whoever is looking at it — the camera captured little,
/// the encoder sent little, or the screen drew it badly. Guessing between them
/// is what produced one regression already. These are the numbers that tell
/// them apart, and [limitation] is the single most important field: libwebrtc
/// says outright whether it is holding the resolution down for CPU or for
/// bandwidth.
class CallStats {
  const CallStats({
    this.sendWidth = 0,
    this.sendHeight = 0,
    this.sendFps = 0,
    this.sendKbps = 0,
    this.recvWidth = 0,
    this.recvHeight = 0,
    this.recvFps = 0,
    this.recvKbps = 0,
    this.limitation = '',
    this.rttMs = 0,
    this.packetsLost = 0,
    this.relayed = false,
    this.codec = '',
  });

  final int sendWidth, sendHeight, recvWidth, recvHeight;
  final double sendFps, recvFps;
  final int sendKbps, recvKbps;

  /// libwebrtc's own reason for capping the outgoing video: 'cpu', 'bandwidth',
  /// 'none', or 'other'. This decides what to do about poor quality, and
  /// nothing else in the app can tell you.
  final String limitation;

  final int rttMs;
  final int packetsLost;

  /// True when media is going through a TURN relay rather than peer-to-peer.
  /// Relay adds latency and can cap throughput.
  final bool relayed;

  final String codec;

  /// One line, short enough for logcat and for an on-screen overlay.
  String get line =>
      'tx ${sendWidth}x$sendHeight@${sendFps.toStringAsFixed(0)} ${sendKbps}kbps | '
      'rx ${recvWidth}x$recvHeight@${recvFps.toStringAsFixed(0)} ${recvKbps}kbps | '
      'limit=${limitation.isEmpty ? '?' : limitation} rtt=${rttMs}ms '
      'lost=$packetsLost ${relayed ? 'RELAY' : 'p2p'} $codec';
}

/// Polls a peer connection and reports what it finds.
///
/// Deliberately cheap and deliberately always on: getStats is a few hundred
/// microseconds every two seconds, and a call that goes wrong in the field is
/// otherwise completely silent. The cost of not having this has already been
/// paid once.
class CallStatsMonitor {
  CallStatsMonitor(this._onUpdate);

  final ValueChanged<CallStats> _onUpdate;
  Timer? _timer;
  RTCPeerConnection? _pc;

  // Byte counters are cumulative, so a rate needs the previous reading.
  int _lastSentBytes = 0, _lastRecvBytes = 0;
  double _lastAt = 0;

  void start(RTCPeerConnection pc) {
    stop();
    _pc = pc;
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _sample());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _pc = null;
    _lastSentBytes = 0;
    _lastRecvBytes = 0;
    _lastAt = 0;
  }

  Future<void> _sample() async {
    final pc = _pc;
    if (pc == null) return;
    try {
      final reports = await pc.getStats();

      // Index first. The stats graph is relational — a candidate pair points at
      // its candidates by id, an rtp stream points at its codec by id — and
      // resolving those links is the whole difference between reading the
      // SELECTED network path and reading whichever report happened to come
      // last.
      final byId = {for (final r in reports) r.id: r};

      StatsReport? outVideo, inVideo, selectedPair;

      for (final r in reports) {
        final v = r.values;
        final kind = (v['kind'] ?? v['mediaType'])?.toString();
        switch (r.type) {
          case 'outbound-rtp':
            if (kind == 'video') outVideo = r;
          case 'inbound-rtp':
            if (kind == 'video') inVideo = r;
          case 'transport':
            // The transport names the pair actually carrying media. This is the
            // authoritative answer; scanning pairs for 'succeeded' is not,
            // because several pairs succeed and only one is used.
            final id = v['selectedCandidatePairId']?.toString();
            if (id != null && byId[id] != null) selectedPair = byId[id];
        }
      }

      // Fallback for stacks that do not populate transport.selectedCandidatePairId.
      selectedPair ??= reports
          .where((r) => r.type == 'candidate-pair' && r.values['nominated'] == true)
          .where((r) => r.values['state'] == 'succeeded')
          .firstOrNull;

      // Relay is a property of the SELECTED local candidate, not of whether any
      // relay candidate was gathered. TURN is always configured here, so relay
      // candidates always exist — reading them directly reported RELAY on every
      // call, including pure peer-to-peer ones.
      var relayed = false;
      if (selectedPair != null) {
        final localId = selectedPair.values['localCandidateId']?.toString();
        final local = localId == null ? null : byId[localId];
        relayed = local?.values['candidateType'] == 'relay';
      }

      final codecId = outVideo?.values['codecId']?.toString();
      final mime = codecId == null
          ? null
          : byId[codecId]?.values['mimeType']?.toString();

      final now = (outVideo ?? inVideo ?? selectedPair)?.timestamp ?? 0;
      final sentBytes = _int(outVideo?.values['bytesSent']);
      final recvBytes = _int(inVideo?.values['bytesReceived']);
      final dt = _lastAt == 0 ? 0.0 : (now - _lastAt) / 1000.0;
      int rate(int nowBytes, int thenBytes) =>
          dt <= 0 ? 0 : (((nowBytes - thenBytes) * 8) / dt / 1000).round();

      final s = CallStats(
        sendWidth: _int(outVideo?.values['frameWidth']),
        sendHeight: _int(outVideo?.values['frameHeight']),
        sendFps: _double(outVideo?.values['framesPerSecond']),
        sendKbps: rate(sentBytes, _lastSentBytes),
        recvWidth: _int(inVideo?.values['frameWidth']),
        recvHeight: _int(inVideo?.values['frameHeight']),
        recvFps: _double(inVideo?.values['framesPerSecond']),
        recvKbps: rate(recvBytes, _lastRecvBytes),
        limitation: outVideo?.values['qualityLimitationReason']?.toString() ?? '',
        rttMs:
            (_double(selectedPair?.values['currentRoundTripTime']) * 1000).round(),
        packetsLost: _int(inVideo?.values['packetsLost']),
        relayed: relayed,
        codec: mime == null ? '' : mime.split('/').last,
      );

      _lastSentBytes = sentBytes;
      _lastRecvBytes = recvBytes;
      _lastAt = now;

      debugPrint('[callstats] ${s.line}');
      _onUpdate(s);
    } catch (e) {
      debugPrint('[callstats] failed: $e');
    }
  }

  static int _int(Object? v) =>
      v is int ? v : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);

  static double _double(Object? v) =>
      v is double ? v : (v is num ? v.toDouble() : double.tryParse('$v') ?? 0);
}
