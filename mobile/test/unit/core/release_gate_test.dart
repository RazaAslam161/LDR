import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/app/release_gate.dart';

/// The release gate used to be read ONCE in main() into plain statics, so a
/// phone that was already running when a release was published never learned
/// about it — no update sheet, and no block screen either, until the process
/// was killed and cold started. On a sideloaded app Android keeps alive for
/// days, that is most of a fleet rather than an edge case.
///
/// [ReleaseGate.revision] is what fixed it, and it is the piece that can be
/// deleted without breaking a build, so it is asserted on directly here.
void main() {
  // Whatever a previous test in this file left behind — these are process-wide
  // statics, so every case starts from a known row rather than an assumed one.
  // The channel goes first: applyRow reads it to pick which floor applies.
  void reset() {
    ReleaseGate.channel = 'sideload';
    ReleaseGate.applyRow({
      'min_build': 1,
      'latest_build': ReleaseGate.buildNumber,
    });
  }

  group('release gate', () {
    test('a floor above this build blocks it, and says so once', () {
      reset();
      final before = ReleaseGate.revision.value;

      ReleaseGate.applyRow({
        'min_build': ReleaseGate.buildNumber + 1,
        'latest_build': ReleaseGate.buildNumber + 1,
      });

      expect(ReleaseGate.isBlocked, isTrue);
      expect(ReleaseGate.revision.value, before + 1);
    });

    test('an unchanged row does not bump the revision', () {
      reset();
      final steady = {
        'min_build': 1,
        'latest_build': ReleaseGate.buildNumber,
        'apk_url': 'https://example.invalid/Miles.apk',
      };
      ReleaseGate.applyRow(steady);
      final settled = ReleaseGate.revision.value;

      // A resume re-check on a fleet that is already current must not wake
      // every listener — the update sheet is offered off this notifier.
      ReleaseGate.applyRow(steady);
      ReleaseGate.applyRow(steady);

      expect(ReleaseGate.revision.value, settled);
    });

    test('a newer build published mid-session is noticed', () {
      reset();
      final before = ReleaseGate.revision.value;

      // Exactly her case: the client is current, sits in the background while a
      // release is published, and resumes. Not blocked, but there IS an update.
      ReleaseGate.applyRow({
        'min_build': 1,
        'latest_build': ReleaseGate.buildNumber + 1,
      });

      expect(ReleaseGate.isBlocked, isFalse);
      expect(ReleaseGate.latestBuild, ReleaseGate.buildNumber + 1);
      expect(ReleaseGate.revision.value, before + 1);
    });

    test('lifting the floor releases a blocked client', () {
      ReleaseGate.applyRow({
        'min_build': ReleaseGate.buildNumber + 1,
        'latest_build': ReleaseGate.buildNumber + 1,
      });
      expect(ReleaseGate.isBlocked, isTrue);
      final blockedAt = ReleaseGate.revision.value;

      // The documented rollback (min_build back to 2) has to be observable by a
      // running client, or the escape hatch only works for cold starts.
      ReleaseGate.applyRow({
        'min_build': 2,
        'latest_build': ReleaseGate.buildNumber,
      });

      expect(ReleaseGate.isBlocked, isFalse);
      expect(ReleaseGate.revision.value, blockedAt + 1);
    });

    test('a row missing its columns is not read as a block', () {
      reset();
      // Fail open. A fresh environment without the columns, or a partial row,
      // must not lock the fleet out of an app that works.
      ReleaseGate.applyRow({});

      expect(ReleaseGate.isBlocked, isFalse);
      expect(ReleaseGate.latestBuild, ReleaseGate.buildNumber);
    });

    test('the play channel reads its own floor, not the sideload one', () {
      reset();
      ReleaseGate.channel = 'play';
      // Belt for a failure mid-test: reset() also restores this, but only in
      // tests that run after this one AND get that far.
      addTearDown(() => ReleaseGate.channel = 'sideload');

      // min_build rises with every forced sideload rollout, and it points at
      // an APK a Play install must never be told to sideload over itself — so
      // a raised sideload floor alone must not block a play client.
      ReleaseGate.applyRow({
        'min_build': ReleaseGate.buildNumber + 1,
        'min_build_play': 1,
        'latest_build': ReleaseGate.buildNumber + 1,
      });
      expect(ReleaseGate.isBlocked, isFalse);

      // And its own floor does block it.
      ReleaseGate.applyRow({
        'min_build': 1,
        'min_build_play': ReleaseGate.buildNumber + 1,
        'latest_build': ReleaseGate.buildNumber + 1,
      });
      expect(ReleaseGate.isBlocked, isTrue);
    });

    test('the sideload channel ignores min_build_play', () {
      reset();
      // The play floor will trail the sideload one for as long as store review
      // takes; it must never hold back the fleet that can already update.
      ReleaseGate.applyRow({
        'min_build': 1,
        'min_build_play': ReleaseGate.buildNumber + 1,
        'latest_build': ReleaseGate.buildNumber,
      });
      expect(ReleaseGate.isBlocked, isFalse);
    });

    test('a row without min_build_play never blocks a play client', () {
      reset();
      ReleaseGate.channel = 'play';
      addTearDown(() => ReleaseGate.channel = 'sideload');

      // The column may not exist yet (staging trails production, or the other
      // way round), and min_build's default of 1 must not leak across: play
      // stays open until the owner deliberately raises ITS floor.
      ReleaseGate.applyRow({
        'min_build': ReleaseGate.buildNumber + 1,
        'latest_build': ReleaseGate.buildNumber + 1,
      });
      expect(ReleaseGate.isBlocked, isFalse);
    });

    test('the build stamp matches the build number release.sh greps for', () {
      // release.sh proves the shipped snapshot is the Dart it just compiled by
      // finding this literal in libapp.so. If the two ever drift, the guard
      // passes on a stale snapshot — which is how six builds shipped build-31
      // Dart under fresh version codes.
      expect(ReleaseGate.buildStamp, 'miles-build-${ReleaseGate.buildNumber}');
    });

    test('a failed channel query leaves the fleet on the sideload floor', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      reset();
      // Every client shipped before the play channel existed is sideload, so
      // a platform query that throws must change nothing: answering 'play'
      // here would swap in the min_build_play floor (0 by default) and
      // unblock exactly the phones min_build exists to block.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('miles/updater'),
        (call) async => throw PlatformException(code: 'gone'),
      );
      await ReleaseGate.loadChannelForTest();
      expect(ReleaseGate.channel, 'sideload');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('miles/updater'),
        null,
      );
    });
  });
}
