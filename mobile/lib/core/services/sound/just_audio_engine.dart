import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:miles/core/services/sound/cue.dart';
import 'package:miles/core/services/sound/sound_engine.dart';

/// The only concrete [SoundEngine], on the player the APK already carries.
///
/// AUDIO FOCUS is the part that bit: an unconfigured just_audio player
/// requests PERMANENT exclusive focus on play and nothing ever abandons it —
/// one 200ms cue killed the user's Spotify for good, and a "News" app seizing
/// the media session is its own tell. So the CUE POOL never touches the audio
/// session at all (handleAudioSessionActivation: false — a murmur has no
/// business owning focus), and the session itself is configured once as
/// sonification + transient-may-duck, so the BED (the one deliberate,
/// minutes-long sound) ducks the user's music instead of pausing it, and
/// gives it back on stop.
///
/// A pool of three cue players, round-robin with a warm-slot scan: one player
/// cannot overlap (a send colliding with a receive would cut itself off), one
/// per cue is fifteen ExoPlayers of native memory, and blind rotation was
/// evicting the very cues warm() had loaded.
///
/// Every failure logs the cue and the error — sound is decoration and must
/// never crash a screen, but a quiet failure pattern in the logs is how an
/// OEM audio bug gets found before the kill switch is needed.
class JustAudioEngine implements SoundEngine {
  final List<AudioPlayer> _pool = [];
  final Map<int, Cue?> _loaded = {};
  int _next = 0;

  AudioPlayer? _bed;
  Timer? _bedRamp;

  /// Guards the ramp/stop machinery against interleaving: every startLoop
  /// bumps it, and a ramp completion only acts if its epoch is still current
  /// — a stopLoop racing a fresh startLoop must not stop the new bed.
  int _bedEpoch = 0;

  static const _poolSize = 3;
  static bool _sessionConfigured = false;

  static Future<void> _ensureSession() async {
    if (_sessionConfigured) return;
    _sessionConfigured = true;
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.ambient,
        androidAudioAttributes: AndroidAudioAttributes(
          contentType: AndroidAudioContentType.sonification,
          usage: AndroidAudioUsage.assistanceSonification,
        ),
        androidAudioFocusGainType:
            AndroidAudioFocusGainType.gainTransientMayDuck,
        androidWillPauseWhenDucked: false,
      ),);
    } catch (e) {
      debugPrint('[sound] session config failed: $e');
    }
  }

  Future<AudioPlayer> _player(int i) async {
    await _ensureSession();
    while (_pool.length <= i) {
      // Cues never activate the audio session: no focus request, so the
      // user's own music plays on untouched.
      _pool.add(AudioPlayer(handleAudioSessionActivation: false));
    }
    return _pool[i];
  }

  @override
  Future<void> preload(List<Cue> cues) async {
    for (var i = 0; i < cues.length && i < _poolSize; i++) {
      try {
        final p = await _player(i);
        await p.setAsset(cues[i].asset);
        _loaded[i] = cues[i];
      } catch (e) {
        debugPrint('[sound] preload ${cues[i].name} failed: $e');
      }
    }
  }

  @override
  Future<void> play(Cue cue, {double gain = 1}) async {
    // Prefer a slot that already holds this cue — blind rotation evicted the
    // warm send/receive/tap mapping on the first mixed sequence.
    var slot = -1;
    for (final e in _loaded.entries) {
      if (e.value == cue) {
        slot = e.key;
        break;
      }
    }
    if (slot < 0) {
      slot = _next;
      _next = (_next + 1) % _poolSize;
    }
    try {
      final p = await _player(slot);
      if (_loaded[slot] != cue) {
        await p.setAsset(cue.asset);
        _loaded[slot] = cue;
      }
      await p.setVolume((cue.gain * gain).clamp(0, 1));
      await p.seek(Duration.zero);
      unawaited(p.play());
    } catch (e) {
      debugPrint('[sound] play ${cue.name} failed: $e');
    }
  }

  @override
  Future<void> stopCues() async {
    for (final p in _pool) {
      try {
        await p.pause();
      } catch (e) {
        debugPrint('[sound] stopCues failed: $e');
      }
    }
  }

  @override
  Future<void> startLoop(
    String assetPath, {
    double gain = 1,
    Duration fadeIn = const Duration(seconds: 2),
  }) async {
    final epoch = ++_bedEpoch;
    try {
      _bedRamp?.cancel();
      await _ensureSession();
      // The bed IS the deliberate sound: it activates the (may-duck) session.
      final bed = _bed ??= AudioPlayer();
      await bed.setAsset(assetPath);
      if (epoch != _bedEpoch) return; // a newer start/stop superseded us
      await bed.setLoopMode(LoopMode.one);
      await bed.setVolume(0);
      unawaited(bed.play());
      _ramp(bed, epoch, to: gain, over: fadeIn);
    } catch (e) {
      debugPrint('[sound] bed start failed: $e');
    }
  }

  @override
  Future<void> setLoopGain(double gain) async {
    final bed = _bed;
    if (bed == null) return;
    _ramp(bed, _bedEpoch, to: gain, over: const Duration(milliseconds: 300));
  }

  @override
  Future<void> stopLoop({Duration fadeOut = const Duration(seconds: 1)}) async {
    final bed = _bed;
    if (bed == null) return;
    final epoch = ++_bedEpoch;
    _ramp(bed, epoch, to: 0, over: fadeOut, then: () async {
      await bed.stop();
      // Give the user's music back the moment ours ends.
      try {
        final session = await AudioSession.instance;
        await session.setActive(false);
      } catch (e) {
        debugPrint('[sound] session release failed: $e');
      }
    },);
  }

  /// A 20-step volume ramp. just_audio has no native fade; twenty setVolume
  /// calls over a couple of seconds is inaudible as steps and cheap. Cancels
  /// any ramp already running, and its completion action fires only if no
  /// newer start/stop has claimed the bed since.
  void _ramp(
    AudioPlayer p,
    int epoch, {
    required double to,
    required Duration over,
    Future<void> Function()? then,
  }) {
    const steps = 20;
    _bedRamp?.cancel();
    final from = p.volume;
    var i = 0;
    _bedRamp = Timer.periodic(over ~/ steps, (t) {
      i++;
      final v = from + (to - from) * (i / steps);
      unawaited(p.setVolume(v.clamp(0, 1)));
      if (i >= steps) {
        t.cancel();
        if (then != null && epoch == _bedEpoch) unawaited(then());
      }
    });
  }

  @override
  Future<void> disposeAll() async {
    _bedRamp?.cancel();
    for (final p in _pool) {
      await p.dispose();
    }
    _pool.clear();
    _loaded.clear();
    await _bed?.dispose();
    _bed = null;
  }
}
