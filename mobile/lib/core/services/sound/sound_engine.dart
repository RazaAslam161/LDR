import 'package:miles/core/services/sound/cue.dart';

/// The swap seam between MilesSound and whatever actually makes noise.
///
/// just_audio implements this today because it is already in the APK and
/// field-proven by voice notes. If its latency ever proves unacceptable on
/// the low-end fleet, a soloud (or any other) engine implements these five
/// methods and MilesSound changes one line — no call site knows an engine
/// exists. Kept deliberately narrow: anything not expressible through these
/// five calls belongs to the facade, not the engine.
abstract interface class SoundEngine {
  /// Load [cues] so their first play is warm. Safe to call more than once.
  Future<void> preload(List<Cue> cues);

  /// Play one cue at [gain] (0–1, multiplied onto the cue's own gain).
  Future<void> play(Cue cue, {double gain = 1});

  /// Stop every in-flight cue NOW. The pool players pause (staying warm);
  /// this is the half of going-silent that stopLoop cannot do — a 2.6s bowl
  /// strike ringing on under a raised cover was the tell this exists for.
  Future<void> stopCues();

  /// Start the single ambient loop. A second call replaces the first.
  Future<void> startLoop(String assetPath, {double gain = 1, Duration fadeIn});

  /// Ramp the running loop's volume (ducking). No-op when no loop runs.
  Future<void> setLoopGain(double gain);

  /// Stop the loop, fading over [fadeOut].
  Future<void> stopLoop({Duration fadeOut});

  /// Stop everything and release native resources.
  Future<void> disposeAll();
}
