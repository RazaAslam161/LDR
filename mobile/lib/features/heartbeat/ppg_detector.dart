import 'package:flutter/foundation.dart';

/// Photoplethysmography (PPG) pulse detector. Fed a stream of average
/// brightness samples from the camera (finger over lens + torch), it finds
/// heartbeats as local peaks in the brightness signal and estimates BPM from
/// the average interval of recent beats.
///
/// Rough by nature — the magic is *feeling* the partner's beat, not clinical
/// accuracy.
class PpgDetector {
  PpgDetector({required this.onBpm, required this.onBeat});

  final void Function(int bpm) onBpm;
  final VoidCallback onBeat;

  final List<double> _vals = [];
  final List<int> _times = [];
  final List<int> _beats = [];
  int _lastBeatMs = 0;

  void reset() {
    _vals.clear();
    _times.clear();
    _beats.clear();
    _lastBeatMs = 0;
  }

  /// [v] = average brightness of the frame, [nowMs] = wall-clock ms.
  void addSample(double v, int nowMs) {
    _vals.add(v);
    _times.add(nowMs);
    // Keep a ~10s rolling window.
    while (_times.length > 1 && nowMs - _times.first > 10000) {
      _vals.removeAt(0);
      _times.removeAt(0);
    }
    final n = _vals.length;
    if (n < 6) return;

    final mean = _vals.reduce((a, b) => a + b) / n;
    final a = _vals[n - 3];
    final b = _vals[n - 2];
    final c = _vals[n - 1];
    final tB = _times[n - 2];

    // b is a local maximum above the mean, with a refractory gap (<=180 BPM).
    if (b > a && b >= c && b > mean && tB - _lastBeatMs > 333) {
      _lastBeatMs = tB;
      _beats.add(tB);
      while (_beats.length > 8) {
        _beats.removeAt(0);
      }
      if (_beats.length >= 3) {
        var sum = 0;
        for (var i = 1; i < _beats.length; i++) {
          sum += _beats[i] - _beats[i - 1];
        }
        final avg = sum / (_beats.length - 1);
        final bpm = (60000 / avg).round();
        if (bpm >= 40 && bpm <= 200) onBpm(bpm);
      }
      onBeat();
    }
  }
}
