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

      var s = const CallStats();
      var sentBytes = 0, recvBytes = 0;
      double now = 0;
      final codecNames = <String, String>{};

      // Codec ids resolve to names in a separate report type.
      for (final r in reports) {
        if (r.type == 'codec') {
          final mime = r.values['mimeType']?.toString() ?? '';
          if (mime.startsWith('video/')) codecNames[r.id] = mime.split('/').last;
        }
      }

      for (final r in reports) {
        final v = r.values;
        final kind = (v['kind'] ?? v['mediaType'])?.toString();
        now = r.timestamp;

        if (r.type == 'outbound-rtp' && kind == 'video') {
          s = CallStats(
            sendWidth: _int(v['frameWidth']),
            sendHeight: _int(v['frameHeight']),
            sendFps: _double(v['framesPerSecond']),
            recvWidth: s.recvWidth,
            recvHeight: s.recvHeight,
            recvFps: s.recvFps,
            recvKbps: s.recvKbps,
            sendKbps: s.sendKbps,
            limitation: v['qualityLimitationReason']?.toString() ?? '',
            rttMs: s.rttMs,
            packetsLost: s.packetsLost,
            relayed: s.relayed,
            codec: codecNames[v['codecId']?.toString()] ?? s.codec,
          );
          sentBytes = _int(v['bytesSent']);
        } else if (r.type == 'inbound-rtp' && kind == 'video') {
          s = CallStats(
            sendWidth: s.sendWidth,
            sendHeight: s.sendHeight,
            sendFps: s.sendFps,
            sendKbps: s.sendKbps,
            recvWidth: _int(v['frameWidth']),
            recvHeight: _int(v['frameHeight']),
            recvFps: _double(v['framesPerSecond']),
            recvKbps: s.recvKbps,
            limitation: s.limitation,
            rttMs: s.rttMs,
            packetsLost: _int(v['packetsLost']),
            relayed: s.relayed,
            codec: s.codec,
          );
          recvBytes = _int(v['bytesReceived']);
        } else if (r.type == 'candidate-pair' &&
            (v['state'] == 'succeeded' || v['nominated'] == true)) {
          s = CallStats(
            sendWidth: s.sendWidth,
            sendHeight: s.sendHeight,
            sendFps: s.sendFps,
            sendKbps: s.sendKbps,
            recvWidth: s.recvWidth,
            recvHeight: s.recvHeight,
            recvFps: s.recvFps,
            recvKbps: s.recvKbps,
            limitation: s.limitation,
            rttMs: (_double(v['currentRoundTripTime']) * 1000).round(),
            packetsLost: s.packetsLost,
            relayed: s.relayed,
            codec: s.codec,
          );
        } else if (r.type == 'local-candidate' && v['candidateType'] == 'relay') {
          s = CallStats(
            sendWidth: s.sendWidth,
            sendHeight: s.sendHeight,
            sendFps: s.sendFps,
            sendKbps: s.sendKbps,
            recvWidth: s.recvWidth,
            recvHeight: s.recvHeight,
            recvFps: s.recvFps,
            recvKbps: s.recvKbps,
            limitation: s.limitation,
            rttMs: s.rttMs,
            packetsLost: s.packetsLost,
            relayed: true,
            codec: s.codec,
          );
        }
      }

      // Bytes are cumulative; turn two readings into a rate.
      final dt = _lastAt == 0 ? 0.0 : (now - _lastAt) / 1000.0;
      if (dt > 0) {
        s = CallStats(
          sendWidth: s.sendWidth,
          sendHeight: s.sendHeight,
          sendFps: s.sendFps,
          sendKbps: (((sentBytes - _lastSentBytes) * 8) / dt / 1000).round(),
          recvWidth: s.recvWidth,
          recvHeight: s.recvHeight,
          recvFps: s.recvFps,
          recvKbps: (((recvBytes - _lastRecvBytes) * 8) / dt / 1000).round(),
          limitation: s.limitation,
          rttMs: s.rttMs,
          packetsLost: s.packetsLost,
          relayed: s.relayed,
          codec: s.codec,
        );
      }
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
