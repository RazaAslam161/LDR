import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/app/release_gate.dart';
import 'package:miles/core/services/sound/cue.dart';
import 'package:miles/core/services/sound/miles_sound.dart';
import 'package:miles/core/services/sound/sound_engine.dart';

/// The gate chain is the sound system's whole safety story: the fleet kill,
/// the user's toggle, the cover tell, the call mic. Each gate is proven to
/// stop audio ON ITS OWN, against a fake engine that records every call —
/// no player, no platform, no asset.
class FakeSoundEngine implements SoundEngine {
  final played = <Cue>[];
  final loops = <String>[];
  final loopGains = <double>[];
  var loopStopped = 0;

  @override
  Future<void> preload(List<Cue> cues) async {}

  @override
  Future<void> play(Cue cue, {double gain = 1}) async => played.add(cue);

  var cuesStopped = 0;
  @override
  Future<void> stopCues() async => cuesStopped++;

  @override
  Future<void> startLoop(String assetPath,
      {double gain = 1, Duration? fadeIn,}) async {
    loops.add(assetPath);
    loopGains.add(gain);
  }

  @override
  Future<void> setLoopGain(double gain) async => loopGains.add(gain);

  @override
  Future<void> stopLoop({Duration? fadeOut}) async => loopStopped++;

  @override
  Future<void> disposeAll() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeSoundEngine engine;

  setUp(() {
    MilesSound.debugReset();
    ReleaseGate.uiSoundKilled = false;
    engine = FakeSoundEngine();
    MilesSound.debugUseEngine = engine;
  });

  tearDown(() {
    MilesSound.debugReset();
    ReleaseGate.uiSoundKilled = false;
  });

  test('a cue plays when every gate is open', () async {
    MilesSound.cue(Cue.send);
    await Future<void>.delayed(Duration.zero);
    expect(engine.played, [Cue.send]);
  });

  test('the fleet kill switch silences alone', () async {
    ReleaseGate.uiSoundKilled = true;
    MilesSound.cue(Cue.send);
    await Future<void>.delayed(Duration.zero);
    expect(engine.played, isEmpty,
        reason: 'one UPDATE on app_release must end all audio');
  });

  test('the user toggle silences alone', () async {
    MilesSound.enabled = false;
    MilesSound.cue(Cue.send);
    await Future<void>.delayed(Duration.zero);
    expect(engine.played, isEmpty);
  });

  test('a visible cover silences alone — a calculator must not chime',
      () async {
    MilesSound.debugCoverVisible = () => true;
    MilesSound.cue(Cue.receive);
    await Future<void>.delayed(Duration.zero);
    expect(engine.played, isEmpty);
  });

  test('an active call silences alone — nothing bleeds into the mic',
      () async {
    MilesSound.debugCallActive = () => true;
    MilesSound.cue(Cue.receive);
    await Future<void>.delayed(Duration.zero);
    expect(engine.played, isEmpty);
  });

  test('the bed ducks under a hold and the LAST release restores it',
      () async {
    await MilesSound.startBed();
    expect(engine.loops, [Cue.bedAsset]);

    await MilesSound.holdAmbient();
    await MilesSound.holdAmbient();
    await MilesSound.releaseAmbient();
    // Still one hold outstanding — the gain must not be restored yet.
    expect(engine.loopGains.last, lessThan(0.5));
    await MilesSound.releaseAmbient();
    expect(engine.loopGains.last, 0.5);
  });

  test('disabling mid-session stops the running bed', () async {
    await MilesSound.startBed();
    MilesSound.enabled = false;
    await Future<void>.delayed(Duration.zero);
    expect(engine.loopStopped, greaterThan(0),
        reason: 'the toggle is a promise about NOW, not about future cues');
  });

  test('silenceAll is unconditional AND covers the cue pool', () async {
    // The bed alone was not silence: a 2.6s bowl strike kept ringing under a
    // raised cover. Both halves now stop.
    await MilesSound.startBed();
    await MilesSound.silenceAll();
    expect(engine.loopStopped, greaterThan(0));
    expect(engine.cuesStopped, greaterThan(0),
        reason: 'in-flight cues must pause, not play out their tails');
  });

  test('a mid-session kill-switch flip silences the running bed', () async {
    MilesSound.attachKillSwitch();
    await MilesSound.startBed();
    ReleaseGate.uiSoundKilled = true;
    ReleaseGate.revision.value++;
    await Future<void>.delayed(Duration.zero);
    expect(engine.loopStopped, greaterThan(0),
        reason: 'a kill that waits for the session to end is not a kill');
  });
}
