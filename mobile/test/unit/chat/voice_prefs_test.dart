import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/chat/voice_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What the handset remembers about listening.
///
/// The speed is the one the owner asked to persist: every other messenger
/// resets to 1x on the next note, which is the actual annoyance. The rest —
/// where a note got to, whether it was heard — shares the store because it
/// shares the bound, and the bound is the part worth testing: a conversation is
/// unbounded and this is not.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    VoicePrefs.instance.resetForTest();
  });

  test('the speed survives a restart', () async {
    await VoicePrefs.instance.load();
    expect(VoicePrefs.instance.speed, 1.0);

    await VoicePrefs.instance.setSpeed(1.5);
    expect(VoicePrefs.instance.speed, 1.5);

    // A fresh process reading the same store.
    VoicePrefs.instance.resetForTest();
    await VoicePrefs.instance.load();
    expect(VoicePrefs.instance.speed, 1.5,
        reason: 'set once, every note after it plays fast',);
  });

  test('the cycle walks 1x -> 1.5x -> 2x and wraps', () async {
    await VoicePrefs.instance.load();
    expect(VoicePrefs.instance.nextSpeed(), 1.5);
    await VoicePrefs.instance.setSpeed(1.5);
    expect(VoicePrefs.instance.nextSpeed(), 2.0);
    await VoicePrefs.instance.setSpeed(2);
    expect(VoicePrefs.instance.nextSpeed(), 1.0);
  });

  test('a speed no tap can reach is not restored', () async {
    // A store written by a build with a different cycle would otherwise strand
    // the chip on a rate the user cannot get off.
    SharedPreferences.setMockInitialValues({'voice_speed': 3.7});
    VoicePrefs.instance.resetForTest();
    await VoicePrefs.instance.load();
    expect(VoicePrefs.instance.speed, 1.0);
  });

  test('a note resumes where it was left', () async {
    await VoicePrefs.instance.load();
    expect(VoicePrefs.instance.positionOf('m1'), Duration.zero);
    expect(VoicePrefs.instance.wasPlayed('m1'), isFalse);

    await VoicePrefs.instance
        .remember('m1', position: const Duration(seconds: 9), played: true);

    VoicePrefs.instance.resetForTest();
    await VoicePrefs.instance.load();
    expect(VoicePrefs.instance.positionOf('m1'), const Duration(seconds: 9));
    expect(VoicePrefs.instance.wasPlayed('m1'), isTrue);
  });

  test('playing a note clears its unplayed dot without losing the position',
      () async {
    await VoicePrefs.instance.load();
    await VoicePrefs.instance
        .remember('m1', position: const Duration(seconds: 4));
    await VoicePrefs.instance.remember('m1', played: true);
    expect(VoicePrefs.instance.positionOf('m1'), const Duration(seconds: 4));
    expect(VoicePrefs.instance.wasPlayed('m1'), isTrue);
  });

  test('the store is bounded, and drops the oldest first', () async {
    await VoicePrefs.instance.load();
    for (var i = 0; i < VoicePrefs.maxRemembered + 20; i++) {
      await VoicePrefs.instance.remember('m$i', played: true);
    }
    // The first twenty are gone; the newest are all still there.
    expect(VoicePrefs.instance.wasPlayed('m0'), isFalse);
    expect(VoicePrefs.instance.wasPlayed('m19'), isFalse);
    expect(VoicePrefs.instance.wasPlayed('m20'), isTrue);
    expect(
      VoicePrefs.instance.wasPlayed('m${VoicePrefs.maxRemembered + 19}'),
      isTrue,
    );
  });

  test('touching a note again keeps it, and evicts something older', () async {
    await VoicePrefs.instance.load();
    await VoicePrefs.instance.remember('keep', played: true);
    for (var i = 0; i < VoicePrefs.maxRemembered - 1; i++) {
      await VoicePrefs.instance.remember('m$i', played: true);
    }
    // 'keep' is now the oldest and would go next; touching it moves it to the
    // front of the queue instead.
    await VoicePrefs.instance.remember('keep', played: true);
    await VoicePrefs.instance.remember('overflow', played: true);
    expect(VoicePrefs.instance.wasPlayed('keep'), isTrue);
    expect(VoicePrefs.instance.wasPlayed('m0'), isFalse);
  });

  test('a store written by another build does not crash the chat', () async {
    SharedPreferences.setMockInitialValues({'voice_notes': 'not json at all'});
    VoicePrefs.instance.resetForTest();
    await VoicePrefs.instance.load();
    expect(VoicePrefs.instance.wasPlayed('m1'), isFalse);
  });
}
