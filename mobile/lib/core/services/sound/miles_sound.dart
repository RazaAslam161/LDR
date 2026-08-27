import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:miles/core/app/release_gate.dart';
import 'package:miles/core/services/sound/cue.dart';
import 'package:miles/core/services/sound/just_audio_engine.dart';
import 'package:miles/core/services/sound/sound_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The one way the app makes a sound. Static, in the house style of
/// TouchHaptics and ReleaseGate: writable seams for tests, no instance to
/// thread through forty call sites.
///
/// Every cue passes the same gate chain, in order:
///   1. the fleet kill switch (ReleaseGate.uiSoundKilled — one UPDATE ends a
///      field audio bug without a release),
///   2. the user's toggle (ON by default; Settings owns it),
///   3. cover discretion — while a disguise cover is up the app is a
///      calculator, and a calculator that chimes is a tell. Total mute, not
///      duck,
///   4. an active call — nothing bleeds into the mic path.
/// The haptic half of a cue fires REGARDLESS of 1, 2 and 4 (a haptic is
/// feedback, not sound) but respects 3 — a buzzing calculator is the same
/// tell.
///
/// The engine is created lazily on the first allowed play, so the test
/// environment (and a user who turns sound off on day one) never constructs
/// a native player at all.
class MilesSound {
  MilesSound._();

  static const prefKey = 'ui_sounds';

  static SoundEngine? _engine;
  static bool _enabled = true;
  static bool _prefLoaded = false;

  /// Test seams. [debugOverrides] injects the ambient facts the chain reads;
  /// [debugUseEngine] replaces the lazy JustAudioEngine.
  @visibleForTesting
  static bool Function()? debugCoverVisible;
  @visibleForTesting
  static bool Function()? debugCallActive;
  @visibleForTesting
  static set debugUseEngine(SoundEngine? e) => _engine = e;
  @visibleForTesting
  static void debugReset() {
    _engine = null;
    _enabled = true;
    _prefLoaded = false;
    debugCoverVisible = null;
    debugCallActive = null;
  }

  /// Wired by main.dart at boot (reads the pref) and by Settings on toggle.
  static bool get enabled => _enabled;
  static set enabled(bool v) {
    _enabled = v;
    if (!v) unawaited(silenceAll());
  }

  /// Load the persisted toggle. Absent = ON: sound ships as designed and the
  /// one-tap opt-out is honoured forever after.
  static Future<void> loadPref() async {
    if (_prefLoaded) return;
    _prefLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(prefKey) ?? true;
    } catch (e) {
      debugPrint('[sound] pref load failed, staying enabled: $e');
    }
  }

  static bool get _coverVisible => debugCoverVisible?.call() ?? _coverProbe();
  static bool get _callActive => debugCallActive?.call() ?? _callProbe();

  /// The real probes are injected by main.dart at boot — the facade must not
  /// import main.dart (everything imports the facade), so main hands the
  /// functions down instead.
  static bool Function() _coverProbe = () => false;
  static bool Function() _callProbe = () => false;
  static void wireProbes({
    required bool Function() coverVisible,
    required bool Function() callActive,
  }) {
    _coverProbe = coverVisible;
    _callProbe = callActive;
  }

  static bool get _mayPlay =>
      !ReleaseGate.uiSoundKilled && _enabled && !_coverVisible && !_callActive;

  /// Fire [cue]: haptic first, synchronously; audio unawaited behind the
  /// gate chain. This is the ONLY public play path.
  static void cue(Cue c) {
    if (!_coverVisible) unawaited(c.fireHaptic());
    if (!_mayPlay) return;
    _engine ??= JustAudioEngine();
    unawaited(_engine!.play(c));
  }

  /// Warm the pool once the real app is on screen (never behind a cover).
  static Future<void> warm() async {
    if (!_mayPlay) return;
    _engine ??= JustAudioEngine();
    await _engine!.preload(const [Cue.send, Cue.receive, Cue.tap]);
  }

  // ── The one ambient bed (Breath Sync) ──────────────────────────────────

  static double _bedGain = 0.5;
  static int _bedHolds = 0;

  static Future<void> startBed() async {
    if (!_mayPlay) return;
    _engine ??= JustAudioEngine();
    await _engine!.startLoop(Cue.bedAsset,
        gain: _bedHolds > 0 ? _bedGain * 0.2 : _bedGain,
        fadeIn: const Duration(seconds: 2),);
  }

  static Future<void> stopBed() async =>
      _engine?.stopLoop(fadeOut: const Duration(seconds: 1));

  /// Duck the bed while something that matters more is audible (a voice
  /// note). Holds nest; the last release restores.
  static Future<void> holdAmbient() async {
    _bedHolds++;
    await _engine?.setLoopGain(_bedGain * 0.2);
  }

  static Future<void> releaseAmbient() async {
    if (_bedHolds > 0) _bedHolds--;
    if (_bedHolds == 0) await _engine?.setLoopGain(_bedGain);
  }

  /// Everything, silent, NOW — the panic path as much as the background
  /// path. Pool cues pause immediately (a bowl strike ringing under a raised
  /// cover is a tell); the bed gets a fast fade rather than a click.
  static Future<void> silenceAll() async {
    final e = _engine;
    if (e == null) return;
    await e.stopCues();
    await e.stopLoop(fadeOut: const Duration(milliseconds: 250));
  }

  static bool _killSwitchAttached = false;

  /// Wired once by main: the moment a recheck flips the fleet kill on, a
  /// RUNNING bed must die too — the gate chain only guards future plays, and
  /// a kill that waits for the current session to end is not a kill.
  static void attachKillSwitch() {
    if (_killSwitchAttached) return;
    _killSwitchAttached = true;
    ReleaseGate.revision.addListener(() {
      if (ReleaseGate.uiSoundKilled) unawaited(silenceAll());
    });
  }
}
